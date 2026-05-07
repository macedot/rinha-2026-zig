const std = @import("std");

pub const DIM: usize = 14;
pub const K_NEIGHBORS: usize = 5;
pub const FIX_SCALE: f32 = 10000.0;
pub const VECTOR_SCALE: f32 = 1.0 / FIX_SCALE;
pub const IVF_CLUSTERS: usize = 4096;
pub const IVF_MAX_NPROBE: usize = 64;
pub const BLOCK_STRIDE: usize = 112; // 8 slots * 14 dims

pub const Config = struct {
    index_path: []const u8,
    ivf_nprobe: usize,
    ivf_full_nprobe: usize,
    candidates: usize,
    use_tcp: bool,
    port: u16,
    host: []const u8,
    uds_path: []const u8,
    uds_mode: u32,
    unlink_uds: bool,
    tcp_nodelay: bool,
    reuse_port: bool,
};

pub fn load(allocator: std.mem.Allocator) !Config {
    return Config{
        .index_path = try envStr(allocator, "INDEX_PATH", "resources/index.bin"),
        .ivf_nprobe = envInt("IVF_NPROBE", 8, 1, IVF_MAX_NPROBE),
        .ivf_full_nprobe = envInt("IVF_FULL_NPROBE", 24, 1, IVF_MAX_NPROBE),
        .candidates = envInt("CANDIDATES", 0, 0, 2000000),
        .use_tcp = envBool("LISTEN_TCP", false),
        .port = @intCast(envInt("PORT", 9999, 1, 65535)),
        .host = try envStr(allocator, "HOST", "0.0.0.0"),
        .uds_path = blk: {
            var name_buf: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "UDS_PATH", .{}) catch break :blk try envStr(allocator, "SOCKET_PATH", "/tmp/rinha.sock");
            const p = getenvZ(name_z.ptr);
            if (p == null) break :blk try envStr(allocator, "SOCKET_PATH", "/tmp/rinha.sock");
            break :blk try allocator.dupe(u8, p.?);
        },
        .uds_mode = @intCast(envInt("UDS_MODE", 666, 0, 777)),
        .unlink_uds = envBool("UNLINK_UDS", true),
        .tcp_nodelay = envBool("TCP_NODELAY", true),
        .reuse_port = envBool("SO_REUSEPORT_ENABLED", true),
    };
}

fn getenvZ(name_z: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name_z);
    if (ptr) |p| {
        return std.mem.sliceTo(p, 0);
    }
    return null;
}

fn envStr(allocator: std.mem.Allocator, name: []const u8, default: []const u8) ![]const u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const v = getenvZ(name_z.ptr);
    if (v) |val| {
        return try allocator.dupe(u8, val);
    }
    return try allocator.dupe(u8, default);
}

fn envInt(name: []const u8, default: usize, minv: usize, maxv: usize) usize {
    // Use stack buffer for name
    var name_buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return default;
    const v = getenvZ(name_z.ptr) orelse return default;
    const x = std.fmt.parseInt(usize, v, 10) catch return default;
    if (x < minv) return minv;
    if (x > maxv) return maxv;
    return x;
}

fn envFloat(name: []const u8, default: f32, minv: f32, maxv: f32) f32 {
    var name_buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return default;
    const v = getenvZ(name_z.ptr) orelse return default;
    const x = std.fmt.parseFloat(f32, v) catch return default;
    if (x < minv) return minv;
    if (x > maxv) return maxv;
    return x;
}

fn envBool(name: []const u8, default: bool) bool {
    return envInt(name, if (default) 1 else 0, 0, 1) == 1;
}
