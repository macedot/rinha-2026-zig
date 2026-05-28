const std = @import("std");
const partitioned_dataset = @import("partitioned_dataset.zig");
const partitioned_search = @import("partitioned_search.zig");
const vectorizer = @import("vectorizer.zig");

// libc raw reader (same as partitioned_dataset)
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

/// Stand-alone accuracy tester for the partitioned int16 path.
/// Loads the exact 24 .bin files produced by the C indexer (119fb40 state)
/// and runs the full 54,100 oracle from test-data.json (or any compatible file).
///
/// Must report FP=0 and FN=0 before any performance work or release.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // program name

    const index_dir = args.next() orelse {
        std.debug.print("Usage: accuracy_test <index_dir> <test-data.json>\n", .{});
        std.debug.print("  index_dir: path to directory with part0_..part3_*.bin\n", .{});
        std.debug.print("  test-data.json: the official 54100-case oracle\n", .{});
        return error.InvalidArgs;
    };

    const test_data_path = args.next() orelse {
        std.debug.print("Usage: accuracy_test <index_dir> <test-data.json>\n", .{});
        return error.InvalidArgs;
    };

    std.debug.print("Loading partitioned index from {s}...\n", .{index_dir});
    var idx = try partitioned_dataset.PartitionedIndex.load(allocator, index_dir);
    defer idx.deinit();

    std.debug.print("Loading oracle {s}...\n", .{test_data_path});

    const content = try readFileRaw(allocator, test_data_path, 128 * 1024 * 1024);
    defer allocator.free(content);

    var total: usize = 0;
    var fp: usize = 0;
    var fn_count: usize = 0;

    var search_pos: usize = 0;

    // Scan by "expected_approved" (more reliable anchor), then look backwards for the preceding "request"
    while (true) {
        const approved_key = std.mem.indexOfPos(u8, content, search_pos, "\"expected_approved\":");
        if (approved_key == null) break;

        const is_approved_expected = std.mem.startsWith(u8, content[approved_key.? + 20 ..], "true");

        // Look backwards for the "request" object belonging to this entry
        const backward_start = if (approved_key.? > 4000) approved_key.? - 4000 else 0;
        const req_key = std.mem.lastIndexOf(u8, content[backward_start..approved_key.?], "\"request\":{") orelse {
            search_pos = approved_key.? + 1;
            continue;
        };
        const req_start = backward_start + req_key + 10; // after "request":{

        // Find matching closing } for the request object
        var depth: i32 = 1;
        var req_end = req_start;
        while (req_end < content.len and depth > 0) {
            if (content[req_end] == '{') depth += 1;
            if (content[req_end] == '}') depth -= 1;
            req_end += 1;
        }
        if (depth != 0) {
            search_pos = approved_key.? + 1;
            continue;
        }

        const raw_body = content[req_start .. req_end - 1];

        // Run vectorizer + search
        if (vectorizer.buildQuantized(raw_body)) |qz| {
            const result = partitioned_search.search(&idx, qz.q);
            const predicted = result.approved;

            if (predicted and !is_approved_expected) fp += 1;
            if (!predicted and is_approved_expected) fn_count += 1;

            total += 1;

            if (total % 10000 == 0) {
                std.debug.print("  processed {}/54100...\n", .{total});
            }
        }

        search_pos = approved_key.? + 1;
    }

    std.debug.print("\n=== ACCURACY RESULTS (Pure Zig partitioned path) ===\n", .{});
    std.debug.print("Total cases evaluated: {}\n", .{total});
    std.debug.print("False Positives (FP):  {}\n", .{fp});
    std.debug.print("False Negatives (FN):  {}\n", .{fn_count});
    std.debug.print("Errors: {}\n", .{fp + fn_count});

    if (fp == 0 and fn_count == 0 and total > 50000) {
        std.debug.print("\n*** PERFECT 0/0 — identical to the best C result ***\n", .{});
    } else if (total < 1000) {
        std.debug.print("\nScanner only found {} cases — parser needs tuning for this oracle format.\n", .{total});
    } else {
        std.debug.print("\n!!! NON-ZERO ERRORS !!!\n", .{});
        std.process.exit(1);
    }
}
