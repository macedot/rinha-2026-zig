const std = @import("std");
const config = @import("config.zig");
const dataset = @import("dataset.zig");
const ivf_search = @import("ivf_search.zig");
const c_bridge = @import("c_bridge.zig");
const http_server = @import("http_server.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const cfg = try config.load(allocator);
    defer {
        allocator.free(cfg.index_path);
        allocator.free(cfg.host);
        allocator.free(cfg.uds_path);
    }

    const use_zig = std.c.getenv("USE_ZIG") != null;

    if (use_zig) {
        std.debug.print("engine: PURE ZIG implementation\n", .{});
        var ds = try dataset.Dataset.load(allocator, cfg.index_path);
        // Not deiniting since server runs forever
        ivf_search.setParams(cfg.ivf_nprobe, cfg.ivf_full_nprobe, cfg.candidates);

        std.debug.print("warming caches...\n", .{});
        var rng: u32 = 0xdeadbeef;
        for (0..500) |_| {
            var q: [config.DIM]f32 = undefined;
            for (0..config.DIM) |i| {
                rng = rng *% 1664525 +% 1013904223;
                q[i] = @as(f32, @floatFromInt(rng >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24));
            }
            _ = ivf_search.search(q, &ds);
        }
        std.debug.print("cache warmup done\n", .{});

        var server = try http_server.Server.init(&cfg, &ds, true);
        try server.run();
    } else {
        std.debug.print("engine: C/AVX2 bridge implementation\n", .{});
        try c_bridge.loadIndex(allocator, cfg.index_path);
        c_bridge.setParams(@intCast(cfg.ivf_nprobe), @intCast(cfg.ivf_full_nprobe), @intCast(cfg.candidates));

        std.debug.print("warming caches...\n", .{});
        c_bridge.warmup();
        std.debug.print("cache warmup done\n", .{});

        var server = try http_server.Server.init(&cfg, null, false);
        try server.run();
    }
}
