#ifndef BRIDGE_H
#define BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

int rinha_load_index(const char *path);
void rinha_set_search_params(int nprobe, int full_nprobe, int candidates);
int rinha_search(const float q[14]);

#ifdef __cplusplus
}
#endif

#endif
