const std = @import("std");
const config = @import("config.zig");
const dataset = @import("dataset.zig");

const DIM = config.DIM;
const IVF_CLUSTERS = config.IVF_CLUSTERS;
const IVF_MAX_NPROBE = config.IVF_MAX_NPROBE;
const BLOCK_STRIDE = config.BLOCK_STRIDE;
const VECTOR_SCALE = config.VECTOR_SCALE;
const FIX_SCALE = config.FIX_SCALE;
const builtin = @import("builtin");

var g_nprobe: usize = 8;
var g_full_nprobe: usize = 24;
var g_candidates: usize = 0;

pub fn setParams(nprobe: usize, full_nprobe: usize, candidates: usize) void {
    g_nprobe = nprobe;
    g_full_nprobe = full_nprobe;
    g_candidates = candidates;
}

pub fn quantize(x: f32) i16 {
    var v = x;
    if (v < -1.0) v = -1.0;
    if (v > 1.0) v = 1.0;
    var scaled = v * FIX_SCALE;
    scaled += if (scaled >= 0.0) 0.5 else -0.5;
    if (scaled < -10000.0) scaled = -10000.0;
    if (scaled > 10000.0) scaled = 10000.0;
    return @intFromFloat(scaled);
}

// --- AVX2 feature detection ---

const have_avx2 = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx2),
    else => false,
};

// --- Centroid distance (AVX2) ---

pub fn computeCentroidDistsAvx2(q: [DIM]f32, ds: *const dataset.Dataset, dists: []f32) void {
    const cp = ds.centroids_t.ptr;
    const dp = dists.ptr;
    const k = IVF_CLUSTERS;

    // Dim 0: initialize
    {
        const qd: @Vector(8, f32) = @splat(q[0]);
        var ci: usize = 0;
        while (ci + 16 <= k) : (ci += 16) {
            const c0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + ci)).*;
            const c1: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + ci + 8)).*;
            const d0 = c0 - qd;
            const d1 = c1 - qd;
            @as(*[8]f32, @ptrCast(dp + ci)).* = d0 * d0;
            @as(*[8]f32, @ptrCast(dp + ci + 8)).* = d1 * d1;
        }
        while (ci + 8 <= k) : (ci += 8) {
            const c0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + ci)).*;
            const d0 = c0 - qd;
            @as(*[8]f32, @ptrCast(dp + ci)).* = d0 * d0;
        }
        while (ci < k) : (ci += 1) {
            const diff = cp[ci] - q[0];
            dp[ci] = diff * diff;
        }
    }

    // Dims 1..13: accumulate
    for (1..DIM) |d| {
        const base = d * k;
        const qd: @Vector(8, f32) = @splat(q[d]);
        var ci: usize = 0;
        while (ci + 16 <= k) : (ci += 16) {
            const cv0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + base + ci)).*;
            const cv1: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + base + ci + 8)).*;
            const d0 = cv0 - qd;
            const d1 = cv1 - qd;
            const a0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(dp + ci)).*;
            const a1: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(dp + ci + 8)).*;
            @as(*[8]f32, @ptrCast(dp + ci)).* = a0 + d0 * d0;
            @as(*[8]f32, @ptrCast(dp + ci + 8)).* = a1 + d1 * d1;
        }
        while (ci + 8 <= k) : (ci += 8) {
            const cv: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(cp + base + ci)).*;
            const d0 = cv - qd;
            const a0: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(dp + ci)).*;
            @as(*[8]f32, @ptrCast(dp + ci)).* = a0 + d0 * d0;
        }
        while (ci < k) : (ci += 1) {
            const diff = cp[base + ci] - q[d];
            dp[ci] += diff * diff;
        }
    }
}

pub fn computeCentroidDistsScalar(q: [DIM]f32, ds: *const dataset.Dataset, dists: []f32) void {
    for (0..IVF_CLUSTERS) |c| {
        var s: f32 = 0.0;
        for (0..DIM) |j| {
            const d = q[j] - ds.centroids_t[j * IVF_CLUSTERS + c];
            s += d * d;
        }
        dists[c] = s;
    }
}

// --- Top-n from distances ---

fn vmovmskps(v: @Vector(8, f32)) u8 {
    const mask: u32 = asm ("vmovmskps %[v], %[mask]"
        : [mask] "=r" (-> u32),
        : [v] "x" (v),
    );
    return @intCast(mask);
}

pub fn topNFromDistsAvx2(nprobe: usize, dists: []const f32, best_c: []i32, best_p: []f32) void {
    for (0..nprobe) |i| {
        best_c[i] = -1;
        best_p[i] = std.math.floatMax(f32);
    }

    var ci: usize = 0;
    while (ci + 8 <= IVF_CLUSTERS) : (ci += 8) {
        const d8: @Vector(8, f32) = @as(*const [8]f32, @ptrCast(dists.ptr + ci)).*;
        const threshold: @Vector(8, f32) = @splat(best_p[nprobe - 1]);
        // d8 - threshold < 0  →  sign bit set  →  d8 < threshold
        const diff = d8 - threshold;
        const mask = vmovmskps(diff);
        if (mask == 0) continue;

        var buf: [8]f32 = undefined;
        @as(*[8]f32, @ptrCast(&buf)).* = d8;
        var m = mask;
        while (m != 0) {
            const slot = @ctz(m);
            m &= m - 1;
            const di = buf[slot];
            if (di < best_p[nprobe - 1]) {
                var pos = nprobe - 1;
                while (pos > 0 and di < best_p[pos - 1]) pos -= 1;
                var i: usize = nprobe - 1;
                while (i > pos) : (i -= 1) {
                    best_p[i] = best_p[i - 1];
                    best_c[i] = best_c[i - 1];
                }
                best_p[pos] = di;
                best_c[pos] = @intCast(ci + slot);
            }
        }
    }

    while (ci < IVF_CLUSTERS) : (ci += 1) {
        const di = dists[ci];
        if (di < best_p[nprobe - 1]) {
            var pos = nprobe - 1;
            while (pos > 0 and di < best_p[pos - 1]) pos -= 1;
            var i: usize = nprobe - 1;
            while (i > pos) : (i -= 1) {
                best_p[i] = best_p[i - 1];
                best_c[i] = best_c[i - 1];
            }
            best_p[pos] = di;
            best_c[pos] = @intCast(ci);
        }
    }
}

fn topNFromDistsScalar(nprobe: usize, dists: []const f32, best_c: []i32, best_p: []f32) void {
    for (0..nprobe) |i| {
        best_c[i] = -1;
        best_p[i] = std.math.floatMax(f32);
    }
    for (0..IVF_CLUSTERS) |c| {
        const di = dists[c];
        if (di >= best_p[nprobe - 1]) continue;
        var pos = nprobe - 1;
        while (pos > 0 and di < best_p[pos - 1]) pos -= 1;
        var i: usize = nprobe - 1;
        while (i > pos) : (i -= 1) {
            best_p[i] = best_p[i - 1];
            best_c[i] = best_c[i - 1];
        }
        best_p[pos] = di;
        best_c[pos] = @intCast(c);
    }
}

// --- Top-5 maintenance ---

inline fn tryInsertTop5(dist: f32, label: u8, best_d: *[5]f32, best_l: *[5]u8, worst: *usize, worst_d: *f32) void {
    _ = worst;
    if (dist < worst_d.*) {
        if (dist < best_d[0]) {
            best_d[4] = best_d[3]; best_l[4] = best_l[3];
            best_d[3] = best_d[2]; best_l[3] = best_l[2];
            best_d[2] = best_d[1]; best_l[2] = best_l[1];
            best_d[1] = best_d[0]; best_l[1] = best_l[0];
            best_d[0] = dist;      best_l[0] = label;
        } else if (dist < best_d[1]) {
            best_d[4] = best_d[3]; best_l[4] = best_l[3];
            best_d[3] = best_d[2]; best_l[3] = best_l[2];
            best_d[2] = best_d[1]; best_l[2] = best_l[1];
            best_d[1] = dist;      best_l[1] = label;
        } else if (dist < best_d[2]) {
            best_d[4] = best_d[3]; best_l[4] = best_l[3];
            best_d[3] = best_d[2]; best_l[3] = best_l[2];
            best_d[2] = dist;      best_l[2] = label;
        } else if (dist < best_d[3]) {
            best_d[4] = best_d[3]; best_l[4] = best_l[3];
            best_d[3] = dist;      best_l[3] = label;
        } else {
            best_d[4] = dist;      best_l[4] = label;
        }
        worst_d.* = best_d[4];
    }
}

// --- AVX2 block scan ---

fn prefetch(ptr: *const anyopaque) void {
    asm volatile (
        \\prefetcht0 (%[ptr])
        :
        : [ptr] "r" (ptr),
    );
}

inline fn loadBlock8I16(blocks: [*]const i16, block_idx: usize, dim: usize) @Vector(8, i16) {
    const offset = block_idx * BLOCK_STRIDE + dim * 8;
    const ptr: *align(1) const [8]i16 = @ptrCast(&blocks[offset]);
    return ptr.*;
}

inline fn dimFma(
    qv: @Vector(8, f32),
    blocks: [*]const i16,
    block_idx: usize,
    dim: usize,
    scale: @Vector(8, f32),
    acc: @Vector(8, f32),
) @Vector(8, f32) {
    const raw = loadBlock8I16(blocks, block_idx, dim);
    const v32: @Vector(8, i32) = @intCast(raw);
    const vf: @Vector(8, f32) = @floatFromInt(v32);
    const vscaled = vf * scale;
    const diff = vscaled - qv;
    return acc + diff * diff;
}

fn scanBlocksAvx2(
    start_block: usize,
    end_block: usize,
    q: [DIM]i16,
    ds: *const dataset.Dataset,
    best_d: *[5]f32,
    best_l: *[5]u8,
    worst: *usize,
    worst_d: *f32,
) void {
    const blocks = ds.blocks.ptr;
    const labels = ds.labels.ptr;
    const scale: @Vector(8, f32) = @splat(VECTOR_SCALE);

    const qv0: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[0])) * VECTOR_SCALE);
    const qv1: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[1])) * VECTOR_SCALE);
    const qv2: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[2])) * VECTOR_SCALE);
    const qv3: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[3])) * VECTOR_SCALE);
    const qv4: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[4])) * VECTOR_SCALE);
    const qv5: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[5])) * VECTOR_SCALE);
    const qv6: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[6])) * VECTOR_SCALE);
    const qv7: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[7])) * VECTOR_SCALE);
    const qv8: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[8])) * VECTOR_SCALE);
    const qv9: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[9])) * VECTOR_SCALE);
    const qv10: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[10])) * VECTOR_SCALE);
    const qv11: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[11])) * VECTOR_SCALE);
    const qv12: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[12])) * VECTOR_SCALE);
    const qv13: @Vector(8, f32) = @splat(@as(f32, @floatFromInt(q[13])) * VECTOR_SCALE);

    var bi = start_block;
    while (bi < end_block) : (bi += 1) {
        if (have_avx2) {
            const pf_block = bi + 8;
            if (pf_block < end_block) {
                const pf_ptr: *const anyopaque = @ptrCast(&blocks[pf_block * BLOCK_STRIDE]);
                prefetch(pf_ptr);
                const pf_ptr2: *const anyopaque = @ptrCast(&blocks[pf_block * BLOCK_STRIDE + 56]);
                prefetch(pf_ptr2);
            }
        }

        const label_base = bi * 8;

        var acc0: @Vector(8, f32) = @splat(0.0);
        var acc1: @Vector(8, f32) = @splat(0.0);

        acc0 = dimFma(qv0, blocks, bi, 0, scale, acc0);
        acc1 = dimFma(qv1, blocks, bi, 1, scale, acc1);
        acc0 = dimFma(qv2, blocks, bi, 2, scale, acc0);
        acc1 = dimFma(qv3, blocks, bi, 3, scale, acc1);
        acc0 = dimFma(qv4, blocks, bi, 4, scale, acc0);
        acc1 = dimFma(qv5, blocks, bi, 5, scale, acc1);
        acc0 = dimFma(qv6, blocks, bi, 6, scale, acc0);
        acc1 = dimFma(qv7, blocks, bi, 7, scale, acc1);

        const partial = acc0 + acc1;
        const diff1 = partial - @as(@Vector(8, f32), @splat(worst_d.*));
        const mask1 = vmovmskps(diff1);
        if (mask1 == 0) continue;

        acc0 = dimFma(qv8, blocks, bi, 8, scale, acc0);
        acc1 = dimFma(qv9, blocks, bi, 9, scale, acc1);
        acc0 = dimFma(qv10, blocks, bi, 10, scale, acc0);
        acc1 = dimFma(qv11, blocks, bi, 11, scale, acc1);
        acc0 = dimFma(qv12, blocks, bi, 12, scale, acc0);
        acc1 = dimFma(qv13, blocks, bi, 13, scale, acc1);

        const acc = acc0 + acc1;
        // acc - worst_d.* < 0  →  sign bit set  →  acc < worst_d.*
        const diff2 = acc - @as(@Vector(8, f32), @splat(worst_d.*));
        const mask2 = vmovmskps(diff2);
        if (mask2 == 0) continue;

        var dists_buf: [8]f32 = undefined;
        @as(*[8]f32, @ptrCast(&dists_buf)).* = acc;
        var m2 = mask2;
        while (m2 != 0) {
            const slot = @ctz(m2);
            m2 &= m2 - 1;
            if (blocks[bi * BLOCK_STRIDE + slot] == std.math.maxInt(i16)) continue;
            const dist = dists_buf[slot];
            if (dist < worst_d.*) {
                tryInsertTop5(dist, labels[label_base + slot], best_d, best_l, worst, worst_d);
            }
        }
    }
}

fn scanBlocksScalar(
    start_block: usize,
    end_block: usize,
    q: [DIM]i16,
    ds: *const dataset.Dataset,
    best_d: *[5]f32,
    best_l: *[5]u8,
    worst: *usize,
    worst_d: *f32,
) void {
    const blocks = ds.blocks.ptr;
    const labels = ds.labels.ptr;
    const vscale = VECTOR_SCALE;

    for (start_block..end_block) |bi| {
        const b = blocks + bi * BLOCK_STRIDE;
        const lb = labels + bi * 8;

        for (0..8) |slot| {
            if (b[slot] == std.math.maxInt(i16)) continue;
            var dist: f32 = 0.0;
            for (0..DIM) |j| {
                const dv = @as(f32, @floatFromInt(b[j * 8 + slot])) * vscale;
                const diff = dv - @as(f32, @floatFromInt(q[j])) * vscale;
                dist += diff * diff;
            }
            if (dist < worst_d.*) {
                tryInsertTop5(dist, lb[slot], best_d, best_l, worst, worst_d);
            }
        }
    }
}

fn scanBlocks(
    start_block: usize,
    end_block: usize,
    q: [DIM]i16,
    ds: *const dataset.Dataset,
    best_d: *[5]f32,
    best_l: *[5]u8,
    worst: *usize,
    worst_d: *f32,
) void {
    if (have_avx2) {
        scanBlocksAvx2(start_block, end_block, q, ds, best_d, best_l, worst, worst_d);
    } else {
        scanBlocksScalar(start_block, end_block, q, ds, best_d, best_l, worst, worst_d);
    }
}

// --- Search ---

fn countFrauds5(best_l: [5]u8) u8 {
    var count: u8 = 0;
    for (best_l) |l| {
        if (l == 1) count += 1;
    }
    return count;
}

pub fn searchWithNprobe(
    nprobe_to_use: usize,
    best_c: []const i32,
    q: [DIM]i16,
    ds: *const dataset.Dataset,
) u8 {
    var nprobe = nprobe_to_use;
    if (nprobe > IVF_CLUSTERS) nprobe = IVF_CLUSTERS;
    if (nprobe < 1) nprobe = 1;

    var best_d: [5]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var best_l: [5]u8 = .{ 0, 0, 0, 0, 0 };
    var worst: usize = 0;
    var worst_d: f32 = std.math.inf(f32);

    for (0..nprobe) |pi| {
        const c: i32 = best_c[pi];
        if (c < 0) continue;
        const cu: usize = @intCast(c);
        const range = ds.clusterBlockRange(cu);
        if (range.end <= range.start) continue;

        var end_block = range.end;
        if (g_candidates > 0) {
            const max_blocks = (g_candidates + 7) / 8;
            if (end_block - range.start > max_blocks) {
                end_block = range.start + max_blocks;
            }
        }
        scanBlocks(range.start, end_block, q, ds, &best_d, &best_l, &worst, &worst_d);
    }

    return countFrauds5(best_l);
}

pub fn search(query: [DIM]f32, ds: *const dataset.Dataset) u8 {
    var q_i16: [DIM]i16 = undefined;
    var q_grid: [DIM]f32 = undefined;
    for (0..DIM) |j| {
        q_i16[j] = quantize(query[j]);
        q_grid[j] = @as(f32, @floatFromInt(q_i16[j])) / FIX_SCALE;
    }

    var fast_nprobe = g_nprobe;
    if (fast_nprobe > IVF_MAX_NPROBE) fast_nprobe = IVF_MAX_NPROBE;
    if (fast_nprobe > IVF_CLUSTERS) fast_nprobe = IVF_CLUSTERS;

    var full_nprobe = g_full_nprobe;
    if (full_nprobe < fast_nprobe) full_nprobe = fast_nprobe;
    if (full_nprobe > IVF_MAX_NPROBE) full_nprobe = IVF_MAX_NPROBE;
    if (full_nprobe > IVF_CLUSTERS) full_nprobe = IVF_CLUSTERS;

    // Compute all centroid distances
    var dists: [IVF_CLUSTERS]f32 = undefined;
    if (have_avx2) {
        computeCentroidDistsAvx2(q_grid, ds, &dists);
    } else {
        computeCentroidDistsScalar(q_grid, ds, &dists);
    }

    // Keep top full_nprobe clusters
    var best_c: [IVF_MAX_NPROBE]i32 = [_]i32{-1} ** IVF_MAX_NPROBE;
    var best_p: [IVF_MAX_NPROBE]f32 = [_]f32{std.math.floatMax(f32)} ** IVF_MAX_NPROBE;
    if (have_avx2) {
        topNFromDistsAvx2(full_nprobe, &dists, &best_c, &best_p);
    } else {
        topNFromDistsScalar(full_nprobe, &dists, &best_c, &best_p);
    }

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

    // Fast pass
    const result = searchWithNprobe(fast_nprobe, &best_c, q_i16, ds);

    // Two-stage: if ambiguous (2 or 3 frauds), re-run with full probes
    if (result == 2 or result == 3) {
        return searchWithNprobe(full_nprobe, &best_c, q_i16, ds);
    }

    return result;
}

/// Warm CPU caches with random queries
pub fn warmup(ds: *const dataset.Dataset) void {
    var state: u32 = 0x12345678;
    for (0..500) |_| {
        var q: [DIM]f32 = undefined;
        for (&q) |*v| {
            state = state *% 1664525 +% 1013904223;
            v.* = @as(f32, @floatFromInt(state >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24));
        }
        _ = search(q, ds);
    }
}
