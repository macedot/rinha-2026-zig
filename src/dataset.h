//
// Created by thiagorigonatti on 29/04/26.
//

#ifndef RINHA_DATASET_H
#define RINHA_DATASET_H
#include "common.h"

typedef struct {
    int n;
    int16_t *dim[DIM];
    uint8_t *labels;
    uint32_t *orig_ids;
    float *centroids;              /* IVF_CLUSTERS * DIM */
    int16_t *bbox_min;             /* IVF_CLUSTERS * DIM, quantized */
    int16_t *bbox_max;             /* IVF_CLUSTERS * DIM, quantized */
    int cluster_start[IVF_CLUSTERS];
    int cluster_end[IVF_CLUSTERS];
} dataset_t;

extern dataset_t g_dataset;
int dataset_load_index(const char *path);
void dataset_free(void);

#endif
