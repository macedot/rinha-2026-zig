//
// Created by thiagorigonatti on 29/04/26.
//

#include "http_responses.h"

char resp_score[6][RES_BUF_SIZE];
size_t resp_score_len[6];
char resp_ready[RES_BUF_SIZE];
size_t resp_ready_len;
char resp_404[RES_BUF_SIZE];
size_t resp_404_len;
char resp_400[RES_BUF_SIZE];
size_t resp_400_len;
char resp_413[RES_BUF_SIZE];
size_t resp_413_len;
char resp_500[RES_BUF_SIZE];
size_t resp_500_len;

void http_responses_init(void) {
    for (int frauds = 0; frauds <= 5; frauds++) {
        float score = (float)frauds * 0.2f;
        const char *approved = frauds < 3 ? "true" : "false";
        char body[96];
        int body_len = snprintf(body, sizeof(body), "{\"approved\":%s,\"fraud_score\":%.4f}", approved, score);
        resp_score_len[frauds] = (size_t)snprintf(resp_score[frauds], sizeof(resp_score[frauds]),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %d\r\n"
            "Connection: keep-alive\r\n"
            "\r\n%s", body_len, body);
    }
    resp_ready_len = (size_t)snprintf(resp_ready, sizeof(resp_ready),
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n");
    resp_404_len = (size_t)snprintf(resp_404, sizeof(resp_404),
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    static const char bad_body[] = "{\"error\":\"invalid_payload\"}";
    resp_400_len = (size_t)snprintf(resp_400, sizeof(resp_400),
        "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
        sizeof(bad_body) - 1, bad_body);
    resp_413_len = (size_t)snprintf(resp_413, sizeof(resp_413),
        "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    resp_500_len = (size_t)snprintf(resp_500, sizeof(resp_500),
        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}
