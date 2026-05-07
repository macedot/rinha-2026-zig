const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

const DIM = 14;
const K = 4096;
const FIX_SCALE = 10000.0;
const BLOCK_STRIDE = 112;
const N_ITER = 25;

const Item = struct {
    vector: [DIM]f32,
    label: u8,
};

fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fp = c.fopen(path_z.ptr, "rb");
    if (fp == null) return error.FileNotFound;
    defer _ = c.fclose(fp);

    var capacity: usize = 1024 * 1024;
    var buf = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buf);
    var total: usize = 0;

    var tmp: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&tmp, 1, tmp.len, fp);
        if (n == 0) break;
        if (total + n > capacity) {
            while (total + n > capacity) capacity *= 2;
            const new_buf = try allocator.realloc(buf, capacity);
            buf = new_buf;
        }
        @memcpy(buf[total..total + n], tmp[0..n]);
        total += n;
    }

    const result = try allocator.alloc(u8, total);
    @memcpy(result, buf[0..total]);
    allocator.free(buf);
    return result;
}


fn parseReferences(allocator: std.mem.Allocator, json_text: []const u8) !std.ArrayList(Item) {
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(allocator);

    // Simple streaming parse: look for {"vector":[...],"label":"..."}
    var pos: usize = 0;
    while (pos < json_text.len) {
        const vec_idx = std.mem.indexOfPos(u8, json_text, pos, "\"vector\"") orelse break;
        pos = vec_idx + 8;

        // Find '['
        while (pos < json_text.len and json_text[pos] != '[') pos += 1;
        if (pos >= json_text.len) break;
        pos += 1;

        var item: Item = undefined;
        var dim: usize = 0;
        while (dim < DIM and pos < json_text.len) : (dim += 1) {
            while (pos < json_text.len and (json_text[pos] == ' ' or json_text[pos] == '\n' or json_text[pos] == '\r' or json_text[pos] == '\t')) pos += 1;
            const start = pos;
            while (pos < json_text.len and json_text[pos] != ',' and json_text[pos] != ']') pos += 1;
            const num_str = std.mem.trim(u8, json_text[start..pos], " \t\n\r");
            item.vector[dim] = try std.fmt.parseFloat(f32, num_str);
            if (pos < json_text.len and json_text[pos] == ',') pos += 1;
        }
        if (dim != DIM) continue;

        // Find "label"
        const label_idx = std.mem.indexOfPos(u8, json_text, pos, "\"label\"") orelse continue;
        pos = label_idx + 7;
        while (pos < json_text.len and json_text[pos] != '"') pos += 1;
        if (pos >= json_text.len) break;
        pos += 1;
        item.label = if (pos + 5 <= json_text.len and std.mem.eql(u8, json_text[pos..pos + 5], "fraud")) 1 else 0;

        try items.append(allocator, item);
        if (items.items.len % 500000 == 0) {
            std.debug.print("parseados {} vetores\n", .{items.items.len});
        }
    }

    return items;
}

fn distSq(a: [DIM]f32, b: [DIM]f32) f32 {
    var d: f32 = 0.0;
    for (0..DIM) |i| {
        const diff = a[i] - b[i];
        d += diff * diff;
    }
    return d;
}

const Lcg = struct {
    state: u64,

    fn new(seed: u64) Lcg {
        return Lcg{ .state = seed };
    }

    fn nextU64(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }

    fn nextUsize(self: *Lcg, n: usize) usize {
        return @intCast((self.nextU64() >> 33) % n);
    }

    fn nextF64(self: *Lcg) f64 {
        return @as(f64, @floatFromInt(self.nextU64() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

fn kmeansPlusPlusInit(vectors: [][DIM]f32, k: usize, seed: u64) ![][DIM]f32 {
    const sample_size = @min(vectors.len, 50_000);
    var rng = Lcg.new(seed);

    var sample = try std.heap.page_allocator.alloc(usize, sample_size);
    defer std.heap.page_allocator.free(sample);
    for (0..sample_size) |i| {
        sample[i] = rng.nextUsize(vectors.len);
    }

    var centroids = try std.heap.page_allocator.alloc([DIM]f32, k);
    errdefer std.heap.page_allocator.free(centroids);

    centroids[0] = vectors[sample[rng.nextUsize(sample_size)]];

    var min_dists = try std.heap.page_allocator.alloc(f32, sample_size);
    defer std.heap.page_allocator.free(min_dists);
    @memset(min_dists, std.math.inf(f32));

    for (1..k) |ci| {
        const last = centroids[ci - 1];
        for (sample, 0..) |vi, i| {
            const d = distSq(vectors[vi], last);
            if (d < min_dists[i]) {
                min_dists[i] = d;
            }
        }
        var total: f64 = 0.0;
        for (min_dists) |d| {
            total += @as(f64, d);
        }
        const r = rng.nextF64() * total;
        var cum: f64 = 0.0;
        var chosen = sample_size - 1;
        for (min_dists, 0..) |d, i| {
            cum += @as(f64, d);
            if (cum >= r) {
                chosen = @intCast(i);
                break;
            }
        }
        centroids[ci] = vectors[sample[chosen]];
    }

    return centroids;
}

fn nearestCentroid(v: [DIM]f32, centroids: [][DIM]f32) u16 {
    var best_dist: f32 = std.math.inf(f32);
    var best_idx: u16 = 0;
    for (centroids, 0..) |cent, i| {
        const d = distSq(v, cent);
        if (d < best_dist) {
            best_dist = d;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

fn assignParallel(vectors: [][DIM]f32, centroids: [][DIM]f32, assignments: []u16) usize {
    var changed: usize = 0;
    for (vectors, 0..) |v, i| {
        const best = nearestCentroid(v, centroids);
        if (best != assignments[i]) {
            assignments[i] = best;
            changed += 1;
        }
    }
    return changed;
}

fn updateCentroids(vectors: [][DIM]f32, assignments: []const u16, centroids: [][DIM]f32) void {
    const k = centroids.len;
    var sums = std.heap.page_allocator.alloc([DIM]f64, k) catch return;
    defer std.heap.page_allocator.free(sums);
    @memset(std.mem.sliceAsBytes(sums), 0);
    var counts = std.heap.page_allocator.alloc(u32, k) catch return;
    defer std.heap.page_allocator.free(counts);
    @memset(std.mem.sliceAsBytes(counts), 0);

    for (vectors, assignments) |v, a| {
        const ci: usize = a;
        counts[ci] += 1;
        for (0..DIM) |d| {
            sums[ci][d] += @as(f64, v[d]);
        }
    }

    for (0..k) |i| {
        if (counts[i] == 0) continue;
        const inv = 1.0 / @as(f64, @floatFromInt(counts[i]));
        for (0..DIM) |d| {
            centroids[i][d] = @as(f32, @floatCast(sums[i][d] * inv));
        }
    }
}

fn quantizeI16(v: f32) i16 {
    const scaled = v * FIX_SCALE;
    return @intFromFloat(@round(scaled));
}

fn writeIndex(
    path: []const u8,
    vectors: [][DIM]f32,
    labels: []const u8,
    assignments: []const u16,
    centroids: [][DIM]f32,
    n: usize,
) !void {
    const k = centroids.len;

    var cluster_vecs = try std.heap.page_allocator.alloc(std.ArrayList(usize), k);
    defer {
        for (cluster_vecs) |*cv| cv.deinit(std.heap.page_allocator);
        std.heap.page_allocator.free(cluster_vecs);
    }
    for (0..k) |ci| {
        cluster_vecs[ci] = .empty;
    }

    for (assignments, 0..) |a, i| {
        try cluster_vecs[a].append(std.heap.page_allocator, i);
    }

    var block_offsets = try std.heap.page_allocator.alloc(u32, k + 1);
    defer std.heap.page_allocator.free(block_offsets);
    block_offsets[0] = 0;
    for (0..k) |ci| {
        const sz: u32 = @intCast(cluster_vecs[ci].items.len);
        block_offsets[ci + 1] = block_offsets[ci] + (sz + 7) / 8;
    }
    const total_blocks = block_offsets[k];
    const padded_n = total_blocks * 8;

    var out_labels = try std.heap.page_allocator.alloc(u8, padded_n);
    defer std.heap.page_allocator.free(out_labels);
    @memset(out_labels, 0);
    var out_blocks = try std.heap.page_allocator.alloc(i16, total_blocks * BLOCK_STRIDE);
    defer std.heap.page_allocator.free(out_blocks);
    @memset(std.mem.sliceAsBytes(out_blocks), 0xff);

    for (0..k) |ci| {
        const block_start = block_offsets[ci];
        const n_blocks = block_offsets[ci + 1] - block_start;
        const vecs = cluster_vecs[ci].items;
        for (0..n_blocks) |bk| {
            const block_base = (block_start + bk) * BLOCK_STRIDE;
            const label_base = (block_start + bk) * 8;
            for (0..8) |slot| {
                const vi = bk * 8 + slot;
                if (vi < vecs.len) {
                    const v = vectors[vecs[vi]];
                    for (0..DIM) |d| {
                        out_blocks[block_base + d * 8 + slot] = quantizeI16(v[d]);
                    }
                    out_labels[label_base + slot] = labels[vecs[vi]];
                } else {
                    for (0..DIM) |d| {
                        out_blocks[block_base + d * 8 + slot] = std.math.maxInt(i16);
                    }
                }
            }
        }
    }

    var centroids_t = try std.heap.page_allocator.alloc(f32, DIM * k);
    defer std.heap.page_allocator.free(centroids_t);
    for (0..k) |ci| {
        for (0..DIM) |d| {
            centroids_t[d * k + ci] = centroids[ci][d];
        }
    }

    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const fp = c.fopen(path_z.ptr, "wb");
    if (fp == null) return error.CreateFileFailed;
    defer _ = c.fclose(fp);

    const writeAll = struct {
        fn f(file: ?*c.FILE, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            const wn = c.fwrite(bytes.ptr, 1, bytes.len, file);
            if (wn != bytes.len) return error.WriteFailed;
        }
    }.f;

    const magic = "IVF1";
    try writeAll(fp, magic);

    var u32_buf: [3]u32 = .{ @intCast(n), @intCast(k), DIM };
    try writeAll(fp, std.mem.sliceAsBytes(u32_buf[0..]));

    try writeAll(fp, std.mem.sliceAsBytes(centroids_t));
    try writeAll(fp, std.mem.sliceAsBytes(block_offsets[0..]));
    try writeAll(fp, out_labels);
    try writeAll(fp, std.mem.sliceAsBytes(out_blocks));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = std.process.args();
    _ = args.skip(); // skip program name
    const input_path_arg = args.next();
    const output_path_arg = args.next();
    const input_path = if (input_path_arg) |a| a[0..a.len] else "resources/references.json.gz";
    const output_path = if (output_path_arg) |a| a[0..a.len] else "data/index.bin";

    std.debug.print("lendo references: {s}\n", .{input_path});

    const json_text = try readAll(allocator, input_path);
    defer allocator.free(json_text);

    std.debug.print("lido: {} bytes\n", .{json_text.len});

    var items = try parseReferences(allocator, json_text);
    defer items.deinit(allocator);
    const n = items.items.len;
    std.debug.print("vetores carregados: {}\n", .{n});

    var vectors = try std.heap.page_allocator.alloc([DIM]f32, n);
    defer std.heap.page_allocator.free(vectors);
    var labels = try std.heap.page_allocator.alloc(u8, n);
    defer std.heap.page_allocator.free(labels);
    for (items.items, 0..) |item, i| {
        vectors[i] = item.vector;
        labels[i] = item.label;
    }
    items.deinit(allocator);

    std.debug.print("kmeans++ init (sample={})...\n", .{@min(n, 50_000)});
    const centroids = try kmeansPlusPlusInit(vectors, K, 0xdeadbeef_cafebabe);
    defer std.heap.page_allocator.free(centroids);

    std.debug.print("lloyd iterations...\n", .{});
    const assignments = try std.heap.page_allocator.alloc(u16, n);
    defer std.heap.page_allocator.free(assignments);
    @memset(assignments, 0);

    for (0..N_ITER) |iter| {
        const changed = assignParallel(vectors, centroids, assignments);
        updateCentroids(vectors, assignments, centroids);
        const pct = @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(n)) * 100.0;
        std.debug.print("  iter {:2}: {d:.2}% changed\n", .{ iter + 1, pct });
        if (changed * 1000 < n) break;
    }

    std.debug.print("gravando {s}...\n", .{output_path});
    // Create parent dir if needed
    {
        const dir = std.fs.path.dirname(output_path) orelse ".";
        const dir_z = try std.heap.page_allocator.dupeZ(u8, dir);
        defer std.heap.page_allocator.free(dir_z);
        _ = std.c.mkdir(dir_z.ptr, 0o755);
    }

    try writeIndex(output_path, vectors, labels, assignments, centroids, n);
    std.debug.print("ok: IVF1 {s} (N={} K={})\n", .{ output_path, n, K });
}
