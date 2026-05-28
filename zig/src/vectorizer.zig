const std = @import("std");

/// VEC_DIM for the float feature vector (matches C VEC_DIM)
pub const VEC_DIM: usize = 16;
/// DIM for the actual feature dimensions used in distance (14 + 2 pads)
pub const DIM: usize = 14;
pub const SCALE: i16 = 10000;

/// Exact port of the successful C implementation (rinha-2026-c at commit 119fb40
/// and the ASM reference vectorize.asm path). This produces the canonical
/// ASM-linear 16-dim float features, then the i16 quantization + 2-bit partition
/// tag used for the 4-partition flat index (2048 clusters each) that achieved
/// FP=0, FN=0 and perfect 6000 score.
///
/// Key fidelity requirements (do not change without re-validating 0/0 on oracle):
/// - parse_iso8601 must match C byte-for-byte (civil calendar + tz offset after .frac)
/// - parse_f32 limited to 6 fractional digits + specific POW table (affects marginal floats)
/// - ratio defaults to 0.0 when customer_avg_amount == 0 (old Rust path used 1.0)
/// - hour/dow are linear [0,1] with NO round4 or sin/cos
/// - quantize: sentinel -SCALE for <= -0.5 (last_tx missing), else clamp [0,1] + lroundf(v*SCALE)
/// - partition tag computed on the *post-quant* i16 values (q[11]>0 for bit1, q[5]>=0 for bit0)
///   NOTE: indexer used float v11>0.5 for tagging records; query uses the i16 rule above.
///   Both are required exactly as-is for 0/0.

const MAX_AMOUNT: f32 = 10000.0;
const MAX_INSTALLMENTS: f32 = 12.0;
const MAX_AVG_RATIO: f32 = 10.0;
const MAX_KM: f32 = 1000.0;
const MAX_TX_COUNT: f32 = 20.0;
const MAX_MERCHANT_AVG: f32 = 10000.0;

/// MCC risk table (exact match to C init_mcc_risks)
const MCC_RISKS: [10]struct { mcc: u16, risk: f32 } = .{
    .{ .mcc = 5411, .risk = 0.15 },
    .{ .mcc = 5812, .risk = 0.30 },
    .{ .mcc = 5912, .risk = 0.20 },
    .{ .mcc = 5944, .risk = 0.45 },
    .{ .mcc = 7801, .risk = 0.80 },
    .{ .mcc = 7802, .risk = 0.75 },
    .{ .mcc = 7995, .risk = 0.85 },
    .{ .mcc = 4511, .risk = 0.35 },
    .{ .mcc = 5311, .risk = 0.25 },
    .{ .mcc = 5999, .risk = 0.50 },
};

fn mccRisk(mcc: u32) f32 {
    inline for (MCC_RISKS) |entry| {
        if (entry.mcc == mcc) return entry.risk;
    }
    return 0.5;
}

fn clamp01(v: f32) f32 {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

/// Exact port of C parse_iso8601 (the authoritative one used for both indexing
/// references and runtime query vectors in the 0/0 solution).
fn parseIso8601(s: []const u8) i64 {
    if (s.len < 19) return 0;
    if (s[4] != '-' or s[7] != '-') return 0;
    const sep = s[10];
    if (sep != 'T' and sep != ' ') return 0;
    if (s[13] != ':' or s[16] != ':') return 0;

    const y: i32 = @as(i32, s[0] - '0') * 1000 + @as(i32, s[1] - '0') * 100 + @as(i32, s[2] - '0') * 10 + @as(i32, s[3] - '0');
    const mo: i32 = @as(i32, s[5] - '0') * 10 + @as(i32, s[6] - '0');
    const da: i32 = @as(i32, s[8] - '0') * 10 + @as(i32, s[9] - '0');
    const hh: i32 = @as(i32, s[11] - '0') * 10 + @as(i32, s[12] - '0');
    const mi: i32 = @as(i32, s[14] - '0') * 10 + @as(i32, s[15] - '0');
    const se: i32 = @as(i32, s[17] - '0') * 10 + @as(i32, s[18] - '0');

    const y2 = y - (if (mo <= 2) @as(i32, 1) else 0);
    const era: i32 = if (y2 >= 0) @divFloor(y2, 400) else @divFloor(y2 - 399, 400);
    const yoe: i32 = y2 - era * 400;
    const m2: i32 = if (mo > 2) mo - 3 else mo + 9;
    const doy: i32 = @divTrunc(153 * m2 + 2, 5) + da - 1;
    const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    var epoch: i64 = @as(i64, era) * 146097 + doe - 719468;
    epoch = epoch * 86400 + @as(i64, hh) * 3600 + @as(i64, mi) * 60 + @as(i64, se);

    // fractional seconds + tz offset (exact C rules)
    var p: usize = 19;
    if (p < s.len and s[p] == '.') {
        p += 1;
        while (p < s.len and s[p] >= '0' and s[p] <= '9') : (p += 1) {}
    }
    if (p < s.len) {
        const c = s[p];
        if ((c == '+' or c == '-') and p + 6 <= s.len and s[p + 3] == ':') {
            const oh: i64 = @as(i64, s[p + 1] - '0') * 10 + @as(i64, s[p + 2] - '0');
            const om: i64 = @as(i64, s[p + 4] - '0') * 10 + @as(i64, s[p + 5] - '0');
            const off: i64 = oh * 3600 + om * 60;
            if (c == '+') {
                epoch -= off;
            } else {
                epoch += off;
            }
        }
    }
    return epoch;
}

/// Exact port of C's limited-precision parse_f32 (max 6 frac digits, specific POW table).
/// Critical for producing the exact same float feature values as the C vectorizer.
fn parseF32(p_in: []const u8, pos_in: *usize) f32 {
    var pos = pos_in.*;
    // skip leading ws (caller usually did it)
    while (pos < p_in.len and (p_in[pos] == ' ' or p_in[pos] == '\n' or p_in[pos] == '\r' or p_in[pos] == '\t')) : (pos += 1) {}
    var neg: i32 = 0;
    if (pos < p_in.len and p_in[pos] == '-') {
        neg = 1;
        pos += 1;
    }
    var int_part: u32 = 0;
    while (pos < p_in.len and p_in[pos] >= '0' and p_in[pos] <= '9') : (pos += 1) {
        int_part = int_part * 10 + @as(u32, p_in[pos] - '0');
    }
    var v: f32 = @floatFromInt(int_part);
    if (pos < p_in.len and p_in[pos] == '.') {
        pos += 1;
        var frac: u32 = 0;
        var frac_digits: u32 = 0;
        while (pos < p_in.len and p_in[pos] >= '0' and p_in[pos] <= '9' and frac_digits < 6) : (pos += 1) {
            frac = frac * 10 + @as(u32, p_in[pos] - '0');
            frac_digits += 1;
        }
        if (frac_digits > 0) {
            const POW10_NEG = [_]f32{ 1.0, 0.1, 0.01, 0.001, 0.0001, 0.00001, 0.000001 };
            v += @as(f32, @floatFromInt(frac)) * POW10_NEG[frac_digits];
        }
        while (pos < p_in.len and p_in[pos] >= '0' and p_in[pos] <= '9') : (pos += 1) {}
    }
    pos_in.* = pos;
    return if (neg != 0) -v else v;
}

// (parsePayload stub removed — build() now uses the json* helpers directly below for schema traversal + C-exact numeric/date logic)

// --- JSON helpers (kept from previous, known to work for schema traversal) ---

fn skipWS(p: []const u8) []const u8 {
    var i: usize = 0;
    while (i < p.len and (p[i] == ' ' or p[i] == '\n' or p[i] == '\r' or p[i] == '\t')) : (i += 1) {}
    return p[i..];
}

fn findKeyRange(data: []const u8, key: []const u8) ?[]const u8 {
    const pat = b: {
        var buf: [128]u8 = undefined;
        const b = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
        break :b b;
    };
    const i: usize = 0;
    while (i < data.len) {
        if (std.mem.indexOfPos(u8, data, i, pat)) |idx| {
            return data[idx..];
        } else break;
    }
    return null;
}

fn findChar(p: []const u8, ch: u8) ?usize {
    for (p, 0..) |c, i| {
        if (c == ch) return i;
    }
    return null;
}

fn matchingBrace(open: []const u8) ?usize {
    if (open.len == 0 or open[0] != '{') return null;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    for (open, 0..) |c, i| {
        if (in_str) {
            if (esc) { esc = false; continue; }
            if (c == '\\') { esc = true; continue; }
            if (c == '"') { in_str = false; continue; }
            continue;
        }
        if (c == '"') { in_str = true; continue; }
        if (c == '{') { depth += 1; continue; }
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn objectRange(data: []const u8, key: []const u8) ?[]const u8 {
    const k = findKeyRange(data, key) orelse return null;
    const colon_idx = findChar(k, ':') orelse return null;
    const p = skipWS(k[colon_idx + 1 ..]);
    if (p.len == 0 or p[0] != '{') return null;
    const close_idx = matchingBrace(p) orelse return null;
    return p[0..close_idx];
}

fn jsonNumber(data: []const u8, key: []const u8) ?f32 {
    const k = findKeyRange(data, key) orelse return null;
    const colon_idx = findChar(k, ':') orelse return null;
    const p = skipWS(k[colon_idx + 1 ..]);
    if (p.len == 0) return null;
    var end: usize = 0;
    while (end < p.len and (std.ascii.isDigit(p[end]) or p[end] == '-' or p[end] == '+' or p[end] == '.')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, p[0..end]) catch null;
}

/// Limited-precision number parser that mimics C parse_f32 (6 frac digits) for fidelity.
fn jsonNumberLimited(data: []const u8, key: []const u8) ?f32 {
    const k = findKeyRange(data, key) orelse return null;
    const colon_idx = findChar(k, ':') orelse return null;
    const p = skipWS(k[colon_idx + 1 ..]);
    if (p.len == 0) return null;
    var pos: usize = 0;
    const v = parseF32(p, &pos);
    if (pos == 0) return null;
    return v;
}

fn jsonBool(data: []const u8, key: []const u8) ?bool {
    const k = findKeyRange(data, key) orelse return null;
    const colon_idx = findChar(k, ':') orelse return null;
    const p = skipWS(k[colon_idx + 1 ..]);
    if (p.len >= 4 and std.mem.eql(u8, p[0..4], "true")) return true;
    if (p.len >= 5 and std.mem.eql(u8, p[0..5], "false")) return false;
    return null;
}

fn jsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const k = findKeyRange(data, key) orelse return null;
    const colon_idx = findChar(k, ':') orelse return null;
    const p = skipWS(k[colon_idx + 1 ..]);
    if (p.len == 0 or p[0] != '"') return null;
    var i: usize = 1;
    while (i < p.len and p[i] != '"') : (i += 1) {}
    if (i >= p.len) return null;
    return p[1..i];
}

fn arrayContainsString(data: []const u8, key: []const u8, needle: []const u8) bool {
    const k = findKeyRange(data, key) orelse return false;
    const colon_idx = findChar(k, ':') orelse return false;
    const lb = findChar(k[colon_idx..], '[') orelse return false;
    var p = k[colon_idx + lb + 1 ..];
    while (true) {
        p = skipWS(p);
        if (p.len == 0 or p[0] == ']') break;
        if (p[0] == '"') {
            p = p[1..];
            var s: usize = 0;
            while (s < p.len and p[s] != '"') : (s += 1) {}
            if (s == needle.len and std.mem.eql(u8, p[0..s], needle)) return true;
            p = p[s..];
            if (p.len > 0 and p[0] == '"') p = p[1..];
        } else {
            while (p.len > 0 and p[0] != ',' and p[0] != ']') : (p = p[1..]) {}
        }
        if (p.len > 0 and p[0] == ',') p = p[1..];
    }
    return false;
}

// --- Public API ---

/// Build the canonical 16-dim ASM-linear float feature vector (exact match to C vectorizer_build).
/// Pads [14] and [15] are always 0.0 (label bit is only used at indexing time).
pub fn build(body: []const u8) ?[VEC_DIM]f32 {
    const transaction = objectRange(body, "transaction") orelse return null;
    const customer = objectRange(body, "customer") orelse return null;
    const merchant = objectRange(body, "merchant") orelse return null;
    const terminal = objectRange(body, "terminal") orelse return null;

    const amount = jsonNumberLimited(transaction, "amount") orelse jsonNumber(transaction, "amount") orelse return null;
    const installments = jsonNumberLimited(transaction, "installments") orelse jsonNumber(transaction, "installments") orelse return null;
    const requested_at = jsonString(transaction, "requested_at") orelse return null;

    const customer_avg_amount = jsonNumberLimited(customer, "avg_amount") orelse jsonNumber(customer, "avg_amount") orelse return null;
    const tx_count_24h = jsonNumberLimited(customer, "tx_count_24h") orelse jsonNumber(customer, "tx_count_24h") orelse return null;

    const merchant_id = jsonString(merchant, "id") orelse return null;
    const mcc_str = jsonString(merchant, "mcc") orelse return null;
    const merchant_avg_amount = jsonNumberLimited(merchant, "avg_amount") orelse jsonNumber(merchant, "avg_amount") orelse return null;

    const is_online = jsonBool(terminal, "is_online") orelse return null;
    const card_present = jsonBool(terminal, "card_present") orelse return null;
    const km_from_home = jsonNumberLimited(terminal, "km_from_home") orelse jsonNumber(terminal, "km_from_home") orelse return null;

    var has_last_tx = false;
    var last_ts: []const u8 = "";
    var km_from_current: f32 = -1.0;

    if (objectRange(body, "last_transaction")) |lt_obj| {
        if (jsonString(lt_obj, "timestamp")) |ts| {
            if (jsonNumberLimited(lt_obj, "km_from_current") orelse jsonNumber(lt_obj, "km_from_current")) |km| {
                has_last_tx = true;
                last_ts = ts;
                km_from_current = km;
            }
        }
    }

    const known_merchant = arrayContainsString(customer, "known_merchants", merchant_id);

    const mcc = std.fmt.parseInt(u32, mcc_str, 10) catch 0;

    const req_epoch = parseIso8601(requested_at);
    const last_epoch: i64 = if (has_last_tx) parseIso8601(last_ts) else 0;

    const days = @divFloor(req_epoch, 86400);
    const dow_i: i32 = @intCast(@mod(days + 3, 7));
    const hour_i: i32 = @intCast(@mod(@divFloor(req_epoch, 3600), 24));

    var out: [VEC_DIM]f32 = [_]f32{0.0} ** VEC_DIM;

    out[0] = clamp01(amount / MAX_AMOUNT);
    out[1] = clamp01(installments / MAX_INSTALLMENTS);

    // Critical fidelity: when customer_avg_amount == 0 the ASM/C path produces 0.0 (not 1.0)
    const ratio: f32 = if (customer_avg_amount > 0.0)
        (amount / customer_avg_amount) / MAX_AVG_RATIO
    else
        0.0;
    out[2] = clamp01(ratio);

    // Linear (no sin/cos, no artificial round4)
    out[3] = clamp01(@as(f32, @floatFromInt(hour_i)) / 23.0);
    out[4] = clamp01(@as(f32, @floatFromInt(@as(u32, @intCast(@mod(dow_i, 7))))) / 6.0);

    if (has_last_tx) {
        var diff_sec = req_epoch - last_epoch;
        if (diff_sec < 0) diff_sec = -diff_sec;
        const min_norm = @as(f32, @floatFromInt(diff_sec)) / (60.0 * 1440.0);
        out[5] = clamp01(min_norm);
        out[6] = clamp01(km_from_current / MAX_KM);
    } else {
        out[5] = -1.0;
        out[6] = -1.0;
    }

    out[7] = clamp01(km_from_home / MAX_KM);
    out[8] = clamp01(tx_count_24h / MAX_TX_COUNT);
    out[9] = if (is_online) 1.0 else 0.0;
    out[10] = if (card_present) 1.0 else 0.0;
    out[11] = if (known_merchant) 0.0 else 1.0;
    out[12] = mccRisk(mcc);
    out[13] = clamp01(merchant_avg_amount / MAX_MERCHANT_AVG);
    out[14] = 0.0;
    out[15] = 0.0;

    return out;
}

/// Exact quantize_feature / quantize_query from the 0/0 C path (knn.c + indexer.c).
pub fn quantize(f: [VEC_DIM]f32) [DIM]i16 {
    var q: [DIM]i16 = undefined;
    for (0..DIM) |d| {
        var v = f[d];
        if (v <= -0.5) {
            q[d] = -SCALE;
        } else {
            if (v < 0.0) v = 0.0;
            if (v > 1.0) v = 1.0;
            q[d] = @intFromFloat(@round(v * @as(f32, SCALE)));
        }
    }
    return q;
}

/// Partition tag computed on the quantized vector (exact query-side rule from rinha_search).
/// Matches computePartitionTag in partitioned_search.zig and the C search path.
pub fn partitionTag(q: [DIM]i16) u8 {
    const bit0: u8 = if (q[5] >= 0) 1 else 0;
    const bit1: u8 = if (q[11] > 0) 2 else 0;
    return bit0 | bit1;
}

/// Convenience: JSON body → quantized i16 vector + partition tag.
/// This is the primary entry point for the partitioned search path.
pub fn buildQuantized(body: []const u8) ?struct { q: [DIM]i16, tag: u8 } {
    const f = build(body) orelse return null;
    const q = quantize(f);
    const tag = partitionTag(q);
    return .{ .q = q, .tag = tag };
}

/// Convenience: JSON body → quantized i16 vector only (tag derived by caller if needed).
pub fn buildI16(body: []const u8) ?[DIM]i16 {
    const f = build(body) orelse return null;
    return quantize(f);
}

// --- Test hooks (used by zig test / small verification mains) ---

pub fn goldenP1() [DIM]i16 {
    return .{ 41, 1667, 500, 7826, 3333, -10000, -10000, 292, 1500, 0, 10000, 0, 1500, 60 };
}

pub fn goldenP2() [DIM]i16 {
    return .{ 385, 2500, 500, 8696, 3333, 2257, 189, 137, 1500, 0, 10000, 0, 2000, 299 };
}

pub fn goldenP3() [DIM]i16 {
    return .{ 4369, 6667, 10000, 870, 1667, 42, 6609, 8816, 9000, 10000, 0, 10000, 8000, 26 };
}

// --- Fidelity tests (B priority: vectorizer must be bit-identical to C/ASM on i16 + tag) ---

const p1 =
    \\{"id":"tx-1329056812","transaction":{"amount":41.12,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.2331036248},"last_transaction":null}
;

const p2 =
    \\{"id":"tx-3576980410","transaction":{"amount":384.88,"installments":3,"requested_at":"2026-03-11T20:23:35Z"},"customer":{"avg_amount":769.76,"tx_count_24h":3,"known_merchants":["MERC-009","MERC-009","MERC-001","MERC-001"]},"merchant":{"id":"MERC-001","mcc":"5912","avg_amount":298.95},"terminal":{"is_online":false,"card_present":true,"km_from_home":13.7090520965},"last_transaction":{"timestamp":"2026-03-11T14:58:35Z","km_from_current":18.8626479774}}
;

const p3 =
    \\{"id":"tx-1788243118","transaction":{"amount":4368.82,"installments":8,"requested_at":"2026-03-17T02:04:06Z"},"customer":{"avg_amount":68.88,"tx_count_24h":18,"known_merchants":["MERC-004","MERC-004","MERC-015","MERC-017","MERC-007"]},"merchant":{"id":"MERC-062","mcc":"7801","avg_amount":25.55},"terminal":{"is_online":true,"card_present":false,"km_from_home":881.6139684714},"last_transaction":{"timestamp":"2026-03-17T01:58:06Z","km_from_current":660.9200962961}}
;

test "vectorizer fidelity vs C golden p1 (null last_tx, sentinel path)" {
    const f = build(p1) orelse unreachable;
    const q = quantize(f);
    const g = goldenP1();
    try std.testing.expectEqual(g, q);
    try std.testing.expectEqual(@as(u8, 0), partitionTag(q));
}

test "vectorizer fidelity vs C golden p2 (with last_tx)" {
    const f = build(p2) orelse unreachable;
    const q = quantize(f);
    const g = goldenP2();
    try std.testing.expectEqual(g, q);
    try std.testing.expectEqual(@as(u8, 1), partitionTag(q));
}

test "vectorizer fidelity vs C golden p3 (unknown merchant, tag 3)" {
    const f = build(p3) orelse unreachable;
    const q = quantize(f);
    const g = goldenP3();
    try std.testing.expectEqual(g, q);
    try std.testing.expectEqual(@as(u8, 3), partitionTag(q));
}
