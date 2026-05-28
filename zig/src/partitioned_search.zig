const std = @import("std");
const partitioned_dataset = @import("partitioned_dataset.zig");

const NUM_PARTITIONS = partitioned_dataset.NUM_PARTITIONS;
const CLUSTERS_PER_PART = partitioned_dataset.CLUSTERS_PER_PART;
const DIM: usize = 14;
const K: usize = 5;
const NPROBE_INITIAL: usize = 10;

pub const SearchResult = struct {
    approved: bool,
    fraud_score: f32,
};

/// Compute the 2-bit partition tag exactly as in the ASM reference
pub fn computePartitionTag(q: [DIM]i16) u8 {
    const bit0: u8 = if (q[5] >= 0) 1 else 0;
    const bit1: u8 = if (q[11] > 0) 2 else 0;
    return bit0 | bit1;
}

/// Lower bound using int16 bbox (exact match to C implementation)
fn bboxLbI16(q: [DIM]i16, minv: []const i16, maxv: []const i16) i64 {
    var lb: i64 = 0;
    for (0..DIM) |d| {
        var diff: i64 = 0;
        if (q[d] > maxv[d]) {
            diff = @as(i64, q[d]) - maxv[d];
        } else if (q[d] < minv[d]) {
            diff = @as(i64, minv[d]) - q[d];
        }
        lb += diff * diff;
    }
    return lb;
}

/// Simple K=5 top-k (we can optimize later)
const TopK = struct {
    dists: [K]f32 = [_]f32{std.math.floatMax(f32)} ** K,
    labels: [K]u8 = [_]u8{0} ** K,

    fn insert(self: *TopK, dist: f32, label: u8) void {
        if (dist >= self.dists[K-1]) return;

        var pos: usize = K - 1;
        while (pos > 0 and dist < self.dists[pos-1]) : (pos -= 1) {
            self.dists[pos] = self.dists[pos-1];
            self.labels[pos] = self.labels[pos-1];
        }
        self.dists[pos] = dist;
        self.labels[pos] = label;
    }

    fn fraudCount(self: *const TopK) u32 {
        var cnt: u32 = 0;
        for (self.labels) |lbl| {
            if (lbl != 0) cnt += 1;
        }
        return cnt;
    }
};

pub fn search(index: *const partitioned_dataset.PartitionedIndex, q: [DIM]i16) SearchResult {
    const tag = computePartitionTag(q);
    const part = &index.partitions[tag];

    // 1. Compute lower bounds for all 2048 clusters
    var lb_dists: [CLUSTERS_PER_PART]struct { dist: f32, idx: u16 } = undefined;
    for (0..CLUSTERS_PER_PART) |c| {
        const min_ptr = part.bbox_min[c * DIM .. (c + 1) * DIM];
        const max_ptr = part.bbox_max[c * DIM .. (c + 1) * DIM];
        const lb = bboxLbI16(q, min_ptr, max_ptr);
        lb_dists[c] = .{ .dist = @floatFromInt(lb), .idx = @intCast(c) };
    }

    // Sort by lower bound (ascending) — manual for Zig std compatibility in this env
    // (on normal Zig this can go back to std.sort)
    {
        var i: usize = 1;
        while (i < lb_dists.len) : (i += 1) {
            const key = lb_dists[i];
            var j: usize = i;
            while (j > 0 and lb_dists[j - 1].dist > key.dist) : (j -= 1) {
                lb_dists[j] = lb_dists[j - 1];
            }
            lb_dists[j] = key;
        }
    }

    var topk: TopK = .{};

    // 2. Probe first NPROBE_INITIAL clusters
    var probed: usize = 0;
    const nprobe: usize = NPROBE_INITIAL;

    for (0..nprobe) |pi| {
        if (pi >= CLUSTERS_PER_PART) break;
        const c = lb_dists[pi].idx;
        if (lb_dists[pi].dist >= topk.dists[K-1]) break;

        scanCluster(part, c, q, &topk);
        probed += 1;
    }

    // 3. Repair logic
    const fcnt = topk.fraudCount();
    if (fcnt >= 1 and fcnt <= 4) {
        for (nprobe..CLUSTERS_PER_PART) |pi| {
            const c = lb_dists[pi].idx;
            if (lb_dists[pi].dist >= topk.dists[K-1]) break;
            scanCluster(part, c, q, &topk);
            probed += 1;
        }
    }

    // 4. Final decision (K=5 unweighted count)
    const frauds = topk.fraudCount();
    const score = @as(f32, @floatFromInt(frauds)) / 5.0;
    const approved = frauds <= 2;

    return .{ .approved = approved, .fraud_score = score };
}

fn scanCluster(part: *const partitioned_dataset.Partition, cluster_id: u16, q: [DIM]i16, topk: *TopK) void {
    const start = part.offsets[cluster_id];
    const end = part.offsets[cluster_id + 1];
    if (end <= start) return;

    const base = start * DIM;

    for (start..end) |i| {
        const vec = part.data_i16[base + (i - start) * DIM ..][0..DIM];

        var sum: i64 = 0;
        inline for (0..DIM) |d| {
            const diff: i64 = @as(i64, q[d]) - vec[d];
            sum += diff * diff;
        }

        const dist: f32 = @floatFromInt(sum);
        if (dist < topk.dists[4]) {
            topk.insert(dist, part.labels[i]);
        }
    }
}
