//
// Created by thiagorigonatti on 29/04/26.
//

#define _GNU_SOURCE
#include <zlib.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>
#include <float.h>

#define DIM 14
#define IVF_K 256
#define FIX_SCALE 10000.0f

typedef struct { FILE *plain; gzFile gz; int is_gz; } stream_file_t;

static float *vectors = NULL;
static uint8_t *labels = NULL;
static uint32_t N = 0, cap_n = 0;

static inline int has_suffix(const char *s, const char *suffix) {
    size_t ls = strlen(s), lf = strlen(suffix);
    return ls >= lf && strcmp(s + ls - lf, suffix) == 0;
}

static int stream_open(stream_file_t *sf, const char *path) {
    memset(sf, 0, sizeof(*sf));
    if (has_suffix(path, ".gz")) {
        sf->gz = gzopen(path, "rb");
        if (!sf->gz) return -1;
        sf->is_gz = 1;
        return 0;
    }
    sf->plain = fopen(path, "rb");
    return sf->plain ? 0 : -1;
}

static size_t stream_read(stream_file_t *sf, char *buf, size_t cap) {
    if (sf->is_gz) {
        int n = gzread(sf->gz, buf, (unsigned int)cap);
        return n > 0 ? (size_t)n : 0;
    }
    return fread(buf, 1, cap, sf->plain);
}

static void stream_close(stream_file_t *sf) {
    if (sf->is_gz && sf->gz) gzclose(sf->gz);
    if (!sf->is_gz && sf->plain) fclose(sf->plain);
}

static void *xrealloc(void *p, size_t sz) {
    void *q = realloc(p, sz);
    if (!q) { fprintf(stderr, "sem memoria realloc %zu\n", sz); exit(1); }
    return q;
}

static void ensure_vectors(void) {
    if (N < cap_n) return;
    cap_n = cap_n ? cap_n * 2u : 1024u;
    vectors = (float *)xrealloc(vectors, (size_t)cap_n * DIM * sizeof(float));
    labels = (uint8_t *)xrealloc(labels, (size_t)cap_n);
}

static void add_vector(const float vals[DIM], uint8_t label) {
    ensure_vectors();
    memcpy(vectors + (size_t)N * DIM, vals, DIM * sizeof(float));
    labels[N] = label;
    N++;
}

static int parse_references_stream(const char *path) {
    stream_file_t sf;
    if (stream_open(&sf, path) != 0) { fprintf(stderr, "nao consegui abrir %s\n", path); return -1; }
    size_t cap = 2 * 1024 * 1024;
    const size_t chunk = 256 * 1024;
    char *buf = (char *)malloc(cap + 1);
    if (!buf) { stream_close(&sf); return -1; }
    size_t len = 0;
    int rc = 0;
    while (1) {
        if (len + chunk + 1 > cap) { cap *= 2; buf = (char *)xrealloc(buf, cap + 1); }
        size_t got = stream_read(&sf, buf + len, chunk);
        len += got; buf[len] = '\0';
        char *base = buf, *end = buf + len, *p = base, *keep_from = end;
        while (p < end) {
            char *vkey = strstr(p, "\"vector\"");
            if (!vkey || vkey >= end) { size_t tail = len < 64 ? len : 64; keep_from = end - tail; break; }
            char *lb = memchr(vkey, '[', (size_t)(end - vkey));
            if (!lb) { keep_from = vkey; break; }
            char *rb = memchr(lb, ']', (size_t)(end - lb));
            if (!rb) { keep_from = vkey; break; }
            float vals[DIM];
            char *cur = lb + 1;
            for (int j = 0; j < DIM; j++) {
                while (cur < rb && (*cur == ' ' || *cur == '\n' || *cur == '\r' || *cur == '\t' || *cur == ',')) cur++;
                char *endptr = cur;
                vals[j] = strtof(cur, &endptr);
                if (endptr == cur || endptr > rb) { fprintf(stderr, "erro lendo dimensao %d perto do vetor %u\n", j, N); rc = -1; goto done; }
                cur = endptr;
            }
            char *label_key = strstr(rb, "\"label\"");
            if (!label_key || label_key >= end) { keep_from = vkey; break; }
            char *colon = memchr(label_key, ':', (size_t)(end - label_key));
            if (!colon) { keep_from = vkey; break; }
            char *q = memchr(colon, '"', (size_t)(end - colon));
            if (!q) { keep_from = vkey; break; }
            q++;
            char *qend = memchr(q, '"', (size_t)(end - q));
            if (!qend) { keep_from = vkey; break; }
            uint8_t label = (qend - q >= 5 && strncmp(q, "fraud", 5) == 0) ? 1 : 0;
            add_vector(vals, label);
            if ((N % 500000u) == 0) fprintf(stderr, "parseados %u vetores\n", N);
            p = qend + 1; keep_from = p;
        }
        if (got == 0) break;
        if (keep_from < end) {
            size_t keep = (size_t)(end - keep_from);
            if (keep > cap / 2) { fprintf(stderr, "objeto JSON muito grande/incompleto: keep=%zu\n", keep); rc = -1; break; }
            memmove(buf, keep_from, keep); len = keep;
        } else len = 0;
    }
done:
    free(buf); stream_close(&sf); return rc;
}

static inline int16_t quantize_i16(float x) {
    if (x < -1.0f) x = -1.0f;
    if (x > 1.0f) x = 1.0f;

    float scaled = x * FIX_SCALE;
    scaled += scaled >= 0.0f ? 0.5f : -0.5f;

    if (scaled < -10000.0f) scaled = -10000.0f;
    if (scaled > 10000.0f) scaled = 10000.0f;

    return (int16_t)scaled;
}

static inline float dist2_vec_centroid(uint32_t idx, const float *centroid) {
    const float *v = vectors + (size_t)idx * DIM;
    float d = 0.0f;
    for (int j = 0; j < DIM; j++) { float diff = v[j] - centroid[j]; d += diff * diff; }
    return d;
}

static int nearest_centroid(uint32_t idx, const float *centroids, uint32_t k) {
    int best = 0;
    float best_d = FLT_MAX;
    const float *v = vectors + (size_t)idx * DIM;
    for (uint32_t c = 0; c < k; c++) {
        const float *cc = centroids + (size_t)c * DIM;
        float d = 0.0f;
        for (int j = 0; j < DIM; j++) { float diff = v[j] - cc[j]; d += diff * diff; }
        if (d < best_d) { best_d = d; best = (int)c; }
    }
    return best;
}

static uint32_t env_u32(const char *name, uint32_t def, uint32_t minv, uint32_t maxv) {
    const char *e = getenv(name);
    if (!e || !*e) return def;
    long v = strtol(e, NULL, 10);
    if (v < (long)minv) v = minv;
    if (v > (long)maxv) v = maxv;
    return (uint32_t)v;
}

static void train_kmeans(float *centroids, uint32_t k, uint32_t sample_n, uint32_t iters) {
    if (sample_n > N) sample_n = N;
    uint32_t *sample = (uint32_t *)malloc((size_t)sample_n * sizeof(uint32_t));
    if (!sample) { fprintf(stderr, "sem memoria sample\n"); exit(1); }
    for (uint32_t i = 0; i < sample_n; i++) sample[i] = (uint32_t)(((uint64_t)i * (uint64_t)N) / sample_n);
    for (uint32_t c = 0; c < k; c++) {
        uint32_t si = (uint32_t)(((uint64_t)c * (uint64_t)sample_n) / k);
        if (si >= sample_n) si = sample_n - 1;
        memcpy(centroids + (size_t)c * DIM, vectors + (size_t)sample[si] * DIM, DIM * sizeof(float));
    }
    float *sums = (float *)calloc((size_t)k * DIM, sizeof(float));
    uint32_t *counts = (uint32_t *)calloc(k, sizeof(uint32_t));
    if (!sums || !counts) { fprintf(stderr, "sem memoria kmeans sums\n"); exit(1); }
    for (uint32_t it = 0; it < iters; it++) {
        memset(sums, 0, (size_t)k * DIM * sizeof(float));
        memset(counts, 0, (size_t)k * sizeof(uint32_t));
        for (uint32_t s = 0; s < sample_n; s++) {
            uint32_t idx = sample[s];
            int c = nearest_centroid(idx, centroids, k);
            const float *v = vectors + (size_t)idx * DIM;
            float *sum = sums + (size_t)c * DIM;
            for (int j = 0; j < DIM; j++) sum[j] += v[j];
            counts[c]++;
        }
        uint32_t empty = 0;
        for (uint32_t c = 0; c < k; c++) {
            if (counts[c] == 0) { empty++; continue; }
            float inv = 1.0f / (float)counts[c];
            float *cc = centroids + (size_t)c * DIM;
            float *sum = sums + (size_t)c * DIM;
            for (int j = 0; j < DIM; j++) cc[j] = sum[j] * inv;
        }
        fprintf(stderr, "kmeans iter %u/%u sample=%u empty=%u\n", it + 1, iters, sample_n, empty);
    }
    free(sample); free(sums); free(counts);
}

static int write_exact(FILE *f, const void *ptr, size_t len) { return fwrite(ptr, 1, len, f) == len ? 0 : -1; }

static int write_index(const char *path, float *centroids, int16_t *bbox_min, int16_t *bbox_max,
                       uint32_t *offsets, int16_t *out_vectors, uint8_t *out_labels, uint32_t *out_ids) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    char magic[4] = {'I','V','F','6'};
    uint32_t n = N, k = IVF_K, d = DIM, stride = DIM;
    float scale = FIX_SCALE;
    int rc = 0;
    if (write_exact(f, magic, 4) != 0 ||
        write_exact(f, &n, sizeof(n)) != 0 ||
        write_exact(f, &k, sizeof(k)) != 0 ||
        write_exact(f, &d, sizeof(d)) != 0 ||
        write_exact(f, &stride, sizeof(stride)) != 0 ||
        write_exact(f, &scale, sizeof(scale)) != 0 ||
        write_exact(f, centroids, (size_t)IVF_K * DIM * sizeof(float)) != 0 ||
        write_exact(f, bbox_min, (size_t)IVF_K * DIM * sizeof(int16_t)) != 0 ||
        write_exact(f, bbox_max, (size_t)IVF_K * DIM * sizeof(int16_t)) != 0 ||
        write_exact(f, offsets, (size_t)(IVF_K + 1) * sizeof(uint32_t)) != 0 ||
        write_exact(f, out_vectors, (size_t)N * DIM * sizeof(int16_t)) != 0 ||
        write_exact(f, out_labels, (size_t)N) != 0 ||
        write_exact(f, out_ids, (size_t)N * sizeof(uint32_t)) != 0) rc = -1;
    fclose(f);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "uso: %s <references.json|references.json.gz> <index.bin>\n", argv[0]); return 1; }
    fprintf(stderr, "lendo references: %s\n", argv[1]);
    if (parse_references_stream(argv[1]) != 0 || N == 0) { fprintf(stderr, "falha lendo references\n"); return 1; }
    fprintf(stderr, "vetores carregados: %u, memoria float+labels=%.2f MB\n", N, ((double)N * DIM * sizeof(float) + (double)N) / (1024.0 * 1024.0));

    uint32_t k = IVF_K;
    uint32_t sample_n = env_u32("IVF_TRAIN_SAMPLE", 131072, k, N);
    uint32_t iters = env_u32("IVF_TRAIN_ITERS", 10, 1, 256);
    fprintf(stderr, "treinando kmeans: K=%u sample=%u iters=%u\n", k, sample_n, iters);
    float *centroids = (float *)malloc((size_t)k * DIM * sizeof(float));
    if (!centroids) { fprintf(stderr, "sem memoria centroids\n"); return 1; }
    train_kmeans(centroids, k, sample_n, iters);

    uint32_t *assign = (uint32_t *)malloc((size_t)N * sizeof(uint32_t));
    uint32_t *counts = (uint32_t *)calloc(k, sizeof(uint32_t));
    if (!assign || !counts) { fprintf(stderr, "sem memoria assign/counts\n"); return 1; }
    fprintf(stderr, "atribuindo %u referencias aos %u clusters...\n", N, k);
    for (uint32_t i = 0; i < N; i++) {
        int c = nearest_centroid(i, centroids, k);
        assign[i] = (uint32_t)c;
        counts[c]++;
        if ((i % 500000u) == 0 && i) fprintf(stderr, "atribuido %u/%u\n", i, N);
    }
    uint32_t *offsets = (uint32_t *)malloc((size_t)(k + 1) * sizeof(uint32_t));
    uint32_t *write_pos = (uint32_t *)malloc((size_t)k * sizeof(uint32_t));
    if (!offsets || !write_pos) { fprintf(stderr, "sem memoria offsets\n"); return 1; }
    offsets[0] = 0;
    for (uint32_t c = 0; c < k; c++) offsets[c + 1] = offsets[c] + counts[c];
    memcpy(write_pos, offsets, (size_t)k * sizeof(uint32_t));

    int16_t *out_vectors = (int16_t *)malloc((size_t)N * DIM * sizeof(int16_t));
    uint8_t *out_labels = (uint8_t *)malloc((size_t)N);
    uint32_t *out_ids = (uint32_t *)malloc((size_t)N * sizeof(uint32_t));
    int16_t *bbox_min = (int16_t *)malloc((size_t)k * DIM * sizeof(int16_t));
    int16_t *bbox_max = (int16_t *)malloc((size_t)k * DIM * sizeof(int16_t));
    if (!out_vectors || !out_labels || !out_ids || !bbox_min || !bbox_max) {
        fprintf(stderr, "sem memoria output vectors/labels/ids/bbox\n"); return 1;
    }
    for (uint32_t c = 0; c < k; c++) {
        for (int j = 0; j < DIM; j++) {
            bbox_min[(size_t)c * DIM + j] = INT16_MAX;
            bbox_max[(size_t)c * DIM + j] = INT16_MIN;
        }
    }
    fprintf(stderr, "ordenando, quantizando e calculando bounding boxes...\n");
    for (uint32_t i = 0; i < N; i++) {
        uint32_t c = assign[i];
        uint32_t pos = write_pos[c]++;
        const float *v = vectors + (size_t)i * DIM;
        int16_t *dst = out_vectors + (size_t)pos * DIM;
        for (int j = 0; j < DIM; j++) {
            int16_t qv = quantize_i16(v[j]);
            dst[j] = qv;
            size_t bi = (size_t)c * DIM + j;
            if (qv < bbox_min[bi]) bbox_min[bi] = qv;
            if (qv > bbox_max[bi]) bbox_max[bi] = qv;
        }
        out_labels[pos] = labels[i];
        out_ids[pos] = i;
    }
    for (uint32_t c = 0; c < k; c++) {
        if (counts[c] == 0) {
            for (int j = 0; j < DIM; j++) {
                bbox_min[(size_t)c * DIM + j] = 0;
                bbox_max[(size_t)c * DIM + j] = 0;
            }
        }
    }
    free(write_pos); free(assign); free(counts);

    fprintf(stderr, "gravando %s...\n", argv[2]);
    if (write_index(argv[2], centroids, bbox_min, bbox_max, offsets, out_vectors, out_labels, out_ids) != 0) { fprintf(stderr, "falha gravando index\n"); return 1; }
    fprintf(stderr, "ok: %s (N=%u K=%u)\n", argv[2], N, k);
    return 0;
}
