const std = @import("std");
const c = @cImport({
    @cInclude("bridge.h");
});

const DIM = 14;

pub fn loadIndex(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (c.rinha_load_index(path_z.ptr) != 0) {
        return error.IndexLoadFailed;
    }
}

pub fn setParams(nprobe: c_int, full_nprobe: c_int, candidates: c_int) void {
    c.rinha_set_search_params(nprobe, full_nprobe, candidates);
}

pub fn search(query: [DIM]f32) u8 {
    return @intCast(c.rinha_search(&query));
}

pub fn warmup() void {
    var state: u32 = 0x12345678;
    for (0..500) |_| {
        var q: [DIM]f32 = undefined;
        for (&q) |*v| {
            state = state *% 1664525 +% 1013904223;
            v.* = @as(f32, @floatFromInt(state >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24));
        }
        _ = c.rinha_search(&q);
    }
}
