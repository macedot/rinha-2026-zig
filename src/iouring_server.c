//
// Created by thiagorigonatti on 29/04/26.
//

#include "iouring_server.h"
#include "config.h"
#include "vectorizer.h"
#include "ivf_search.h"
#include "http_responses.h"

#define OP_ACCEPT 1
#define OP_READ   2
#define OP_WRITE  3

typedef struct {
    int fd;
    int used;
    int close_after_write;
    char req_buf[REQ_BUF_SIZE];
    size_t req_len;
    char res_buf[RES_BUF_SIZE];
    size_t res_len;
    size_t res_sent;
} conn_t;

static struct io_uring ring;
static conn_t conns[MAX_CONNS];

static inline void *pack_udata(int type, void *ptr) {
    return (void *)(((uint64_t)type << 48) | ((uint64_t)ptr & 0x0000FFFFFFFFFFFFULL));
}
static inline int unpack_type(void *data) { return (int)((uint64_t)data >> 48); }
static inline void *unpack_ptr(void *data) { return (void *)((uint64_t)data & 0x0000FFFFFFFFFFFFULL); }

static int set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static inline void set_response(conn_t *c, const char *src, size_t len, int close_after_write) {
    if (unlikely(len >= sizeof(c->res_buf))) len = sizeof(c->res_buf) - 1;
    memcpy(c->res_buf, src, len);
    c->res_len = len;
    c->res_sent = 0;
    c->close_after_write = close_after_write;
}

static struct io_uring_sqe *get_sqe_or_submit(void) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    if (unlikely(!sqe)) {
        io_uring_submit(&ring);
        sqe = io_uring_get_sqe(&ring);
    }
    return sqe;
}

static void add_accept(int server_fd) {
    struct io_uring_sqe *sqe = get_sqe_or_submit();
    io_uring_prep_accept(sqe, server_fd, NULL, NULL, 0);
    io_uring_sqe_set_data(sqe, pack_udata(OP_ACCEPT, NULL));
}

static void add_read(conn_t *c) {
    if (unlikely(c->req_len >= REQ_BUF_SIZE - 1)) return;
    struct io_uring_sqe *sqe = get_sqe_or_submit();
    io_uring_prep_recv(sqe, c->fd, c->req_buf + c->req_len, REQ_BUF_SIZE - 1 - c->req_len, 0);
    io_uring_sqe_set_data(sqe, pack_udata(OP_READ, c));
}

static void add_write(conn_t *c) {
    if (unlikely(c->res_sent >= c->res_len)) return;
    struct io_uring_sqe *sqe = get_sqe_or_submit();
    io_uring_prep_send(sqe, c->fd, c->res_buf + c->res_sent, c->res_len - c->res_sent, 0);
    io_uring_sqe_set_data(sqe, pack_udata(OP_WRITE, c));
}

static conn_t *alloc_conn(int fd) {
    for (int i = 0; i < MAX_CONNS; i++) {
        if (!conns[i].used) {
            conn_t *c = &conns[i];
            memset(c, 0, sizeof(*c));
            c->used = 1;
            c->fd = fd;
            return c;
        }
    }
    return NULL;
}

static void free_conn(conn_t *c) {
    if (unlikely(!c || !c->used)) return;
    close(c->fd);
    memset(c, 0, sizeof(*c));
}

static int try_process_request(conn_t *c) {
    c->req_buf[c->req_len] = '\0';
    char *header_end = strstr(c->req_buf, "\r\n\r\n");
    if (!header_end) {
        if (unlikely(c->req_len >= REQ_BUF_SIZE - 1)) {
            set_response(c, resp_413, resp_413_len, 1);
            add_write(c);
            return 1;
        }
        return 0;
    }

    if (strncmp(c->req_buf, "GET /ready", 10) == 0) {
        set_response(c, resp_ready, resp_ready_len, 0);
        add_write(c);
        return 1;
    }

    size_t header_len = (size_t)(header_end - c->req_buf) + 4;
    if (likely(strncmp(c->req_buf, "POST /fraud-score", 17) == 0)) {
        char *cl = strstr(c->req_buf, "Content-Length:");
        if (unlikely(!cl || cl > header_end)) cl = strcasestr(c->req_buf, "Content-Length:");
        if (unlikely(!cl || cl > header_end)) {
            set_response(c, resp_400, resp_400_len, 1);
            add_write(c);
            return 1;
        }
        cl += strlen("Content-Length:");
        while (*cl == ' ' || *cl == '\t') cl++;
        long content_length = strtol(cl, NULL, 10);
        if (unlikely(content_length < 0 || content_length > (long)(REQ_BUF_SIZE - header_len - 1))) {
            set_response(c, resp_413, resp_413_len, 1);
            add_write(c);
            return 1;
        }
        if (c->req_len < header_len + (size_t)content_length) return 0;

        char *body = c->req_buf + header_len;
        body[content_length] = '\0';
        float q[DIM] __attribute__((aligned(64)));
        if (unlikely(vectorizer_build(body, (size_t)content_length, q) != 0)) {
            set_response(c, resp_400, resp_400_len, 1);
            add_write(c);
            return 1;
        }
        int frauds = ivf_search_fraud_votes(q);
        if (unlikely(frauds < 0 || frauds > 5)) {
            set_response(c, resp_500, resp_500_len, 1);
            add_write(c);
            return 1;
        }
        set_response(c, resp_score[frauds], resp_score_len[frauds], 0);
        add_write(c);
        return 1;
    }

    set_response(c, resp_404, resp_404_len, 1);
    add_write(c);
    return 1;
}

static int create_tcp_socket(void) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket tcp"); return -1; }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
    if (g_cfg.reuse_port) setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif
#ifdef TCP_NODELAY
    if (g_cfg.tcp_nodelay) setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
#endif
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)g_cfg.port);
    if (strcmp(g_cfg.host, "0.0.0.0") == 0) addr.sin_addr.s_addr = INADDR_ANY;
    else inet_pton(AF_INET, g_cfg.host, &addr.sin_addr);
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind tcp"); close(server_fd); return -1; }
    if (listen(server_fd, g_cfg.backlog) != 0) { perror("listen tcp"); close(server_fd); return -1; }
    if (set_nonblock(server_fd) != 0) { perror("nonblock tcp"); close(server_fd); return -1; }
    fprintf(stderr, "listening TCP %s:%d\n", g_cfg.host, g_cfg.port);
    return server_fd;
}

static int octal_from_decimal_mode(int mode) {
    int a = mode / 100;
    int b = (mode / 10) % 10;
    int c = mode % 10;
    return (a << 6) | (b << 3) | c;
}

static int create_uds_socket(void) {
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket uds"); return -1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(g_cfg.uds_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "UDS_PATH muito longo: %s\n", g_cfg.uds_path);
        close(server_fd);
        return -1;
    }
    strncpy(addr.sun_path, g_cfg.uds_path, sizeof(addr.sun_path) - 1);
    if (g_cfg.unlink_uds) unlink(g_cfg.uds_path);
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind uds"); close(server_fd); return -1; }
    chmod(g_cfg.uds_path, (mode_t)octal_from_decimal_mode(g_cfg.uds_mode));
    if (listen(server_fd, g_cfg.backlog) != 0) { perror("listen uds"); close(server_fd); return -1; }
    if (set_nonblock(server_fd) != 0) { perror("nonblock uds"); close(server_fd); return -1; }
    fprintf(stderr, "listening UDS %s mode=%d\n", g_cfg.uds_path, g_cfg.uds_mode);
    return server_fd;
}

static int create_server_socket(void) {
    return g_cfg.use_tcp ? create_tcp_socket() : create_uds_socket();
}

static int setup_ring(void) {
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
#ifdef IORING_SETUP_SINGLE_ISSUER
    p.flags |= IORING_SETUP_SINGLE_ISSUER;
#endif
#ifdef IORING_SETUP_COOP_TASKRUN
    p.flags |= IORING_SETUP_COOP_TASKRUN;
#endif
#ifdef IORING_SETUP_SQPOLL
    if (g_cfg.sqpoll) {
        p.flags |= IORING_SETUP_SQPOLL;
        if (g_cfg.sqpoll_cpu >= 0) {
            p.flags |= IORING_SETUP_SQ_AFF;
            p.sq_thread_cpu = (unsigned)g_cfg.sqpoll_cpu;
        }
    }
#endif
    int rc = io_uring_queue_init_params((unsigned)g_cfg.io_uring_qd, &ring, &p);
    if (rc != 0 && g_cfg.sqpoll) {
        fprintf(stderr, "io_uring SQPOLL falhou (%d), tentando sem SQPOLL\n", rc);
        memset(&p, 0, sizeof(p));
#ifdef IORING_SETUP_SINGLE_ISSUER
        p.flags |= IORING_SETUP_SINGLE_ISSUER;
#endif
#ifdef IORING_SETUP_COOP_TASKRUN
        p.flags |= IORING_SETUP_COOP_TASKRUN;
#endif
        rc = io_uring_queue_init_params((unsigned)g_cfg.io_uring_qd, &ring, &p);
    }
    if (rc != 0) fprintf(stderr, "io_uring_queue_init_params falhou: %d\n", rc);
    return rc;
}

int server_run_forever(void) {
    int server_fd = create_server_socket();
    if (server_fd < 0) return 1;
    if (setup_ring() != 0) { close(server_fd); return 1; }
    for (int i = 0; i < g_cfg.accept_sqe_count; i++) add_accept(server_fd);
    io_uring_submit(&ring);

    while (1) {
        struct io_uring_cqe *cqe = NULL;
        int wait_rc = io_uring_wait_cqe(&ring, &cqe);
        if (unlikely(wait_rc != 0 || !cqe)) continue;
        void *data = io_uring_cqe_get_data(cqe);
        int type = unpack_type(data);
        conn_t *conn = (conn_t *)unpack_ptr(data);
        int res = cqe->res;
        io_uring_cqe_seen(&ring, cqe);

        if (type == OP_ACCEPT) {
            if (likely(res >= 0)) {
                int client_fd = res;
                set_nonblock(client_fd);
                if (g_cfg.use_tcp && g_cfg.tcp_nodelay) {
#ifdef TCP_NODELAY
                    int opt = 1;
                    setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
#endif
                }
                conn_t *c = alloc_conn(client_fd);
                if (likely(c)) add_read(c);
                else close(client_fd);
            }
            add_accept(server_fd);
        } else if (type == OP_READ) {
            if (unlikely(!conn || !conn->used)) continue;
            if (unlikely(res <= 0)) free_conn(conn);
            else {
                conn->req_len += (size_t)res;
                if (!try_process_request(conn)) add_read(conn);
            }
        } else if (type == OP_WRITE) {
            if (unlikely(!conn || !conn->used)) continue;
            if (unlikely(res <= 0)) free_conn(conn);
            else {
                conn->res_sent += (size_t)res;
                if (conn->res_sent < conn->res_len) add_write(conn);
                else {
                    if (conn->close_after_write) free_conn(conn);
                    else {
                        conn->req_len = 0;
                        conn->res_len = 0;
                        conn->res_sent = 0;
                        conn->close_after_write = 0;
                        add_read(conn);
                    }
                }
            }
        }
        io_uring_submit(&ring);
    }
}
