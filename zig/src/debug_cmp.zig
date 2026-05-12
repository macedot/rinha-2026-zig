const std = @import("std");
const config = @import("config.zig");
const dataset = @import("dataset.zig");
const ivf_search = @import("ivf_search.zig");
const c = @cImport({
    @cInclude("bridge.h");
});

const DIM = config.DIM;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load index in pure Zig
    var ds = try dataset.Dataset.load(allocator, "data/index.bin");
    defer ds.deinit();

    // Load index in C bridge
    const path_z = try allocator.dupeZ(u8, "data/index.bin");
    defer allocator.free(path_z);
    if (c.rinha_load_index(path_z.ptr) != 0) {
        std.debug.print("Failed to load C bridge index\n", .{});
        return error.IndexLoadFailed;
    }
    c.rinha_set_search_params(8, 24, 0);
    ivf_search.setParams(8, 24, 0);

    // Test query
    var q: [DIM]f32 = .{0.5} ** DIM;

    const c_result = c.rinha_search(&q);
    const zig_result = ivf_search.search(q, &ds);

    std.debug.print("Query: ", .{});
    for (q) |v| std.debug.print("{d:.4} ", .{v});
    std.debug.print("\n", .{});
    std.debug.print("C bridge result: {}\n", .{c_result});
    std.debug.print("Pure Zig result: {}\n", .{zig_result});

    if (c_result != zig_result) {
        std.debug.print("MISMATCH!\n", .{});

        // Debug: compare centroid distances for first 16 clusters
        var q_i16: [DIM]i16 = undefined;
        var q_grid: [DIM]f32 = undefined;
        for (0..DIM) |j| {
            q_i16[j] = ivf_search.quantize(q[j]);
            q_grid[j] = @as(f32, @floatFromInt(q_i16[j])) / config.FIX_SCALE;
        }

        var dists_scalar: [config.IVF_CLUSTERS]f32 = undefined;
        ivf_search.computeCentroidDistsScalar(q_grid, &ds, &dists_scalar);

        var dists_avx2: [config.IVF_CLUSTERS]f32 = undefined;
        ivf_search.computeCentroidDistsAvx2(q_grid, &ds, &dists_avx2);

        std.debug.print("\nCentroid distance comparison (first 16):\n", .{});
        var cd_mismatch: usize = 0;
        for (0..config.IVF_CLUSTERS) |i| {
            if (@abs(dists_scalar[i] - dists_avx2[i]) > 0.001) {
                cd_mismatch += 1;
                if (cd_mismatch <= 16) {
                    std.debug.print("  c={} scalar={d:.6} avx2={d:.6}\n", .{ i, dists_scalar[i], dists_avx2[i] });
                }
            }
        }
        std.debug.print("Total centroid dist mismatches: {}\n", .{cd_mismatch});
    } else {
        std.debug.print("MATCH!\n", .{});
    }
}
