//
// Created by thiagorigonatti on 29/04/26.
//

#ifndef RINHA_HTTP_RESPONSES_H
#define RINHA_HTTP_RESPONSES_H
#include "common.h"

extern char resp_score[6][RES_BUF_SIZE];
extern size_t resp_score_len[6];
extern char resp_ready[RES_BUF_SIZE];
extern size_t resp_ready_len;
extern char resp_404[RES_BUF_SIZE];
extern size_t resp_404_len;
extern char resp_400[RES_BUF_SIZE];
extern size_t resp_400_len;
extern char resp_413[RES_BUF_SIZE];
extern size_t resp_413_len;
extern char resp_500[RES_BUF_SIZE];
extern size_t resp_500_len;
void http_responses_init(void);

#endif
