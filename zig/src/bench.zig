const std = @import("std");
const config = @import("config.zig");
const dataset = @import("dataset.zig");
const ivf_search = @import("ivf_search.zig");
const c = @cImport({
    @cInclude("bridge.h");
    @cInclude("time.h");
});

const DIM = config.DIM;
const N_WARMUP = 500;
const N_BENCH = 5000;

fn nanos() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn benchCBridge(queries: [][DIM]f32, results: []u8) u64 {
    c.rinha_set_search_params(8, 24, 0);
    const t0 = nanos();
    for (queries, 0..) |q, i| {
        results[i] = @intCast(c.rinha_search(&q));
    }
    const t1 = nanos();
    return t1 - t0;
}

fn benchPureZig(queries: [][DIM]f32, ds: *const dataset.Dataset, results: []u8) u64 {
    ivf_search.setParams(8, 24, 0);
    const t0 = nanos();
    for (queries, 0..) |q, i| {
        results[i] = ivf_search.search(q, ds);
    }
    const t1 = nanos();
    return t1 - t0;
}

// Instrumented search - returns breakdown per phase
fn searchInstrumented(query: [DIM]f32, ds: *const dataset.Dataset) struct { result: u8, phase_times: [6]u64 } {
    const t_start = nanos();

    var q_i16: [DIM]i16 = undefined;
    var q_grid: [DIM]f32 = undefined;
    for (0..DIM) |j| {
        q_i16[j] = ivf_search.quantize(query[j]);
        q_grid[j] = @as(f32, @floatFromInt(q_i16[j])) / config.FIX_SCALE;
    }
    const t_after_quant = nanos();

    // Compute all centroid distances
    var dists: [config.IVF_CLUSTERS]f32 = undefined;
    ivf_search.computeCentroidDistsAvx2(q_grid, ds, &dists);
    const t_after_centroid = nanos();

    const fast_nprobe = 8;
    const full_nprobe = 24;

    // Keep top full_nprobe clusters
    var best_c: [config.IVF_MAX_NPROBE]i32 = [_]i32{-1} ** config.IVF_MAX_NPROBE;
    var best_p: [config.IVF_MAX_NPROBE]f32 = [_]f32{std.math.floatMax(f32)} ** config.IVF_MAX_NPROBE;
    ivf_search.topNFromDistsAvx2(full_nprobe, &dists, &best_c, &best_p);
    const t_after_topn = nanos();

    // Reorder: scan smallest clusters first
    for (0..full_nprobe - 1) |i| {
        for (i + 1..full_nprobe) |j| {
            if (best_c[i] >= 0 and best_c[j] >= 0) {
                const ci: usize = @intCast(best_c[i]);
                const cj: usize = @intCast(best_c[j]);
                const si = ds.block_offsets[ci + 1] - ds.block_offsets[ci];
                const sj = ds.block_offsets[cj + 1] - ds.block_offsets[cj];
                if (sj < si) {
                    const tc = best_c[i]; best_c[i] = best_c[j]; best_c[j] = tc;
                    const tp = best_p[i]; best_p[i] = best_p[j]; best_p[j] = tp;
                }
            }
        }
    }
    const t_after_reorder = nanos();

    // Fast pass
    const result_fast = ivf_search.searchWithNprobe(fast_nprobe, &best_c, q_i16, ds);
    const t_after_fast = nanos();

    // Two-stage: if ambiguous (2 or 3 frauds), re-run with full probes
    var result = result_fast;
    if (result == 2 or result == 3) {
        result = ivf_search.searchWithNprobe(full_nprobe, &best_c, q_i16, ds);
    }
    const t_after_full = nanos();

    return .{
        .result = result,
        .phase_times = .{
            t_after_quant - t_start,
            t_after_centroid - t_after_quant,
            t_after_topn - t_after_centroid,
            t_after_reorder - t_after_topn,
            t_after_fast - t_after_reorder,
            t_after_full - t_after_fast,
        },
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load index
    std.debug.print("Loading IVF1 index...\n", .{});
    var ds = try dataset.Dataset.load(allocator, "data/index.bin");
    defer ds.deinit();
    std.debug.print("Index loaded: N={} K={} blocks={}\n", .{ ds.n, config.IVF_CLUSTERS, ds.total_blocks });

    // Load C bridge
    const path_z = try allocator.dupeZ(u8, "data/index.bin");
    defer allocator.free(path_z);
    if (c.rinha_load_index(path_z.ptr) != 0) {
        std.debug.print("Failed to load C bridge index\n", .{});
        return error.IndexLoadFailed;
    }
    c.rinha_set_search_params(8, 24, 0);

    // Generate random queries
    std.debug.print("Generating {} random queries...\n", .{N_WARMUP + N_BENCH});
    var queries = try allocator.alloc([DIM]f32, N_WARMUP + N_BENCH);
    defer allocator.free(queries);

    var rng: u32 = 0xdeadbeef;
    for (queries) |*q| {
        for (q) |*v| {
            rng = rng *% 1664525 +% 1013904223;
            v.* = @as(f32, @floatFromInt(rng >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24));
        }
    }

    // Warmup C bridge
    std.debug.print("Warming up C bridge...\n", .{});
    for (queries[0..N_WARMUP]) |q| {
        _ = c.rinha_search(&q);
    }

    // Warmup pure Zig
    std.debug.print("Warming up pure Zig...\n", .{});
    for (queries[0..N_WARMUP]) |q| {
        _ = ivf_search.search(q, &ds);
    }

    const c_results = try allocator.alloc(u8, N_BENCH);
    defer allocator.free(c_results);
    const zig_results = try allocator.alloc(u8, N_BENCH);
    defer allocator.free(zig_results);

    // Benchmark C bridge
    std.debug.print("\nBenchmarking C bridge ({} queries)...\n", .{N_BENCH});
    c.rinha_reset_inst();
    const c_time = benchCBridge(queries[N_WARMUP..], c_results);
    const c_avg_ns = c_time / N_BENCH;
    std.debug.print("C bridge: {d:.2} ms total, {d:.2} us avg/query\n", .{ @as(f64, @floatFromInt(c_time)) / 1_000_000.0, @as(f64, @floatFromInt(c_avg_ns)) / 1000.0 });
    var c_inst: [7]u64 = undefined;
    c.rinha_get_inst(&c_inst);
    const c_count = c_inst[6];
    std.debug.print("\n=== C Instrumentation ===\n", .{});
    const c_phase_names = [_][]const u8{
        "quantize/q_grid",
        "centroid dists",
        "top-n select",
        "reorder",
        "fast scan",
        "full scan (2nd)",
    };
    for (0..6) |p| {
        const avg_ns = if (c_count > 0) c_inst[p] / c_count else 0;
        const pct = if (c_time > 0) @as(f64, @floatFromInt(c_inst[p])) / @as(f64, @floatFromInt(c_time)) * 100.0 else 0.0;
        std.debug.print("  {s:20}: {d:6} ns ({d:5.1}%)\n", .{ c_phase_names[p], avg_ns, pct });
    }
    std.debug.print("  Two-stage triggers: detected\n", .{});

    // Benchmark pure Zig
    std.debug.print("\nBenchmarking pure Zig ({} queries)...\n", .{N_BENCH});
    const zig_time = benchPureZig(queries[N_WARMUP..], &ds, zig_results);
    const zig_avg_ns = zig_time / N_BENCH;
    std.debug.print("Pure Zig: {d:.2} ms total, {d:.2} us avg/query\n", .{ @as(f64, @floatFromInt(zig_time)) / 1_000_000.0, @as(f64, @floatFromInt(zig_avg_ns)) / 1000.0 });

    // Verify correctness
    var mismatches: usize = 0;
    for (c_results, zig_results) |cr, zr| {
        if (cr != zr) mismatches += 1;
    }
    if (mismatches > 0) {
        std.debug.print("WARNING: {} mismatches out of {}\n", .{ mismatches, N_BENCH });
    } else {
        std.debug.print("All {} results match!\n", .{N_BENCH});
    }

    // Instrumentation: per-phase breakdown on subset
    std.debug.print("\n=== Instrumentation ({} queries) ===\n", .{N_BENCH});
    var phase_totals = [_]u64{0} ** 6;
    var two_stage_count: usize = 0;
    for (queries[N_WARMUP..]) |q| {
        const inst = searchInstrumented(q, &ds);
        for (0..6) |p| {
            phase_totals[p] += inst.phase_times[p];
        }
        if (inst.phase_times[5] > 0) two_stage_count += 1;
    }
    const phase_names = [_][]const u8{
        "quantize/q_grid",
        "centroid dists",
        "top-n select",
        "reorder",
        "fast scan",
        "full scan (2nd)",
    };
    for (0..6) |p| {
        const avg_ns = phase_totals[p] / N_BENCH;
        const pct = @as(f64, @floatFromInt(phase_totals[p])) / @as(f64, @floatFromInt(zig_time)) * 100.0;
        std.debug.print("  {s:20}: {d:6} ns ({d:5.1}%)\n", .{ phase_names[p], avg_ns, pct });
    }
    std.debug.print("  Two-stage triggers: {} / {} ({d:.1}%)\n", .{ two_stage_count, N_BENCH, @as(f64, @floatFromInt(two_stage_count)) / @as(f64, @floatFromInt(N_BENCH)) * 100.0 });

    // Results
    const ratio = @as(f64, @floatFromInt(zig_time)) / @as(f64, @floatFromInt(c_time));
    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("C bridge avg: {d:.2} us/query\n", .{@as(f64, @floatFromInt(c_avg_ns)) / 1000.0});
    std.debug.print("Pure Zig avg: {d:.2} us/query\n", .{@as(f64, @floatFromInt(zig_avg_ns)) / 1000.0});
    if (ratio > 1.0) {
        std.debug.print("C bridge is {d:.2}x faster than pure Zig\n", .{ratio});
    } else {
        std.debug.print("Pure Zig is {d:.2}x faster than C bridge\n", .{1.0 / ratio});
    }
}
