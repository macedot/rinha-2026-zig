//
// Created by thiagorigonatti on 29/04/26.
//

#include "config.h"

app_config_t g_cfg;

void config_load(void) {
    g_cfg.index_path = env_str("INDEX_PATH", "resources/index.bin");
    g_cfg.mcc_risk_path = env_str("MCC_RISK_PATH", "resources/mcc_risk.json");
    g_cfg.ivf_nprobe = env_int("IVF_NPROBE", IVF_DEFAULT_NPROBE, 1, IVF_MAX_NPROBE);
    g_cfg.candidates = env_int("CANDIDATES", 0, 0, 2000000);
    g_cfg.workers = env_int("WORKERS", 1, 1, 16);
    g_cfg.use_tcp = env_int("LISTEN_TCP", 0, 0, 1);
    g_cfg.port = env_int("PORT", 9999, 1, 65535);
    g_cfg.host = env_str("HOST", "0.0.0.0");
    g_cfg.uds_path = env_str("UDS_PATH", env_str("SOCKET_PATH", "/tmp/rinha.sock"));
    g_cfg.uds_mode = env_int("UDS_MODE", 666, 0, 777);
    g_cfg.unlink_uds = env_int("UNLINK_UDS", 1, 0, 1);
    g_cfg.io_uring_qd = env_int("IOURING_QD", 4096, 64, 32768);
    g_cfg.accept_sqe_count = env_int("ACCEPT_SQES", 256, 1, 4096);
    g_cfg.backlog = env_int("BACKLOG", 4096, 16, 65535);
    g_cfg.sqpoll = env_int("IOURING_SQPOLL", 0, 0, 1);
    g_cfg.sqpoll_cpu = env_int("IOURING_SQPOLL_CPU", -1, -1, 256);
    g_cfg.tcp_nodelay = env_int("TCP_NODELAY", 1, 0, 1);
    g_cfg.reuse_port = env_int("SO_REUSEPORT_ENABLED", 1, 0, 1);
    g_cfg.amount_divisor = env_float("AMOUNT_DIVISOR", 10000.0f, 1.0f, 100000000.0f);
    g_cfg.installments_divisor = env_float("INSTALLMENTS_DIVISOR", 12.0f, 1.0f, 1000.0f);
    g_cfg.tx24h_divisor = env_float("TX24H_DIVISOR", 20.0f, 1.0f, 100000.0f);
    g_cfg.km_divisor = env_float("KM_DIVISOR", 1000.0f, 1.0f, 10000000.0f);
    g_cfg.merchant_amount_divisor = env_float("MERCHANT_AMOUNT_DIVISOR", 10000.0f, 1.0f, 100000000.0f);
}

void config_print(void) {
    fprintf(stderr,
        "config: INDEX_PATH=%s MCC_RISK_PATH=%s IVF_NPROBE=%d CANDIDATES=%d WORKERS=%d transport=%s %s:%d uds=%s qd=%d accepts=%d backlog=%d sqpoll=%d\n",
        g_cfg.index_path, g_cfg.mcc_risk_path, g_cfg.ivf_nprobe, g_cfg.candidates,
        g_cfg.workers, g_cfg.use_tcp ? "tcp" : "uds", g_cfg.host, g_cfg.port,
        g_cfg.uds_path, g_cfg.io_uring_qd, g_cfg.accept_sqe_count,
        g_cfg.backlog, g_cfg.sqpoll);
}
