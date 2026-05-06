#include "bridge.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <float.h>

#define DIM 14
#define K_NEIGHBORS 5
#define FIX_SCALE 10000.0f
#define IVF_CLUSTERS 1024
#define IVF_MAX_NPROBE 512
#define CACHELINE 64

#if defined(__GNUC__) || defined(__clang__)
#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)
#else
#define likely(x)   (x)
#define unlikely(x) (x)
#endif

static inline void *xaligned_alloc(size_t alignment, size_t size) {
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) return NULL;
    memset(ptr, 0, size);
    return ptr;
}

static inline int16_t quantize_fixed(float x) {
    if (x < -1.0f) x = -1.0f;
    if (x >  1.0f) x =  1.0f;
    float scaled = x * FIX_SCALE;
    scaled += scaled >= 0.0f ? 0.5f : -0.5f;
    if (scaled < -10000.0f) scaled = -10000.0f;
    if (scaled >  10000.0f) scaled =  10000.0f;
    return (int16_t)scaled;
}

static inline float clamp01(float x) {
    if (x < 0.0f) return 0.0f;
    if (x > 1.0f) return 1.0f;
    return x;
}

typedef struct {
    int n;
    int16_t *dim[DIM];
    uint8_t *labels;
    uint32_t *orig_ids;
    float *centroids;
    int16_t *bbox_min;
    int16_t *bbox_max;
    int cluster_start[IVF_CLUSTERS];
    int cluster_end[IVF_CLUSTERS];
} dataset_t;

static dataset_t g_dataset;
static int g_nprobe = 1;
static int g_full_nprobe = 4;
static int g_candidates = 0;

static int read_exact(FILE *f, void *ptr, size_t len) {
    return fread(ptr, 1, len, f) == len ? 0 : -1;
}

int rinha_load_index(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }

    char magic[4];
    uint32_t n = 0, k = 0, d = 0, stride = 0;
    float scale = 0.0f;
    if (read_exact(f, magic, 4) != 0 || memcmp(magic, "IVF6", 4) != 0 ||
        read_exact(f, &n, sizeof(n)) != 0 ||
        read_exact(f, &k, sizeof(k)) != 0 ||
        read_exact(f, &d, sizeof(d)) != 0 ||
        read_exact(f, &stride, sizeof(stride)) != 0 ||
        read_exact(f, &scale, sizeof(scale)) != 0) {
        fprintf(stderr, "index invalido ou magic diferente de IVF6: %s\n", path);
        fclose(f); return -1;
    }

    if (k != IVF_CLUSTERS || d != DIM || stride != DIM) {
        fprintf(stderr, "index incompativel\n");
        fclose(f); return -1;
    }
    if (fabsf(scale - FIX_SCALE) > 0.01f) {
        fprintf(stderr, "index incompativel: scale\n");
        fclose(f); return -1;
    }

    memset(&g_dataset, 0, sizeof(g_dataset));
    g_dataset.n = (int)n;
    g_dataset.centroids = (float *)xaligned_alloc(CACHELINE, (size_t)IVF_CLUSTERS * DIM * sizeof(float));
    g_dataset.bbox_min = (int16_t *)xaligned_alloc(CACHELINE, (size_t)IVF_CLUSTERS * DIM * sizeof(int16_t));
    g_dataset.bbox_max = (int16_t *)xaligned_alloc(CACHELINE, (size_t)IVF_CLUSTERS * DIM * sizeof(int16_t));
    if (!g_dataset.centroids || !g_dataset.bbox_min || !g_dataset.bbox_max) { fclose(f); return -1; }

    if (read_exact(f, g_dataset.centroids, (size_t)IVF_CLUSTERS * DIM * sizeof(float)) != 0 ||
        read_exact(f, g_dataset.bbox_min, (size_t)IVF_CLUSTERS * DIM * sizeof(int16_t)) != 0 ||
        read_exact(f, g_dataset.bbox_max, (size_t)IVF_CLUSTERS * DIM * sizeof(int16_t)) != 0) {
        fclose(f); return -1;
    }

    uint32_t *offsets = (uint32_t *)malloc((size_t)(IVF_CLUSTERS + 1) * sizeof(uint32_t));
    if (!offsets) { fclose(f); return -1; }
    if (read_exact(f, offsets, (size_t)(IVF_CLUSTERS + 1) * sizeof(uint32_t)) != 0) {
        free(offsets); fclose(f); return -1;
    }
    for (int c = 0; c < IVF_CLUSTERS; c++) {
        g_dataset.cluster_start[c] = (int)offsets[c];
        g_dataset.cluster_end[c] = (int)offsets[c + 1];
    }
    free(offsets);

    for (int j = 0; j < DIM; j++) {
        g_dataset.dim[j] = (int16_t *)xaligned_alloc(CACHELINE, (size_t)n * sizeof(int16_t));
        if (!g_dataset.dim[j]) { fclose(f); return -1; }
    }

    const size_t CHUNK = 16384;
    int16_t *tmp = (int16_t *)malloc(CHUNK * DIM * sizeof(int16_t));
    if (!tmp) { fclose(f); return -1; }
    uint32_t done = 0;
    while (done < n) {
        uint32_t take = n - done;
        if (take > CHUNK) take = CHUNK;
        if (read_exact(f, tmp, (size_t)take * DIM * sizeof(int16_t)) != 0) {
            free(tmp); fclose(f); return -1;
        }
        for (uint32_t i = 0; i < take; i++) {
            for (int j = 0; j < DIM; j++) {
                g_dataset.dim[j][done + i] = tmp[(size_t)i * DIM + j];
            }
        }
        done += take;
    }
    free(tmp);

    g_dataset.labels = (uint8_t *)xaligned_alloc(CACHELINE, (size_t)n * sizeof(uint8_t));
    if (!g_dataset.labels) { fclose(f); return -1; }
    if (read_exact(f, g_dataset.labels, (size_t)n) != 0) { fclose(f); return -1; }

    g_dataset.orig_ids = (uint32_t *)xaligned_alloc(CACHELINE, (size_t)n * sizeof(uint32_t));
    if (!g_dataset.orig_ids) { fclose(f); return -1; }
    if (read_exact(f, g_dataset.orig_ids, (size_t)n * sizeof(uint32_t)) != 0) { fclose(f); return -1; }

    fclose(f);

    double mb = ((double)n * DIM * sizeof(int16_t) + (double)n + (double)n * sizeof(uint32_t) +
                 (double)IVF_CLUSTERS * DIM * (sizeof(float) + 2.0 * sizeof(int16_t))) / (1024.0 * 1024.0);
    fprintf(stderr, "index IVF6 carregado (C bridge): N=%u K=%u scale=%.1f memoria=%.2f MB\n", n, k, scale, mb);
#ifdef __AVX2__
    fprintf(stderr, "C bridge: AVX2 enabled\n");
#else
    fprintf(stderr, "C bridge: scalar fallback\n");
#endif
    return 0;
}

void rinha_set_search_params(int nprobe, int full_nprobe, int candidates) {
    g_nprobe = nprobe;
    g_full_nprobe = full_nprobe;
    g_candidates = candidates;
}

static inline uint64_t sqdiff_i16(int16_t a, int16_t b) {
    int32_t d = (int32_t)a - (int32_t)b;
    return (uint64_t)((int64_t)d * (int64_t)d);
}

static inline int is_worse_pair(uint64_t da, uint32_t ia, uint64_t db, uint32_t ib) {
    return da > db || (da == db && ia > ib);
}

static inline int is_better_pair(uint64_t da, uint32_t ia, uint64_t db, uint32_t ib) {
    return da < db || (da == db && ia < ib);
}

static inline int worst_index5(const uint64_t d[5], const uint32_t id[5]) {
    int w = 0;
    if (is_worse_pair(d[1], id[1], d[w], id[w])) w = 1;
    if (is_worse_pair(d[2], id[2], d[w], id[w])) w = 2;
    if (is_worse_pair(d[3], id[3], d[w], id[w])) w = 3;
    if (is_worse_pair(d[4], id[4], d[w], id[w])) w = 4;
    return w;
}

static inline void try_insert_top5(uint64_t d, uint8_t label, uint32_t orig_id,
                                   uint64_t best_d[5], uint8_t best_l[5], uint32_t best_id[5],
                                   int *worst, uint64_t *worst_d, uint32_t *worst_id) {
    if (is_better_pair(d, orig_id, *worst_d, *worst_id)) {
        best_d[*worst] = d;
        best_l[*worst] = label;
        best_id[*worst] = orig_id;
        *worst = worst_index5(best_d, best_id);
        *worst_d = best_d[*worst];
        *worst_id = best_id[*worst];
    }
}

static inline float centroid_sqdist(const float q[DIM], int c) {
    const float *cent = g_dataset.centroids + (size_t)c * DIM;
    float s = 0.0f;
    for (int j = 0; j < DIM; j++) {
        float d = q[j] - cent[j];
        s += d * d;
    }
    return s;
}

static inline uint64_t bbox_lower_bound(const int16_t q[DIM], int c) {
    const int16_t *mn = g_dataset.bbox_min + (size_t)c * DIM;
    const int16_t *mx = g_dataset.bbox_max + (size_t)c * DIM;
    uint64_t s = 0;
    for (int j = 0; j < DIM; j++) {
        int32_t d = 0;
        if (q[j] < mn[j]) d = (int32_t)mn[j] - (int32_t)q[j];
        else if (q[j] > mx[j]) d = (int32_t)q[j] - (int32_t)mx[j];
        s += (uint64_t)((int64_t)d * (int64_t)d);
    }
    return s;
}

static inline void insert_probe_cluster(int cluster, float penalty, int *best_c, float *best_p, int nprobe) {
    if (penalty >= best_p[nprobe - 1]) return;
    int pos = nprobe - 1;
    while (pos > 0 && penalty < best_p[pos - 1]) pos--;
    for (int i = nprobe - 1; i > pos; i--) {
        best_p[i] = best_p[i - 1];
        best_c[i] = best_c[i - 1];
    }
    best_p[pos] = penalty;
    best_c[pos] = cluster;
}

static void scan_range_scalar(int start, int end, const int16_t q[DIM],
                              uint64_t best_d[5], uint8_t best_l[5], uint32_t best_id[5],
                              int *worst, uint64_t *worst_d, uint32_t *worst_id) {
    const int16_t q0=q[0], q1=q[1], q2=q[2], q3=q[3], q4=q[4], q5=q[5], q6=q[6], q7=q[7];
    const int16_t q8=q[8], q9=q[9], q10=q[10], q11=q[11], q12=q[12], q13=q[13];
    const int16_t *d0=g_dataset.dim[0], *d1=g_dataset.dim[1], *d2=g_dataset.dim[2], *d3=g_dataset.dim[3];
    const int16_t *d4=g_dataset.dim[4], *d5=g_dataset.dim[5], *d6=g_dataset.dim[6], *d7=g_dataset.dim[7];
    const int16_t *d8=g_dataset.dim[8], *d9=g_dataset.dim[9], *d10=g_dataset.dim[10], *d11=g_dataset.dim[11];
    const int16_t *d12=g_dataset.dim[12], *d13=g_dataset.dim[13];
    const uint8_t *labels = g_dataset.labels;
    const uint32_t *ids = g_dataset.orig_ids;

    for (int i = start; i < end; i++) {
        uint64_t dist = 0;
        dist += sqdiff_i16(q5, d5[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q6, d6[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q2, d2[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q0, d0[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q7, d7[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q8, d8[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q11, d11[i]); if (dist > *worst_d) continue;
        dist += sqdiff_i16(q12, d12[i]); if (dist > *worst_d) continue;
        dist += sqdiff_i16(q9, d9[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q10, d10[i]); if (dist > *worst_d) continue;
        dist += sqdiff_i16(q1, d1[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q13, d13[i]); if (dist > *worst_d) continue;
        dist += sqdiff_i16(q3, d3[i]);   if (dist > *worst_d) continue;
        dist += sqdiff_i16(q4, d4[i]);
        uint32_t oid = ids[i];
        if (is_better_pair(dist, oid, *worst_d, *worst_id)) {
            try_insert_top5(dist, labels[i], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
        }
    }
}

#ifdef __AVX2__
#include <immintrin.h>

static inline void acc_dim_i64(__m256i *lo64, __m256i *hi64, __m256i q32, const int16_t *ptr, int i) {
    __m128i raw = _mm_loadu_si128((const __m128i *)(ptr + i));
    __m256i v32 = _mm256_cvtepi16_epi32(raw);
    __m256i diff = _mm256_sub_epi32(v32, q32);
    __m256i sq32 = _mm256_mullo_epi32(diff, diff);
    __m128i sqlo128 = _mm256_castsi256_si128(sq32);
    __m128i sqhi128 = _mm256_extracti128_si256(sq32, 1);
    __m256i sqlo64 = _mm256_cvtepi32_epi64(sqlo128);
    __m256i sqhi64 = _mm256_cvtepi32_epi64(sqhi128);
    *lo64 = _mm256_add_epi64(*lo64, sqlo64);
    *hi64 = _mm256_add_epi64(*hi64, sqhi64);
}

static void scan_range_avx2(int start, int end, const int16_t q[DIM],
                            uint64_t best_d[5], uint8_t best_l[5], uint32_t best_id[5],
                            int *worst, uint64_t *worst_d, uint32_t *worst_id) {
    const int16_t *d0=g_dataset.dim[0], *d1=g_dataset.dim[1], *d2=g_dataset.dim[2], *d3=g_dataset.dim[3];
    const int16_t *d4=g_dataset.dim[4], *d5=g_dataset.dim[5], *d6=g_dataset.dim[6], *d7=g_dataset.dim[7];
    const int16_t *d8=g_dataset.dim[8], *d9=g_dataset.dim[9], *d10=g_dataset.dim[10], *d11=g_dataset.dim[11];
    const int16_t *d12=g_dataset.dim[12], *d13=g_dataset.dim[13];
    const uint8_t *labels = g_dataset.labels;
    const uint32_t *ids = g_dataset.orig_ids;

    const __m256i q0=_mm256_set1_epi32((int)q[0]), q1=_mm256_set1_epi32((int)q[1]);
    const __m256i q2=_mm256_set1_epi32((int)q[2]), q3=_mm256_set1_epi32((int)q[3]);
    const __m256i q4=_mm256_set1_epi32((int)q[4]), q5=_mm256_set1_epi32((int)q[5]);
    const __m256i q6=_mm256_set1_epi32((int)q[6]), q7=_mm256_set1_epi32((int)q[7]);
    const __m256i q8=_mm256_set1_epi32((int)q[8]), q9=_mm256_set1_epi32((int)q[9]);
    const __m256i q10=_mm256_set1_epi32((int)q[10]), q11=_mm256_set1_epi32((int)q[11]);
    const __m256i q12=_mm256_set1_epi32((int)q[12]), q13=_mm256_set1_epi32((int)q[13]);
    const __m256i all_ones = _mm256_set1_epi64x(-1);

    uint64_t tmp_lo[4] __attribute__((aligned(32)));
    uint64_t tmp_hi[4] __attribute__((aligned(32)));
    int i = start;
    int limit = end - ((end - start) & 15);
    for (; i < limit; i += 16) {
        __m256i lo0 = _mm256_setzero_si256();
        __m256i hi0 = _mm256_setzero_si256();
        __m256i lo1 = _mm256_setzero_si256();
        __m256i hi1 = _mm256_setzero_si256();

        /* Phase 1: first 3 most-discriminative dimensions — interleaved 2x */
        acc_dim_i64(&lo0, &hi0, q5, d5, i);
        acc_dim_i64(&lo1, &hi1, q5, d5, i + 8);
        acc_dim_i64(&lo0, &hi0, q6, d6, i);
        acc_dim_i64(&lo1, &hi1, q6, d6, i + 8);
        acc_dim_i64(&lo0, &hi0, q2, d2, i);
        acc_dim_i64(&lo1, &hi1, q2, d2, i + 8);

        /* Early termination — interleaved 2x */
        if (likely(*worst_d < 0x7FFFFFFFFFFFFFFFULL)) {
            __m256i worst_vec = _mm256_set1_epi64x((int64_t)(*worst_d));
            __m256i cmp_lo0 = _mm256_cmpgt_epi64(lo0, worst_vec);
            __m256i cmp_hi0 = _mm256_cmpgt_epi64(hi0, worst_vec);
            __m256i cmp_lo1 = _mm256_cmpgt_epi64(lo1, worst_vec);
            __m256i cmp_hi1 = _mm256_cmpgt_epi64(hi1, worst_vec);
            int skip0 = _mm256_testc_si256(cmp_lo0, all_ones) && _mm256_testc_si256(cmp_hi0, all_ones);
            int skip1 = _mm256_testc_si256(cmp_lo1, all_ones) && _mm256_testc_si256(cmp_hi1, all_ones);
            if (skip0 && skip1) continue;
            if (!skip0) {
                acc_dim_i64(&lo0, &hi0, q0, d0, i);
                acc_dim_i64(&lo0, &hi0, q7, d7, i);
                acc_dim_i64(&lo0, &hi0, q8, d8, i);
                acc_dim_i64(&lo0, &hi0, q11, d11, i);
                acc_dim_i64(&lo0, &hi0, q12, d12, i);
                acc_dim_i64(&lo0, &hi0, q9, d9, i);
                acc_dim_i64(&lo0, &hi0, q10, d10, i);
                acc_dim_i64(&lo0, &hi0, q1, d1, i);
                acc_dim_i64(&lo0, &hi0, q13, d13, i);
                acc_dim_i64(&lo0, &hi0, q3, d3, i);
                acc_dim_i64(&lo0, &hi0, q4, d4, i);
                _mm256_store_si256((__m256i *)tmp_lo, lo0);
                _mm256_store_si256((__m256i *)tmp_hi, hi0);
                for (int lane = 0; lane < 4; lane++) {
                    uint32_t oid = ids[i + lane];
                    uint64_t dd = tmp_lo[lane];
                    if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                        try_insert_top5(dd, labels[i + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
                    }
                }
                for (int lane = 0; lane < 4; lane++) {
                    uint32_t oid = ids[i + 4 + lane];
                    uint64_t dd = tmp_hi[lane];
                    if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                        try_insert_top5(dd, labels[i + 4 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
                    }
                }
            }
            if (!skip1) {
                acc_dim_i64(&lo1, &hi1, q0, d0, i + 8);
                acc_dim_i64(&lo1, &hi1, q7, d7, i + 8);
                acc_dim_i64(&lo1, &hi1, q8, d8, i + 8);
                acc_dim_i64(&lo1, &hi1, q11, d11, i + 8);
                acc_dim_i64(&lo1, &hi1, q12, d12, i + 8);
                acc_dim_i64(&lo1, &hi1, q9, d9, i + 8);
                acc_dim_i64(&lo1, &hi1, q10, d10, i + 8);
                acc_dim_i64(&lo1, &hi1, q1, d1, i + 8);
                acc_dim_i64(&lo1, &hi1, q13, d13, i + 8);
                acc_dim_i64(&lo1, &hi1, q3, d3, i + 8);
                acc_dim_i64(&lo1, &hi1, q4, d4, i + 8);
                _mm256_store_si256((__m256i *)tmp_lo, lo1);
                _mm256_store_si256((__m256i *)tmp_hi, hi1);
                for (int lane = 0; lane < 4; lane++) {
                    uint32_t oid = ids[i + 8 + lane];
                    uint64_t dd = tmp_lo[lane];
                    if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                        try_insert_top5(dd, labels[i + 8 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
                    }
                }
                for (int lane = 0; lane < 4; lane++) {
                    uint32_t oid = ids[i + 12 + lane];
                    uint64_t dd = tmp_hi[lane];
                    if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                        try_insert_top5(dd, labels[i + 12 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
                    }
                }
            }
            continue;
        }

        /* Phase 2: remaining 11 dimensions — both batches */
        acc_dim_i64(&lo0, &hi0, q0, d0, i);
        acc_dim_i64(&lo1, &hi1, q0, d0, i + 8);
        acc_dim_i64(&lo0, &hi0, q7, d7, i);
        acc_dim_i64(&lo1, &hi1, q7, d7, i + 8);
        acc_dim_i64(&lo0, &hi0, q8, d8, i);
        acc_dim_i64(&lo1, &hi1, q8, d8, i + 8);
        acc_dim_i64(&lo0, &hi0, q11, d11, i);
        acc_dim_i64(&lo1, &hi1, q11, d11, i + 8);
        acc_dim_i64(&lo0, &hi0, q12, d12, i);
        acc_dim_i64(&lo1, &hi1, q12, d12, i + 8);
        acc_dim_i64(&lo0, &hi0, q9, d9, i);
        acc_dim_i64(&lo1, &hi1, q9, d9, i + 8);
        acc_dim_i64(&lo0, &hi0, q10, d10, i);
        acc_dim_i64(&lo1, &hi1, q10, d10, i + 8);
        acc_dim_i64(&lo0, &hi0, q1, d1, i);
        acc_dim_i64(&lo1, &hi1, q1, d1, i + 8);
        acc_dim_i64(&lo0, &hi0, q13, d13, i);
        acc_dim_i64(&lo1, &hi1, q13, d13, i + 8);
        acc_dim_i64(&lo0, &hi0, q3, d3, i);
        acc_dim_i64(&lo1, &hi1, q3, d3, i + 8);
        acc_dim_i64(&lo0, &hi0, q4, d4, i);
        acc_dim_i64(&lo1, &hi1, q4, d4, i + 8);

        _mm256_store_si256((__m256i *)tmp_lo, lo0);
        _mm256_store_si256((__m256i *)tmp_hi, hi0);
        for (int lane = 0; lane < 4; lane++) {
            uint32_t oid = ids[i + lane];
            uint64_t dd = tmp_lo[lane];
            if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                try_insert_top5(dd, labels[i + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
            }
        }
        for (int lane = 0; lane < 4; lane++) {
            uint32_t oid = ids[i + 4 + lane];
            uint64_t dd = tmp_hi[lane];
            if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                try_insert_top5(dd, labels[i + 4 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
            }
        }
        _mm256_store_si256((__m256i *)tmp_lo, lo1);
        _mm256_store_si256((__m256i *)tmp_hi, hi1);
        for (int lane = 0; lane < 4; lane++) {
            uint32_t oid = ids[i + 8 + lane];
            uint64_t dd = tmp_lo[lane];
            if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                try_insert_top5(dd, labels[i + 8 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
            }
        }
        for (int lane = 0; lane < 4; lane++) {
            uint32_t oid = ids[i + 12 + lane];
            uint64_t dd = tmp_hi[lane];
            if (is_better_pair(dd, oid, *worst_d, *worst_id)) {
                try_insert_top5(dd, labels[i + 12 + lane], oid, best_d, best_l, best_id, worst, worst_d, worst_id);
            }
        }
    }
    if (i < end) scan_range_scalar(i, end, q, best_d, best_l, best_id, worst, worst_d, worst_id);
}
#endif

static inline void scan_range_fast(int start, int end, const int16_t q[DIM],
                                   uint64_t best_d[5], uint8_t best_l[5], uint32_t best_id[5],
                                   int *worst, uint64_t *worst_d, uint32_t *worst_id) {
#ifdef __AVX2__
    scan_range_avx2(start, end, q, best_d, best_l, best_id, worst, worst_d, worst_id);
#else
    scan_range_scalar(start, end, q, best_d, best_l, best_id, worst, worst_d, worst_id);
#endif
}

static inline int count_frauds5(const uint8_t best_l[5]) {
    return (best_l[0] == 1) + (best_l[1] == 1) + (best_l[2] == 1) + (best_l[3] == 1) + (best_l[4] == 1);
}

static int search_with_nprobe(int nprobe_to_use, const int best_c[], const float best_p[],
                              const int16_t q[DIM]) {
    int nprobe = nprobe_to_use;
    if (nprobe > IVF_CLUSTERS) nprobe = IVF_CLUSTERS;
    if (nprobe < 1) nprobe = 1;

    uint64_t best_d[5] = { UINT64_MAX, UINT64_MAX, UINT64_MAX, UINT64_MAX, UINT64_MAX };
    uint8_t best_l[5] = {0, 0, 0, 0, 0};
    uint32_t best_id[5] = { UINT32_MAX, UINT32_MAX, UINT32_MAX, UINT32_MAX, UINT32_MAX };
    int worst = 0;
    uint64_t worst_d = UINT64_MAX;
    uint32_t worst_id = UINT32_MAX;
    int scanned = 0;
    uint8_t scanned_cluster[IVF_CLUSTERS];
    memset(scanned_cluster, 0, sizeof(scanned_cluster));

    for (int pi = 0; pi < nprobe; pi++) {
        int c = best_c[pi];
        if (c < 0) continue;
        int start = g_dataset.cluster_start[c];
        int end = g_dataset.cluster_end[c];
        int sz = end - start;
        if (sz <= 0) continue;
        scanned_cluster[c] = 1;
        if (g_candidates > 0 && scanned + sz > g_candidates) {
            int remaining = g_candidates - scanned;
            if (remaining <= 0) break;
            end = start + remaining;
            sz = remaining;
        }
        scan_range_fast(start, end, q, best_d, best_l, best_id, &worst, &worst_d, &worst_id);
        scanned += sz;
        if (g_candidates > 0 && scanned >= g_candidates) break;
    }

    if (g_candidates <= 0) {
        for (int c = 0; c < IVF_CLUSTERS; c++) {
            if (scanned_cluster[c]) continue;
            int start = g_dataset.cluster_start[c];
            int end = g_dataset.cluster_end[c];
            if (end <= start) continue;
            if (bbox_lower_bound(q, c) <= worst_d) {
                scan_range_fast(start, end, q, best_d, best_l, best_id, &worst, &worst_d, &worst_id);
            }
        }
    }

    return count_frauds5(best_l);
}

int rinha_search(const float q_float[DIM]) {
    int16_t q[DIM];
    float q_grid[DIM];
    for (int j = 0; j < DIM; j++) {
        q[j] = quantize_fixed(q_float[j]);
        q_grid[j] = (float)q[j] / FIX_SCALE;
    }

    int fast_nprobe = g_nprobe;
    if (fast_nprobe < 1) fast_nprobe = 1;
    if (fast_nprobe > IVF_MAX_NPROBE) fast_nprobe = IVF_MAX_NPROBE;
    if (fast_nprobe > IVF_CLUSTERS) fast_nprobe = IVF_CLUSTERS;

    int full_nprobe = g_full_nprobe;
    if (full_nprobe < fast_nprobe) full_nprobe = fast_nprobe;
    if (full_nprobe > IVF_MAX_NPROBE) full_nprobe = IVF_MAX_NPROBE;
    if (full_nprobe > IVF_CLUSTERS) full_nprobe = IVF_CLUSTERS;

    /* Compute ALL centroid distances once — keep top full_nprobe */
    int best_c[IVF_MAX_NPROBE];
    float best_p[IVF_MAX_NPROBE];
    for (int i = 0; i < full_nprobe; i++) { best_c[i] = -1; best_p[i] = FLT_MAX; }
    for (int c = 0; c < IVF_CLUSTERS; c++)
        insert_probe_cluster(c, centroid_sqdist(q_grid, c), best_c, best_p, full_nprobe);

    /* Reorder: scan smallest clusters first */
    for (int i = 0; i < full_nprobe - 1; i++) {
        for (int j = i + 1; j < full_nprobe; j++) {
            int si = g_dataset.cluster_end[best_c[i]] - g_dataset.cluster_start[best_c[i]];
            int sj = g_dataset.cluster_end[best_c[j]] - g_dataset.cluster_start[best_c[j]];
            if (sj < si) {
                int tc = best_c[i]; best_c[i] = best_c[j]; best_c[j] = tc;
                float tp = best_p[i]; best_p[i] = best_p[j]; best_p[j] = tp;
            }
        }
    }

    /* Fast pass */
    int result = search_with_nprobe(fast_nprobe, best_c, best_p, q);

    /* Two-stage: if ambiguous (2 or 3 frauds), re-run with full probes */
    if (result == 2 || result == 3) {
        result = search_with_nprobe(full_nprobe, best_c, best_p, q);
    }

    return result;
}
