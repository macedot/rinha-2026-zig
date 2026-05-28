const std = @import("std");

// libc raw file reader (reliable and simple). The accuracy tester and future
// pure-Zig server link libc anyway, so this is the pragmatic choice for the project.
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

fn readFileRaw(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.CannotOpenFile;

    defer _ = c.close(fd);

    const buf = try allocator.alloc(u8, max_size);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) {
        allocator.free(buf);
        return error.ReadFailed;
    }

    return try allocator.realloc(buf, @intCast(n));
}

pub const NUM_PARTITIONS = 4;
pub const CLUSTERS_PER_PART = 2048;
pub const DIM = 14;

/// One partition of the ASM-style index (2048 flat clusters)
pub const Partition = struct {
    n_records: usize,

    // int16 data: [n_records][14]i16  (row-major)
    data_i16: []i16,

    // labels: [n_records]u8
    labels: []u8,

    // Per-cluster bbox (2048 * 14)
    bbox_min: []i16,
    bbox_max: []i16,

    // Cluster offsets: [2049]u32
    offsets: [CLUSTERS_PER_PART + 1]u32,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Partition) void {
        self.allocator.free(self.data_i16);
        self.allocator.free(self.labels);
        self.allocator.free(self.bbox_min);
        self.allocator.free(self.bbox_max);
    }
};

/// Full 4-partition index (exact layout produced by the C indexer at 119fb40)
pub const PartitionedIndex = struct {
    partitions: [NUM_PARTITIONS]Partition,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, base_path: []const u8) !PartitionedIndex {
        var idx = PartitionedIndex{
            .partitions = undefined,
            .allocator = allocator,
        };

        for (0..NUM_PARTITIONS) |p| {
            idx.partitions[p] = try loadPartition(allocator, base_path, @intCast(p));
        }

        return idx;
    }

    pub fn deinit(self: *PartitionedIndex) void {
        for (&self.partitions) |*part| {
            part.deinit();
        }
    }
};

fn loadPartition(allocator: std.mem.Allocator, base_path: []const u8, part_id: u8) !Partition {
    var part: Partition = undefined;
    part.allocator = allocator;

    const prefix = try std.fmt.allocPrint(allocator, "{s}/part{d}_", .{ base_path, part_id });
    defer allocator.free(prefix);

    // Uses the libc readFileRaw defined at top of file (reliable in this env)

    // Load data_i16
    const data_path = try std.fmt.allocPrint(allocator, "{s}data_i16.bin", .{prefix});
    defer allocator.free(data_path);
    const data_bytes = try readFileRaw(allocator, data_path, 256 * 1024 * 1024);
    defer allocator.free(data_bytes);

    const n_records = data_bytes.len / (DIM * @sizeOf(i16));
    part.n_records = n_records;

    part.data_i16 = try allocator.alloc(i16, n_records * DIM);
    @memcpy(std.mem.sliceAsBytes(part.data_i16), data_bytes);

    // Load labels
    const labels_path = try std.fmt.allocPrint(allocator, "{s}labels.bin", .{prefix});
    defer allocator.free(labels_path);
    const labels_bytes = try readFileRaw(allocator, labels_path, 32 * 1024 * 1024);
    defer allocator.free(labels_bytes);

    part.labels = try allocator.alloc(u8, n_records);
    @memcpy(part.labels, labels_bytes);

    // Load bbox min
    const bmin_path = try std.fmt.allocPrint(allocator, "{s}bbox_min_i16.bin", .{prefix});
    defer allocator.free(bmin_path);
    const bmin_bytes = try readFileRaw(allocator, bmin_path, 1024 * 1024);
    defer allocator.free(bmin_bytes);

    part.bbox_min = try allocator.alloc(i16, CLUSTERS_PER_PART * DIM);
    @memcpy(std.mem.sliceAsBytes(part.bbox_min), bmin_bytes);

    // Load bbox max
    const bmax_path = try std.fmt.allocPrint(allocator, "{s}bbox_max_i16.bin", .{prefix});
    defer allocator.free(bmax_path);
    const bmax_bytes = try readFileRaw(allocator, bmax_path, 1024 * 1024);
    defer allocator.free(bmax_bytes);

    part.bbox_max = try allocator.alloc(i16, CLUSTERS_PER_PART * DIM);
    @memcpy(std.mem.sliceAsBytes(part.bbox_max), bmax_bytes);

    // Load offsets
    const offsets_path = try std.fmt.allocPrint(allocator, "{s}offsets.bin", .{prefix});
    defer allocator.free(offsets_path);
    const offsets_bytes = try readFileRaw(allocator, offsets_path, 16 * 1024);
    defer allocator.free(offsets_bytes);

    const offsets_u32 = std.mem.bytesAsSlice(u32, offsets_bytes);
    if (offsets_u32.len != CLUSTERS_PER_PART + 1) {
        return error.InvalidOffsets;
    }
    @memcpy(part.offsets[0..], offsets_u32);

    return part;
}
