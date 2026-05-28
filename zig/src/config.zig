const std = @import("std");

pub const Config = struct {
    index_path: []u8,
    host: []u8,
    uds_path: []u8,
    // Old IVF params removed — new architecture uses hardcoded NPROBE=10 + repair
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const index_path = try allocator.dupe(u8, std.process.getEnvVarOwned(allocator, "INDEX_PATH") catch "/app/data");
    const host = try allocator.dupe(u8, "0.0.0.0");
    const uds_path = try allocator.dupe(u8, std.process.getEnvVarOwned(allocator, "UDS_PATH") catch "/tmp/rinha.sock");

    return .{
        .index_path = index_path,
        .host = host,
        .uds_path = uds_path,
    };
}