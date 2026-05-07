const std = @import("std");

const DIM = 14;

fn round4(x: f32) f32 {
    return @round(x * 10000.0) * 0.0001;
}

fn clamp01(v: f32) f32 {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

fn mccRiskF(mcc: u32) f32 {
    return switch (mcc) {
        5411 => 0.15,
        5812 => 0.30,
        5912 => 0.20,
        5944 => 0.45,
        7801 => 0.80,
        7802 => 0.75,
        7995 => 0.85,
        4511 => 0.35,
        5311 => 0.25,
        5999 => 0.50,
        else => 0.50,
    };
}

// --- JSON helpers (custom, zero-allocation) ---

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
    var i: usize = 0;
    while (i < data.len) {
        if (std.mem.indexOfPos(u8, data, i, pat)) |idx| {
            const start = data[idx..];
            if (start.len >= pat.len) return start;
            i = idx + 1;
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

// --- ISO 8601 date helpers ---

fn isoHourUTC(s: []const u8) u32 {
    if (s.len < 14) return 0;
    const h = @as(u32, s[11] - '0') * 10 + @as(u32, s[12] - '0');
    return if (h > 23) 23 else h;
}

fn isoMinute(s: []const u8) u32 {
    if (s.len < 16) return 0;
    return @as(u32, s[14] - '0') * 10 + @as(u32, s[15] - '0');
}

fn isoYear(s: []const u8) i32 {
    if (s.len < 4) return 0;
    return @as(i32, s[0] - '0') * 1000 + @as(i32, s[1] - '0') * 100 + @as(i32, s[2] - '0') * 10 + @as(i32, s[3] - '0');
}

fn isoMonth(s: []const u8) u32 {
    if (s.len < 7) return 1;
    const m = @as(u32, s[5] - '0') * 10 + @as(u32, s[6] - '0');
    return if (m < 1 or m > 12) 1 else m;
}

fn isoDay(s: []const u8) u32 {
    if (s.len < 10) return 1;
    return @as(u32, s[8] - '0') * 10 + @as(u32, s[9] - '0');
}

fn daysFromCivil(y: i32, m: u32, d: u32) i64 {
    var year = y;
    if (m <= 2) year -= 1;
    const era: i32 = if (year >= 0) @divFloor(year, 400) else @divFloor(year - 399, 400);
    const yoe: u32 = @intCast(year - era * 400);
    const doy: u32 = if (m > 2)
        (153 * (m - 3) + 2) / 5 + d - 1
    else
        (153 * (m + 9) + 2) / 5 + d - 1;
    const doe = @as(u32, yoe) * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i64, era) * 146097 + @as(i64, doe) - 719468;
}

fn weekdayFromISO(s: []const u8) usize {
    const days = daysFromCivil(isoYear(s), isoMonth(s), isoDay(s));
    var w: i64 = @mod(days + 3, 7);
    if (w < 0) w += 7;
    return @intCast(w);
}

fn isoToEpochSeconds(s: []const u8) i64 {
    const days = daysFromCivil(isoYear(s), isoMonth(s), isoDay(s));
    return days * 86400 + @as(i64, isoHourUTC(s)) * 3600 + @as(i64, isoMinute(s)) * 60;
}

fn minutesBetweenAbs(a: []const u8, b: []const u8) i64 {
    const diff = isoToEpochSeconds(a) - isoToEpochSeconds(b);
    return if (diff < 0) @divTrunc(-diff, 60) else @divTrunc(diff, 60);
}

// --- Main vectorizer (matching Rust SOTA) ---

pub fn build(body: []const u8) ?[DIM]f32 {
    var v = [1]f32{0.0} ** DIM;

    const transaction = objectRange(body, "transaction") orelse return null;
    const customer = objectRange(body, "customer") orelse return null;
    const merchant = objectRange(body, "merchant") orelse return null;
    const terminal = objectRange(body, "terminal") orelse return null;

    const amount = jsonNumber(transaction, "amount") orelse return null;
    const installments = jsonNumber(transaction, "installments") orelse return null;
    const requested_at = jsonString(transaction, "requested_at") orelse return null;

    const customer_avg_amount = jsonNumber(customer, "avg_amount") orelse return null;
    const tx_count_24h = jsonNumber(customer, "tx_count_24h") orelse return null;

    const merchant_id = jsonString(merchant, "id") orelse return null;
    const mcc_str = jsonString(merchant, "mcc") orelse return null;
    const merchant_avg_amount = jsonNumber(merchant, "avg_amount") orelse return null;

    const is_online = jsonBool(terminal, "is_online") orelse return null;
    const card_present = jsonBool(terminal, "card_present") orelse return null;
    const km_from_home = jsonNumber(terminal, "km_from_home") orelse return null;

    var minutes_since_last_tx: f32 = -1.0;
    var km_from_current: f32 = -1.0;

    if (objectRange(body, "last_transaction")) |lt_obj| {
        if (jsonString(lt_obj, "timestamp")) |last_ts| {
            if (jsonNumber(lt_obj, "km_from_current")) |km| {
                const mins = minutesBetweenAbs(requested_at, last_ts);
                minutes_since_last_tx = clamp01(@as(f32, @floatFromInt(mins)) / 1440.0);
                km_from_current = clamp01(km / 1000.0);
            }
        }
    }

    const known_merchant = arrayContainsString(customer, "known_merchants", merchant_id);
    const is_unknown_merchant = !known_merchant;

    const mcc = std.fmt.parseInt(u32, mcc_str, 10) catch 0;

    const ratio = if (customer_avg_amount > 0.0)
        (amount / customer_avg_amount) / 10.0
    else
        1.0;

    v[0] = clamp01(amount / 10_000.0);
    v[1] = clamp01(installments / 12.0);
    v[2] = clamp01(ratio);
    v[3] = round4(@as(f32, @floatFromInt(isoHourUTC(requested_at))) / 23.0);
    v[4] = round4(@as(f32, @floatFromInt(weekdayFromISO(requested_at))) / 6.0);
    v[5] = minutes_since_last_tx;
    v[6] = km_from_current;
    v[7] = clamp01(km_from_home / 1000.0);
    v[8] = clamp01(tx_count_24h / 20.0);
    v[9] = if (is_online) 1.0 else 0.0;
    v[10] = if (card_present) 1.0 else 0.0;
    v[11] = if (is_unknown_merchant) 1.0 else 0.0;
    v[12] = mccRiskF(mcc);
    v[13] = clamp01(merchant_avg_amount / 10_000.0);

    return v;
}
