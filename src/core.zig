const std = @import("std");
const Op = @import("op.zig");

pub const Module = struct {
    arena: *std.heap.ArenaAllocator,
    memory: u32 = 0,
    funcs: []Func,
    exports: []Export,

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
        self.funcs = &[0]Func{};
        self.exports = &[0]Export{};
    }

    pub const Type = enum {
        I32,
        I64,
        F32,
        F64,
    };

    pub const Export = struct {
        name: []const u8,
        value: union(enum) {
            func: usize,
        },
    };

    pub const Func = struct {
        name: ?[]const u8,
        params: []Type,
        result: ?Type,
        locals: []Type,
        instrs: []Instr,
    };

    pub const Instr = struct {
        opcode: u8,
        arg: Op.Arg,
    };
};

pub const WasmTrap = error{WasmTrap};

pub const Instance = struct {
    module: *Module,
    memory: []u8,
    allocator: *std.mem.Allocator,

    pub fn memGet(self: Instance, start: usize, offset: usize, comptime length: usize) WasmTrap!*[length]u8 {
        const tail = start +% offset +% (length - 1);
        const is_overflow = tail < start;
        const is_seg_fault = tail >= self.memory.len;
        if (is_overflow or is_seg_fault) {
            return error.WasmTrap;
        }
        return @ptrCast(*[length]u8, &self.memory[start + offset]);
    }
};
