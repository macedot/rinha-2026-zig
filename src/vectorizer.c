//
// Created by thiagorigonatti on 29/04/26.
//

#include "vectorizer.h"
#include "config.h"
#include "mcc_risk.h"

static inline char *skip_ws(char *p, char *end) {
    while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) p++;
    return p;
}

static inline char *find_char_range(char *start, char *end, char ch) {
    for (char *p = start; p < end && *p; p++) if (*p == ch) return p;
    return NULL;
}

static char *find_key_range(char *start, char *end, const char *key) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    size_t pat_len = strlen(pat);
    char *p = start;
    while (p < end) {
        p = strstr(p, pat);
        if (!p || p >= end) return NULL;
        if (p + pat_len <= end) return p;
        p++;
    }
    return NULL;
}

static char *matching_brace(char *open, char *end) {
    if (!open || open >= end || *open != '{') return NULL;
    int depth = 0;
    bool in_str = false, esc = false;
    for (char *p = open; p < end && *p; p++) {
        char c = *p;
        if (in_str) {
            if (esc) esc = false;
            else if (c == '\\') esc = true;
            else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true;
        else if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth == 0) return p + 1; }
    }
    return NULL;
}

static bool object_range(char *start, char *end, const char *key, char **obj_start, char **obj_end) {
    char *k = find_key_range(start, end, key);
    if (!k) return false;
    char *colon = find_char_range(k, end, ':');
    if (!colon) return false;
    char *p = skip_ws(colon + 1, end);
    if (p >= end || *p != '{') return false;
    char *close = matching_brace(p, end);
    if (!close) return false;
    *obj_start = p; *obj_end = close;
    return true;
}

static bool json_number(char *start, char *end, const char *key, float *out) {
    char *k = find_key_range(start, end, key);
    if (!k) return false;
    char *colon = find_char_range(k, end, ':');
    if (!colon) return false;
    char *p = skip_ws(colon + 1, end);
    if (p >= end) return false;
    char *endptr = p;
    float v = strtof(p, &endptr);
    if (endptr == p) return false;
    *out = v;
    return true;
}

static bool json_bool(char *start, char *end, const char *key, int *out) {
    char *k = find_key_range(start, end, key);
    if (!k) return false;
    char *colon = find_char_range(k, end, ':');
    if (!colon) return false;
    char *p = skip_ws(colon + 1, end);
    if (p + 4 <= end && strncmp(p, "true", 4) == 0) { *out = 1; return true; }
    if (p + 5 <= end && strncmp(p, "false", 5) == 0) { *out = 0; return true; }
    return false;
}

static bool json_string(char *start, char *end, const char *key, char *out, size_t out_sz) {
    if (out_sz == 0) return false;
    char *k = find_key_range(start, end, key);
    if (!k) return false;
    char *colon = find_char_range(k, end, ':');
    if (!colon) return false;
    char *p = skip_ws(colon + 1, end);
    if (p >= end || *p != '"') return false;
    p++;
    size_t n = 0;
    while (p < end && *p && *p != '"') {
        if (n + 1 < out_sz) out[n++] = *p;
        p++;
    }
    out[n] = 0;
    return p < end && *p == '"';
}

static bool array_contains_string(char *start, char *end, const char *key, const char *needle) {
    char *k = find_key_range(start, end, key);
    if (!k) return false;
    char *colon = find_char_range(k, end, ':');
    if (!colon) return false;
    char *lb = find_char_range(colon, end, '[');
    if (!lb) return false;
    char *p = lb + 1;
    size_t needle_len = strlen(needle);
    while (p < end && *p) {
        p = skip_ws(p, end);
        if (p >= end || *p == ']') break;
        if (*p == '"') {
            p++;
            char *s = p;
            while (p < end && *p && *p != '"') p++;
            size_t len = (size_t)(p - s);
            if (len == needle_len && strncmp(s, needle, len) == 0) return true;
            if (p < end && *p == '"') p++;
        } else p++;
    }
    return false;
}

static inline int iso_year(const char *s) { return (s[0]-'0')*1000 + (s[1]-'0')*100 + (s[2]-'0')*10 + (s[3]-'0'); }
static inline int iso_month(const char *s) { return (s[5]-'0')*10 + (s[6]-'0'); }
static inline int iso_day(const char *s) { return (s[8]-'0')*10 + (s[9]-'0'); }
static inline int iso_hour_utc(const char *s) { int h=(s[11]-'0')*10+(s[12]-'0'); if(h<0) return 0; if(h>23) return 23; return h; }
static inline int iso_minute(const char *s) { return (s[14]-'0')*10 + (s[15]-'0'); }
static inline int iso_second(const char *s) { return (s[17]-'0')*10 + (s[18]-'0'); }

static int64_t days_from_civil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (int64_t)era * 146097 + (int64_t)doe - 719468;
}

static inline int weekday_from_iso_monday0_fast(const char *s) {
    int64_t days = days_from_civil(iso_year(s), (unsigned)iso_month(s), (unsigned)iso_day(s));
    int w = (int)((days + 3) % 7);
    if (w < 0) w += 7;
    return w;
}

static inline int64_t iso_to_epoch_seconds_fast(const char *s) {
    int64_t days = days_from_civil(iso_year(s), (unsigned)iso_month(s), (unsigned)iso_day(s));
    return days * 86400 + iso_hour_utc(s) * 3600 + iso_minute(s) * 60 + iso_second(s);
}

static inline long minutes_between_abs_fast(const char *a, const char *b) {
    int64_t diff = iso_to_epoch_seconds_fast(a) - iso_to_epoch_seconds_fast(b);
    if (diff < 0) diff = -diff;
    return (long)(diff / 60);
}

int vectorizer_build(char *body, size_t body_len, float q[DIM]) {
    char *end = body + body_len;
    char *transaction = NULL, *transaction_end = NULL;
    char *customer = NULL, *customer_end = NULL;
    char *merchant = NULL, *merchant_end = NULL;
    char *terminal = NULL, *terminal_end = NULL;

    if (unlikely(!object_range(body, end, "transaction", &transaction, &transaction_end))) return -1;
    if (unlikely(!object_range(body, end, "customer", &customer, &customer_end))) return -1;
    if (unlikely(!object_range(body, end, "merchant", &merchant, &merchant_end))) return -1;
    if (unlikely(!object_range(body, end, "terminal", &terminal, &terminal_end))) return -1;

    float amount = 0.0f, installments = 0.0f, customer_avg_amount = 0.0f, tx_count_24h = 0.0f;
    float merchant_avg_amount = 0.0f, km_from_home = 0.0f;
    int is_online = 0, card_present = 0;
    char requested_at[40] = {0}, merchant_id[64] = {0}, mcc[16] = {0};

    if (unlikely(!json_number(transaction, transaction_end, "amount", &amount))) return -1;
    if (unlikely(!json_number(transaction, transaction_end, "installments", &installments))) return -1;
    if (unlikely(!json_string(transaction, transaction_end, "requested_at", requested_at, sizeof(requested_at)))) return -1;
    if (unlikely(!json_number(customer, customer_end, "avg_amount", &customer_avg_amount))) return -1;
    if (unlikely(!json_number(customer, customer_end, "tx_count_24h", &tx_count_24h))) return -1;
    if (unlikely(!json_string(merchant, merchant_end, "id", merchant_id, sizeof(merchant_id)))) return -1;
    if (unlikely(!json_string(merchant, merchant_end, "mcc", mcc, sizeof(mcc)))) return -1;
    if (unlikely(!json_number(merchant, merchant_end, "avg_amount", &merchant_avg_amount))) return -1;
    if (unlikely(!json_bool(terminal, terminal_end, "is_online", &is_online))) return -1;
    if (unlikely(!json_bool(terminal, terminal_end, "card_present", &card_present))) return -1;
    if (unlikely(!json_number(terminal, terminal_end, "km_from_home", &km_from_home))) return -1;

    float minutes_since_last_tx = -1.0f;
    float km_from_last_tx = -1.0f;
    char *lt_key = find_key_range(body, end, "last_transaction");
    if (lt_key) {
        char *colon = find_char_range(lt_key, end, ':');
        if (colon) {
            char *p = skip_ws(colon + 1, end);
            if (p < end && *p == '{') {
                char *lt_end = matching_brace(p, end);
                if (unlikely(!lt_end)) return -1;
                char last_ts[40] = {0};
                float km_from_current = 0.0f;
                if (unlikely(!json_string(p, lt_end, "timestamp", last_ts, sizeof(last_ts)))) return -1;
                if (unlikely(!json_number(p, lt_end, "km_from_current", &km_from_current))) return -1;
                long mins = minutes_between_abs_fast(requested_at, last_ts);
                minutes_since_last_tx = clamp01((float)mins / 1440.0f);
                km_from_last_tx = clamp01(km_from_current / g_cfg.km_divisor);
            }
        }
    }

    bool known_merchant = array_contains_string(customer, customer_end, "known_merchants", merchant_id);
    float unknown_merchant = known_merchant ? 0.0f : 1.0f;
    float amount_vs_avg = 1.0f;
    if (likely(customer_avg_amount > 0.0f)) amount_vs_avg = clamp01((amount / customer_avg_amount) / 10.0f);

    q[0]  = clamp01(amount / g_cfg.amount_divisor);
    q[1]  = clamp01(installments / g_cfg.installments_divisor);
    q[2]  = amount_vs_avg;
    q[3]  = clamp01((float)iso_hour_utc(requested_at) / 23.0f);
    q[4]  = clamp01((float)weekday_from_iso_monday0_fast(requested_at) / 6.0f);
    q[5]  = minutes_since_last_tx;
    q[6]  = km_from_last_tx;
    q[7]  = clamp01(km_from_home / g_cfg.km_divisor);
    q[8]  = clamp01(tx_count_24h / g_cfg.tx24h_divisor);
    q[9]  = is_online ? 1.0f : 0.0f;
    q[10] = card_present ? 1.0f : 0.0f;
    q[11] = unknown_merchant;
    q[12] = mcc_risk_get(mcc);
    q[13] = clamp01(merchant_avg_amount / g_cfg.merchant_amount_divisor);
    return 0;
}
