//
// Created by thiagorigonatti on 29/04/26.
//

#include "common.h"
#include "config.h"
#include "dataset.h"
#include "mcc_risk.h"
#include "http_responses.h"
#include "iouring_server.h"

int main(void) {
    config_load();
    config_print();
    http_responses_init();
    mcc_risk_load(g_cfg.mcc_risk_path);

    if (dataset_load_index(g_cfg.index_path) != 0) {
        fprintf(stderr, "falha carregando INDEX_PATH=%s\n", g_cfg.index_path);
        return 1;
    }

#ifdef __AVX2__
    fprintf(stderr, "engine: IVF/kmeans + int16 + top5 seco + AVX2\n");
#else
    fprintf(stderr, "engine: IVF/kmeans + int16 + top5 seco + escalar\n");
#endif

    for (int i = 1; i < g_cfg.workers; i++) {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); break; }
        if (pid == 0) return server_run_forever();
    }
    return server_run_forever();
}
