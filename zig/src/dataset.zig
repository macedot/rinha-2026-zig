const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});
const config = @import("config.zig");

const DIM = config.DIM;
const IVF_CLUSTERS = config.IVF_CLUSTERS;
const BLOCK_STRIDE = config.BLOCK_STRIDE;

const CFile = struct {
    fp: ?*c.FILE,

    fn open(path: [*:0]const u8) !CFile {
        const fp = c.fopen(path, "rb");
        if (fp == null) return error.FileNotFound;
        return CFile{ .fp = fp };
    }

    fn close(self: *CFile) void {
        _ = c.fclose(self.fp);
        self.fp = null;
    }

    fn read(self: *CFile, buf: []u8) !usize {
        const n = c.fread(buf.ptr, 1, buf.len, self.fp);
        if (n != buf.len and c.feof(self.fp) == 0) return error.ReadError;
        return n;
    }

    fn readInt(self: *CFile, comptime T: type) !T {
        var buf: [@sizeOf(T)]u8 = undefined;
        _ = try self.read(&buf);
        return std.mem.readInt(T, &buf, .little);
    }
};

pub const Dataset = struct {
    n: usize,
    total_blocks: usize,
    padded_n: usize,
    centroids_t: []f32,
    block_offsets: [IVF_CLUSTERS + 1]u32,
    labels: []u8,
    blocks: []i16,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Dataset {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        var file = try CFile.open(path_z);
        defer file.close();

        // Magic: "IVF1"
        var magic: [4]u8 = undefined;
        _ = try file.read(&magic);
        if (!std.mem.eql(u8, &magic, "IVF1")) {
            std.debug.print("index invalido: magic != IVF1\n", .{});
            return error.InvalidIndex;
        }

        const n = try file.readInt(u32);
        const k = try file.readInt(u32);
        const d = try file.readInt(u32);

        if (k != IVF_CLUSTERS or d != DIM) {
            std.debug.print("index incompativel: K={} D={}\n", .{ k, d });
            return error.InvalidIndex;
        }

        // Transposed centroids: DIM * IVF_CLUSTERS floats, align(32)
        const centroids_len = DIM * IVF_CLUSTERS;
        const centroids_t = try allocator.alignedAlloc(f32, 32, centroids_len);
        errdefer allocator.free(centroids_t);
        const centroids_bytes = std.mem.sliceAsBytes(centroids_t);
        _ = try file.read(centroids_bytes);

        // Block offsets: K+1 uint32
        var block_offsets: [IVF_CLUSTERS + 1]u32 = undefined;
        const offsets_bytes = std.mem.sliceAsBytes(block_offsets[0..]);
        _ = try file.read(offsets_bytes);

        const total_blocks: usize = @intCast(block_offsets[IVF_CLUSTERS]);
        const padded_n = total_blocks * 8;

        // Labels: padded_n uint8
        const labels = try allocator.alignedAlloc(u8, 64, padded_n);
        errdefer allocator.free(labels);
        _ = try file.read(labels);

        // Blocks: total_blocks * BLOCK_STRIDE int16, align(32)
        const blocks_len = total_blocks * BLOCK_STRIDE;
        const blocks = try allocator.alignedAlloc(i16, 32, blocks_len);
        errdefer allocator.free(blocks);
        const blocks_bytes = std.mem.sliceAsBytes(blocks);
        _ = try file.read(blocks_bytes);

        const mb = @as(f64, @floatFromInt(blocks_len * @sizeOf(i16) + padded_n + centroids_len * @sizeOf(f32) + (IVF_CLUSTERS + 1) * @sizeOf(u32))) / (1024.0 * 1024.0);
        std.debug.print("index IVF1 carregado (Zig): N={} K={} blocks={} memoria={d:.2} MB\n", .{ n, k, total_blocks, mb });

        return Dataset{
            .n = @intCast(n),
            .total_blocks = total_blocks,
            .padded_n = padded_n,
            .centroids_t = centroids_t,
            .block_offsets = block_offsets,
            .labels = labels,
            .blocks = blocks,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dataset) void {
        self.allocator.free(self.centroids_t);
        self.allocator.free(self.labels);
        self.allocator.free(self.blocks);
    }

    pub fn clusterBlockRange(self: *const Dataset, cluster: usize) struct { start: usize, end: usize } {
        return .{
            .start = @intCast(self.block_offsets[cluster]),
            .end = @intCast(self.block_offsets[cluster + 1]),
        };
    }
};
