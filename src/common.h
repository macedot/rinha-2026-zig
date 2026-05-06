//
// Created by thiagorigonatti on 29/04/26.
//

#ifndef RINHA_COMMON_H
#define RINHA_COMMON_H

#define _GNU_SOURCE

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/wait.h>
#include <math.h>
#include <liburing.h>

#ifdef __AVX2__
#include <immintrin.h>
#endif

#define DIM 14
#define K_NEIGHBORS 5
#define CACHELINE 64
#define FIX_SCALE 10000.0f

#define IVF_CLUSTERS 256
#define IVF_DEFAULT_NPROBE 32
#define IVF_MAX_NPROBE 512

#define REQ_BUF_SIZE 32768
#define RES_BUF_SIZE 512
#define MAX_CONNS 4096

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

static inline int env_int(const char *name, int def, int minv, int maxv) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    long x = strtol(v, NULL, 10);
    if (x < minv) x = minv;
    if (x > maxv) x = maxv;
    return (int)x;
}

static inline float env_float(const char *name, float def, float minv, float maxv) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    float x = strtof(v, NULL);
    if (x < minv) x = minv;
    if (x > maxv) x = maxv;
    return x;
}

static inline const char *env_str(const char *name, const char *def) {
    const char *v = getenv(name);
    return (v && *v) ? v : def;
}

#endif
