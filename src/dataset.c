//
// Created by thiagorigonatti on 29/04/26.
//

#include "dataset.h"

static int read_exact(FILE *f, void *ptr, size_t len) {
    return fread(ptr, 1, len, f) == len ? 0 : -1;
}

dataset_t g_dataset;

int dataset_load_index(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return -1;
    }

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
        fclose(f);
        return -1;
    }

    if (k != IVF_CLUSTERS || d != DIM || stride != DIM) {
        fprintf(stderr, "index incompatível: k=%u d=%u stride=%u esperado k=%d d=%d stride=%d\n", k, d, stride, IVF_CLUSTERS, DIM, DIM);
        fclose(f);
        return -1;
    }
    if (fabsf(scale - FIX_SCALE) > 0.01f) {
        fprintf(stderr, "index incompatível: scale=%.1f esperado=%.1f\n", scale, FIX_SCALE);
        fclose(f);
        return -1;
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
    fprintf(stderr, "index IVF6 carregado: N=%u K=%u scale=%.1f memoria=%.2f MB\n", n, k, scale, mb);
    return 0;
}

void dataset_free(void) {
    for (int j = 0; j < DIM; j++) free(g_dataset.dim[j]);
    free(g_dataset.labels);
    free(g_dataset.orig_ids);
    free(g_dataset.centroids);
    free(g_dataset.bbox_min);
    free(g_dataset.bbox_max);
    memset(&g_dataset, 0, sizeof(g_dataset));
}
