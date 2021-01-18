const std = @import("std");

const Module = @import("../module.zig");
const Op = @import("../op.zig");
const Wat = @import("../wat.zig");

pub fn post_process(self: *Module) !void {
    var temp_arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
    defer temp_arena.deinit();

    var stack_types = std.ArrayList(Module.Type.Value).init(&temp_arena.allocator);
    var stack_blocks = std.ArrayList(struct { instr_idx: usize, block_type: Module.Type.Block }).init(&temp_arena.allocator);

    var import_funcs: usize = 0;
    for (self.import) |import| {
        if (import.kind == .Function) {
            import_funcs += 1;
        }
    }

    for (self.code) |body, f| {
        std.debug.assert(stack_types.items.len == 0);

        const func = self.function[f];
        const func_type = self.@"type"[@enumToInt(func.type_idx)];
        const func_idx = f + import_funcs;
        for (body.code) |instr, i| {
            const op_meta = Op.Meta.of(instr.op);
            switch (instr.op) {
                .block, .loop, .@"if" => {
                    const result_type = @intToEnum(Op.Arg.Type, instr.arg.V128);
                    const converted_type: Module.Type.Block = switch (result_type) {
                        .Void => .Empty,
                        .I32 => .I32,
                        .I64 => .I64,
                        .F32 => .F32,
                        .F64 => .F64,
                    };
                    try stack_blocks.append(.{ .instr_idx = i, .block_type = converted_type });
                },
                .end, .@"else" => {
                    const block_meta = stack_blocks.popOrNull() orelse return error.BlockMismatch;
                    if (block_meta.block_type != .Empty) {
                        if (stack_types.items.len == 0) {
                            return error.BlockMismatch;
                        }
                        const last = stack_types.items[stack_types.items.len - 1];
                        if (@enumToInt(block_meta.block_type) != @enumToInt(last)) {
                            return error.StackMismatch;
                        }
                    }

                    if (instr.op == .@"else") {
                        if (block_meta.block_type != .Empty) {
                            _ = stack_types.pop();
                        }

                        try stack_blocks.append(.{ .instr_idx = i, .block_type = block_meta.block_type });
                    }
                },
                .call => {
                    const call_func = self.function[instr.arg.U32];
                    try processFuncStack(&stack_types, self.@"type"[@enumToInt(call_func.type_idx)]);
                },
                .call_indirect => try processFuncStack(&stack_types, self.@"type"[instr.arg.U32]),
                else => {
                    for (op_meta.pop) |pop| {
                        const top = stack_types.popOrNull() orelse return error.StackMismatch;
                        const expected: Module.Type.Value = switch (pop) {
                            .I32 => .I32,
                            .I64 => .I64,
                            .F32 => .F32,
                            .F64 => .F64,
                            .Poly => switch (instr.op) {
                                .drop => continue, // Drops *any* value, no comparison needed
                                .@"local.set", .@"local.tee" => localType(instr.arg.U32, func_type.param_types, body.locals),
                                else => @panic("TODO"),
                            },
                        };
                        if (expected != top) {
                            return error.StackMismatch;
                        }
                    }

                    if (op_meta.push) |push| {
                        try stack_types.append(switch (push) {
                            .I32 => .I32,
                            .I64 => .I64,
                            .F32 => .F32,
                            .F64 => .F64,
                            .Poly => switch (instr.op) {
                                .@"local.get", .@"local.tee" => localType(instr.arg.U32, func_type.param_types, body.locals),
                                else => @panic("TODO"),
                            },
                        });
                    }
                },
            }
        }

        if (stack_blocks.items.len != 0) {
            return error.BlockMismatch;
        }

        if (func_type.return_type) |return_type| {
            if (stack_types.items.len != 1 or stack_types.pop() != return_type) {
                return error.StackMismatch;
            }
        } else {
            if (stack_types.items.len != 0) {
                return error.StackMismatch;
            }
        }
    }
}

fn processFuncStack(stack: *std.ArrayList(Module.Type.Value), func_type: Module.sectionType(.Type)) !void {
    var i: usize = func_type.param_types.len;
    while (i > 0) {
        i -= 1;
        const param = func_type.param_types[i];
        const top = stack.popOrNull() orelse return error.StackMismatch;
        if (param != top) {
            return error.StackMismatch;
        }
    }
    if (func_type.return_type) |ret| {
        try stack.append(ret);
    }
}

fn localType(local_idx: u32, params: []const Module.Type.Value, locals: []const Module.Type.Value) Module.Type.Value {
    if (local_idx < params.len) {
        return params[local_idx];
    } else {
        return locals[local_idx - params.len];
    }
}

test "smoke" {
    var fbs = std.io.fixedBufferStream(
        \\(module
        \\  (func (result i32)
        \\    i32.const 40
        \\    i32.const 2
        \\    i32.add))
    );
    var module = try Wat.parseNoValidate(std.testing.allocator, fbs.reader());
    defer module.deinit();

    try module.post_process();
}

test "add nothing" {
    var fbs = std.io.fixedBufferStream(
        \\(module
        \\  (func (result i32)
        \\    i32.add))
    );
    var module = try Wat.parseNoValidate(std.testing.allocator, fbs.reader());
    defer module.deinit();

    std.testing.expectError(error.StackMismatch, module.post_process());
}

test "add wrong types" {
    var fbs = std.io.fixedBufferStream(
        \\(module
        \\  (func (result i32)
        \\    i32.const 40
        \\    i64.const 2
        \\    i32.add))
    );
    var module = try Wat.parseNoValidate(std.testing.allocator, fbs.reader());
    defer module.deinit();

    std.testing.expectError(error.StackMismatch, module.post_process());
}

test "return nothing" {
    var fbs = std.io.fixedBufferStream(
        \\(module
        \\  (func (result i32)))
    );
    var module = try Wat.parseNoValidate(std.testing.allocator, fbs.reader());
    defer module.deinit();

    std.testing.expectError(error.StackMismatch, module.post_process());
}

test "return wrong type" {
    var fbs = std.io.fixedBufferStream(
        \\(module
        \\  (func (result i32)
        \\    i64.const 40))
    );
    var module = try Wat.parseNoValidate(std.testing.allocator, fbs.reader());
    defer module.deinit();

    std.testing.expectError(error.StackMismatch, module.post_process());
}