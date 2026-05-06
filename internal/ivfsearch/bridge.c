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
#define VECTOR_SCALE (1.0f / FIX_SCALE)
#define IVF_CLUSTERS 1024
#define IVF_MAX_NPROBE 512
#define CACHELINE 64
#define BLOCK_STRIDE 112  /* 8 slots * 14 dims */

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

/* Dataset: IVF7 AoSoA layout
 *
 * centroids_t[dim][cluster]: float, transposed column-major (dim-major)
 *   - centroid_sqdist reads dim0 of all clusters contiguously, then dim1, etc.
 * block_offsets[K+1]: cumulative block counts per cluster
 * labels[total_blocks * 8]: padded to block boundaries
 * blocks[total_blocks * BLOCK_STRIDE]: AoSoA
 *   - each block: dim0[0..7], dim1[0..7], ..., dim13[0..7] = 112 i16
 */
typedef struct {
    int n;
    int total_blocks;
    float *centroids_t;       /* [DIM * IVF_CLUSTERS], transposed */
    uint32_t block_offsets[IVF_CLUSTERS + 1];
    uint8_t *labels;          /* [total_blocks * 8], padded */
    int16_t *blocks;          /* [total_blocks * BLOCK_STRIDE], AoSoA */
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
    if (read_exact(f, magic, 4) != 0 || memcmp(magic, "IVF7", 4) != 0 ||
        read_exact(f, &n, sizeof(n)) != 0 ||
        read_exact(f, &k, sizeof(k)) != 0 ||
        read_exact(f, &d, sizeof(d)) != 0 ||
        read_exact(f, &stride, sizeof(stride)) != 0 ||
        read_exact(f, &scale, sizeof(scale)) != 0) {
        fprintf(stderr, "index invalido ou magic != IVF7: %s\n", path);
        fclose(f); return -1;
    }

    if (k != IVF_CLUSTERS || d != DIM || stride != DIM) {
        fprintf(stderr, "index incompativel: K=%u D=%u stride=%u\n", k, d, stride);
        fclose(f); return -1;
    }
    if (fabsf(scale - FIX_SCALE) > 0.01f) {
        fprintf(stderr, "index incompativel: scale=%f\n", scale);
        fclose(f); return -1;
    }

    memset(&g_dataset, 0, sizeof(g_dataset));
    g_dataset.n = (int)n;

    /* Transposed centroids: DIM * IVF_CLUSTERS floats */
    g_dataset.centroids_t = (float *)xaligned_alloc(CACHELINE,
        (size_t)DIM * IVF_CLUSTERS * sizeof(float));
    if (!g_dataset.centroids_t) { fclose(f); return -1; }
    if (read_exact(f, g_dataset.centroids_t,
        (size_t)DIM * IVF_CLUSTERS * sizeof(float)) != 0) {
        fclose(f); return -1;
    }

    /* Block offsets: K+1 uint32 */
    if (read_exact(f, g_dataset.block_offsets,
        (size_t)(IVF_CLUSTERS + 1) * sizeof(uint32_t)) != 0) {
        fclose(f); return -1;
    }
    g_dataset.total_blocks = (int)g_dataset.block_offsets[IVF_CLUSTERS];
    int padded_n = g_dataset.total_blocks * 8;

    /* Labels: padded_n uint8 */
    g_dataset.labels = (uint8_t *)xaligned_alloc(CACHELINE,
        (size_t)padded_n * sizeof(uint8_t));
    if (!g_dataset.labels) { fclose(f); return -1; }
    if (read_exact(f, g_dataset.labels, (size_t)padded_n) != 0) {
        fclose(f); return -1;
    }

    /* Blocks: total_blocks * BLOCK_STRIDE int16 */
    g_dataset.blocks = (int16_t *)xaligned_alloc(CACHELINE,
        (size_t)g_dataset.total_blocks * BLOCK_STRIDE * sizeof(int16_t));
    if (!g_dataset.blocks) { fclose(f); return -1; }
    if (read_exact(f, g_dataset.blocks,
        (size_t)g_dataset.total_blocks * BLOCK_STRIDE * sizeof(int16_t)) != 0) {
        fclose(f); return -1;
    }

    fclose(f);

    double mb = ((double)g_dataset.total_blocks * BLOCK_STRIDE * sizeof(int16_t) +
                 (double)padded_n +
                 (double)DIM * IVF_CLUSTERS * sizeof(float) +
                 (double)(IVF_CLUSTERS + 1) * sizeof(uint32_t)) / (1024.0 * 1024.0);
    fprintf(stderr, "index IVF7 carregado (C bridge): N=%u K=%u blocks=%d memoria=%.2f MB\n",
        n, k, g_dataset.total_blocks, mb);
#ifdef __AVX2__
    fprintf(stderr, "C bridge: AVX2 enabled (AoSoA blocks)\n");
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

/* --- Top-5 maintenance (same as before, no orig_id needed) --- */

static inline int is_worse_float(float da, float db) {
    return da > db;
}

static inline int is_better_float(float da, float db) {
    return da < db;
}

static inline int worst_index5_f(const float d[5]) {
    int w = 0;
    if (d[1] > d[w]) w = 1;
    if (d[2] > d[w]) w = 2;
    if (d[3] > d[w]) w = 3;
    if (d[4] > d[w]) w = 4;
    return w;
}

static inline void try_insert_top5_f(float d, uint8_t label,
                                     float best_d[5], uint8_t best_l[5],
                                     int *worst, float *worst_d) {
    if (d < *worst_d) {
        best_d[*worst] = d;
        best_l[*worst] = label;
        *worst = worst_index5_f(best_d);
        *worst_d = best_d[*worst];
    }
}

/* --- Centroid distance with transposed layout --- */

static inline float centroid_sqdist(const float q[DIM], int c) {
    /* centroids_t is dim-major: centroids_t[dim * K + cluster] */
    float s = 0.0f;
    for (int j = 0; j < DIM; j++) {
        float d = q[j] - g_dataset.centroids_t[(size_t)j * IVF_CLUSTERS + c];
        s += d * d;
    }
    return s;
}

static inline void insert_probe_cluster(int cluster, float penalty,
                                        int *best_c, float *best_p, int nprobe) {
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

/* --- AoSoA block-based scan kernels --- */

static inline void scan_blocks_scalar(int start_block, int end_block, const int16_t q[DIM],
                                      float best_d[5], uint8_t best_l[5],
                                      int *worst, float *worst_d) {
    const int16_t *blocks = g_dataset.blocks;
    const uint8_t *labels = g_dataset.labels;
    const float vscale = VECTOR_SCALE;

    for (int bi = start_block; bi < end_block; bi++) {
        const int16_t *b = blocks + (size_t)bi * BLOCK_STRIDE;
        const uint8_t *lb = labels + (size_t)bi * 8;

        for (int slot = 0; slot < 8; slot++) {
            /* Skip sentinel (unused slot padded with INT16_MAX) */
            if (b[slot] == INT16_MAX) continue;

            float dist = 0.0f;
            for (int j = 0; j < DIM; j++) {
                float dv = (float)b[(size_t)j * 8 + slot] * vscale;
                float diff = dv - (float)q[j] * vscale;
                dist += diff * diff;
            }
            if (dist < *worst_d) {
                try_insert_top5_f(dist, lb[slot], best_d, best_l, worst, worst_d);
            }
        }
    }
}

#ifdef __AVX2__
#include <immintrin.h>

/* Process one block (8 vectors) through all 14 dimensions using dim pairs.
 * Matches the Rust SOTA scan_blocks approach:
 *   - Load 8×i16 per dimension via _mm_loadu_si128
 *   - Convert i16→i32→f32, dequantize, compute diff, accumulate via FMA
 *   - Process dimensions in pairs (dim_pair! macro)
 *   - Early termination after 4 dim-pairs (8 of 14 dims)
 *   - Software prefetch for blocks ahead
 */
static void scan_blocks_avx2(int start_block, int end_block, const int16_t q[DIM],
                             float best_d[5], uint8_t best_l[5],
                             int *worst, float *worst_d) {
    const int16_t *blocks = g_dataset.blocks;
    const uint8_t *labels = g_dataset.labels;
    const __m256 scale = _mm256_set1_ps(VECTOR_SCALE);

    /* Pre-broadcast query as float vectors */
    const __m256 qv0  = _mm256_set1_ps((float)q[0]  * VECTOR_SCALE);
    const __m256 qv1  = _mm256_set1_ps((float)q[1]  * VECTOR_SCALE);
    const __m256 qv2  = _mm256_set1_ps((float)q[2]  * VECTOR_SCALE);
    const __m256 qv3  = _mm256_set1_ps((float)q[3]  * VECTOR_SCALE);
    const __m256 qv4  = _mm256_set1_ps((float)q[4]  * VECTOR_SCALE);
    const __m256 qv5  = _mm256_set1_ps((float)q[5]  * VECTOR_SCALE);
    const __m256 qv6  = _mm256_set1_ps((float)q[6]  * VECTOR_SCALE);
    const __m256 qv7  = _mm256_set1_ps((float)q[7]  * VECTOR_SCALE);
    const __m256 qv8  = _mm256_set1_ps((float)q[8]  * VECTOR_SCALE);
    const __m256 qv9  = _mm256_set1_ps((float)q[9]  * VECTOR_SCALE);
    const __m256 qv10 = _mm256_set1_ps((float)q[10] * VECTOR_SCALE);
    const __m256 qv11 = _mm256_set1_ps((float)q[11] * VECTOR_SCALE);
    const __m256 qv12 = _mm256_set1_ps((float)q[12] * VECTOR_SCALE);
    const __m256 qv13 = _mm256_set1_ps((float)q[13] * VECTOR_SCALE);

    /* dim_pair! macro: process two adjacent dimensions, accumulate into acc0/acc1 */
#define DIM_PAIR(acc0, acc1, bb, d) do {                                      \
        __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + (bb) + (d)*8));      \
        __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + (bb) + ((d)+1)*8));  \
        __m256 v0 = _mm256_mul_ps(                                            \
            _mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);           \
        __m256 v1 = _mm256_mul_ps(                                            \
            _mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);           \
        __m256 d0 = _mm256_sub_ps(v0, qv##d);                                 \
        __m256 d1 = _mm256_sub_ps(v1, qv##d##_1);                             \
        (acc0) = _mm256_fmadd_ps(d0, d0, (acc0));                             \
        (acc1) = _mm256_fmadd_ps(d1, d1, (acc1));                             \
    } while(0)

    /* Helper to get qv for dim d+1. Since we can't do qv##d##_1 with macros easily,
     * we need individual macros or an array. Let's inline manually for the pairs. */
    /* Pairs: (0,1), (2,3), (4,5), (6,7), (8,9), (10,11), (12,13) */

    float dists_buf[8] __attribute__((aligned(32)));

    for (int bi = start_block; bi < end_block; bi++) {
        /* Software prefetch: fetch 8 blocks ahead */
        int pf_block = bi + 8;
        if (pf_block < end_block) {
            _mm_prefetch((const char *)(blocks + (size_t)pf_block * BLOCK_STRIDE),
                         _MM_HINT_T0);
            _mm_prefetch((const char *)(blocks + (size_t)pf_block * BLOCK_STRIDE + 56),
                         _MM_HINT_T0);
        }

        size_t bb = (size_t)bi * BLOCK_STRIDE;
        const uint8_t *lb = labels + (size_t)bi * 8;
        __m256 threshold = _mm256_set1_ps(*worst_d);

        /* Phase 1: first 4 dim-pairs (8 dims) with early termination */
        __m256 acc0 = _mm256_setzero_ps();
        __m256 acc1 = _mm256_setzero_ps();

        /* Pair (0,1) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 0));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 8));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv0), _mm256_sub_ps(v0, qv0), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv1), _mm256_sub_ps(v1, qv1), acc1); }

        /* Pair (2,3) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 16));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 24));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv2), _mm256_sub_ps(v0, qv2), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv3), _mm256_sub_ps(v1, qv3), acc1); }

        /* Pair (4,5) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 32));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 40));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv4), _mm256_sub_ps(v0, qv4), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv5), _mm256_sub_ps(v1, qv5), acc1); }

        /* Pair (6,7) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 48));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 56));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv6), _mm256_sub_ps(v0, qv6), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv7), _mm256_sub_ps(v1, qv7), acc1); }

        /* Early termination: check if any of the 8 partial sums could beat worst */
        __m256 partial = _mm256_add_ps(acc0, acc1);
        if (_mm256_movemask_ps(_mm256_cmp_ps(partial, threshold, _CMP_LT_OQ)) == 0)
            continue;

        /* Phase 2: remaining 6 dims (pairs 8,9; 10,11; 12,13) */
        /* Pair (8,9) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 64));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 72));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv8), _mm256_sub_ps(v0, qv8), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv9), _mm256_sub_ps(v1, qv9), acc1); }

        /* Pair (10,11) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 80));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 88));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv10), _mm256_sub_ps(v0, qv10), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv11), _mm256_sub_ps(v1, qv11), acc1); }

        /* Pair (12,13) */
        { __m128i r0 = _mm_loadu_si128((const __m128i *)(blocks + bb + 96));
          __m128i r1 = _mm_loadu_si128((const __m128i *)(blocks + bb + 104));
          __m256 v0 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r0)), scale);
          __m256 v1 = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(r1)), scale);
          acc0 = _mm256_fmadd_ps(_mm256_sub_ps(v0, qv12), _mm256_sub_ps(v0, qv12), acc0);
          acc1 = _mm256_fmadd_ps(_mm256_sub_ps(v1, qv13), _mm256_sub_ps(v1, qv13), acc1); }

        __m256 acc = _mm256_add_ps(acc0, acc1);
        int mask = _mm256_movemask_ps(_mm256_cmp_ps(acc, threshold, _CMP_LT_OQ));
        if (mask == 0) continue;

        _mm256_store_ps(dists_buf, acc);
        int m = mask;
        while (m != 0) {
            int slot = __builtin_ctz(m);
            m &= m - 1;
            float di = dists_buf[slot];
            if (di < *worst_d) {
                try_insert_top5_f(di, lb[slot], best_d, best_l, worst, worst_d);
            }
        }
    }
#undef DIM_PAIR
}
#endif

static inline void scan_blocks(int start_block, int end_block, const int16_t q[DIM],
                               float best_d[5], uint8_t best_l[5],
                               int *worst, float *worst_d) {
#ifdef __AVX2__
    scan_blocks_avx2(start_block, end_block, q, best_d, best_l, worst, worst_d);
#else
    scan_blocks_scalar(start_block, end_block, q, best_d, best_l, worst, worst_d);
#endif
}

/* --- Search with nprobe (block-based) --- */

static inline int count_frauds5(const uint8_t best_l[5]) {
    return (best_l[0] == 1) + (best_l[1] == 1) + (best_l[2] == 1) +
           (best_l[3] == 1) + (best_l[4] == 1);
}

static int search_with_nprobe(int nprobe_to_use, const int best_c[], const float best_p[],
                              const int16_t q[DIM]) {
    int nprobe = nprobe_to_use;
    if (nprobe > IVF_CLUSTERS) nprobe = IVF_CLUSTERS;
    if (nprobe < 1) nprobe = 1;

    float best_d[5] = { INFINITY, INFINITY, INFINITY, INFINITY, INFINITY };
    uint8_t best_l[5] = {0, 0, 0, 0, 0};
    int worst = 0;
    float worst_d = INFINITY;

    for (int pi = 0; pi < nprobe; pi++) {
        int c = best_c[pi];
        if (c < 0) continue;
        int start_block = (int)g_dataset.block_offsets[c];
        int end_block   = (int)g_dataset.block_offsets[c + 1];
        if (end_block <= start_block) continue;

        int nblocks = end_block - start_block;
        if (g_candidates > 0) {
            /* candidates limits number of vectors (not blocks) */
            int max_blocks = (g_candidates + 7) / 8;
            if (nblocks > max_blocks) nblocks = max_blocks;
            end_block = start_block + nblocks;
        }
        scan_blocks(start_block, end_block, q, best_d, best_l, &worst, &worst_d);
        if (g_candidates > 0 && pi == nprobe - 1) break;
    }

    /* No bbox pass — AoSoA with early termination is sufficient */

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

    /* Reorder: scan smallest clusters first (by block count) */
    for (int i = 0; i < full_nprobe - 1; i++) {
        for (int j = i + 1; j < full_nprobe; j++) {
            int si = (int)(g_dataset.block_offsets[best_c[i] + 1] - g_dataset.block_offsets[best_c[i]]);
            int sj = (int)(g_dataset.block_offsets[best_c[j] + 1] - g_dataset.block_offsets[best_c[j]]);
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
