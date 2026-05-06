//
// Created by thiagorigonatti on 29/04/26.
//

#ifndef RINHA_CONFIG_H
#define RINHA_CONFIG_H
#include "common.h"

typedef struct {
    const char *index_path;
    const char *mcc_risk_path;
    int ivf_nprobe;
    int candidates;
    int workers;
    int use_tcp;
    int port;
    const char *host;
    const char *uds_path;
    int uds_mode;
    int unlink_uds;
    int io_uring_qd;
    int accept_sqe_count;
    int backlog;
    int sqpoll;
    int sqpoll_cpu;
    int tcp_nodelay;
    int reuse_port;
    float amount_divisor;
    float installments_divisor;
    float tx24h_divisor;
    float km_divisor;
    float merchant_amount_divisor;
} app_config_t;

extern app_config_t g_cfg;
void config_load(void);
void config_print(void);
#endif
