//
// Created by thiagorigonatti on 29/04/26.
//

#include "mcc_risk.h"

typedef struct { int code; float risk; } mcc_entry_t;
static mcc_entry_t g_mcc[4096];
static int g_mcc_count = 0;

static int mcc_code4(const char *mcc) {
    if (!mcc || strlen(mcc) < 4) return -1;
    if (mcc[0] < '0' || mcc[0] > '9' || mcc[1] < '0' || mcc[1] > '9' || mcc[2] < '0' || mcc[2] > '9' || mcc[3] < '0' || mcc[3] > '9') return -1;
    return (mcc[0]-'0')*1000 + (mcc[1]-'0')*100 + (mcc[2]-'0')*10 + (mcc[3]-'0');
}

static void add_default(int code, float risk) {
    if (g_mcc_count < (int)(sizeof(g_mcc)/sizeof(g_mcc[0]))) {
        g_mcc[g_mcc_count].code = code;
        g_mcc[g_mcc_count].risk = risk;
        g_mcc_count++;
    }
}

static void load_defaults(void) {
    g_mcc_count = 0;
    add_default(5411, 0.15f); add_default(5812, 0.30f); add_default(5912, 0.20f);
    add_default(5944, 0.45f); add_default(7801, 0.80f); add_default(7802, 0.75f);
    add_default(7995, 0.85f); add_default(4511, 0.35f); add_default(5311, 0.25f);
    add_default(5999, 0.50f);
}

int mcc_risk_load(const char *path) {
    load_defaults();
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "mcc_risk: usando tabela default; nao abriu %s\n", path);
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long sz = ftell(f);
    if (sz <= 0 || sz > 1024 * 1024) { fclose(f); return -1; }
    rewind(f);
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return -1; }
    fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[sz] = 0;

    int loaded = 0;
    char *p = buf;
    while ((p = strchr(p, '"')) != NULL) {
        p++;
        if (!(p[0] >= '0' && p[0] <= '9' && p[1] >= '0' && p[1] <= '9' && p[2] >= '0' && p[2] <= '9' && p[3] >= '0' && p[3] <= '9' && p[4] == '"')) continue;
        int code = (p[0]-'0')*1000 + (p[1]-'0')*100 + (p[2]-'0')*10 + (p[3]-'0');
        char *colon = strchr(p + 4, ':');
        if (!colon) break;
        float risk = strtof(colon + 1, NULL);
        bool updated = false;
        for (int i = 0; i < g_mcc_count; i++) if (g_mcc[i].code == code) { g_mcc[i].risk = risk; updated = true; break; }
        if (!updated && g_mcc_count < (int)(sizeof(g_mcc)/sizeof(g_mcc[0]))) { g_mcc[g_mcc_count].code = code; g_mcc[g_mcc_count].risk = risk; g_mcc_count++; }
        loaded++;
        p = colon + 1;
    }
    free(buf);
    fprintf(stderr, "mcc_risk: carregados/atualizados=%d total=%d arquivo=%s\n", loaded, g_mcc_count, path);
    return 0;
}

float mcc_risk_get(const char *mcc) {
    int code = mcc_code4(mcc);
    if (code < 0) return 0.50f;
    for (int i = 0; i < g_mcc_count; i++) if (g_mcc[i].code == code) return g_mcc[i].risk;
    return 0.50f;
}
