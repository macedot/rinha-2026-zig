const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const Table = struct {
    entries: std.StringHashMap(f32),

    pub fn init(allocator: std.mem.Allocator) Table {
        return Table{ .entries = std.StringHashMap(f32).init(allocator) };
    }

    pub fn deinit(self: *Table) void {
        self.entries.deinit();
    }

    pub fn get(self: *const Table, mcc: []const u8) f32 {
        return self.entries.get(mcc) orelse 0.50;
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Table {
    var table = Table.init(allocator);
    errdefer table.deinit();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c.fopen(path_z, "rb");
    if (fp == null) return error.FileNotFound;
    defer _ = c.fclose(fp);

    // Read entire file into buffer
    var buf: [100 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, fp);
    const content = buf[0..n];

    // Simple JSON object parser
    var pos: usize = 0;
    while (pos < content.len) : (pos += 1) {
        if (content[pos] == '"') {
            pos += 1;
            const key_start = pos;
            while (pos < content.len and content[pos] != '"') : (pos += 1) {}
            const key = content[key_start..pos];
            pos += 1;

            // Find ':'
            while (pos < content.len and content[pos] != ':') : (pos += 1) {}
            pos += 1;

            // Find number
            while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '\r')) : (pos += 1) {}
            const num_start = pos;
            while (pos < content.len and (std.ascii.isDigit(content[pos]) or content[pos] == '.' or content[pos] == 'e' or content[pos] == 'E' or content[pos] == '-' or content[pos] == '+')) : (pos += 1) {}
            const num_str = content[num_start..pos];

            const value = std.fmt.parseFloat(f32, num_str) catch 0.50;
            try table.entries.put(try allocator.dupe(u8, key), value);
        }
    }

    return table;
}
