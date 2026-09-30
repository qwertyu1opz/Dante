
#include "dcurl.h"

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#error "dcurl needs OpenSSL 1.1.0 or newer"
#endif

#define DC_DEFAULT_TIMEOUT_MS 30000
#define DC_DEFAULT_MAX_BODY   ((size_t)8 << 20)
#define DC_MAX_HEADER_BLOCK   ((size_t)64 << 10)
#define DC_MAX_LINE           8192
#define DC_RBUF               16384

#ifdef MSG_NOSIGNAL
#define DC_SEND_FLAGS MSG_NOSIGNAL
#else
#define DC_SEND_FLAGS 0
#endif

struct dc_ctx {
    SSL_CTX *ssl;
    size_t   ca_count;
};

typedef struct {
    int            fd;
    SSL           *ssl;
    long long      deadline;
    int            unclean_eof;
    char           why[200];
    size_t         roff, rlen;
    unsigned char  rbuf[DC_RBUF];
} dc_conn;

typedef struct {
    unsigned char *p;
    size_t         len, cap, limit;
} dc_bytes;

typedef struct {
    int      tls;
    char     host[256];
    uint16_t port;
    char    *path;
} dc_url;

#pragma mark - Helpers

static long long dc_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void dc_fail(dc_response *r, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(r->error, sizeof(r->error), fmt, ap);
    va_end(ap);
}

static int dc_why(dc_conn *c, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(c->why, sizeof(c->why), fmt, ap);
    va_end(ap);
    return -1;
}

static int dc_why_errno(dc_conn *c, int err) {
    return dc_why(c, "%s", err ? strerror(err) : "connection closed");
}

static int dc_why_ssl(dc_conn *c, int sslerr) {
    unsigned long e = ERR_get_error();
    if (e) {
        char buf[160];
        ERR_error_string_n(e, buf, sizeof(buf));
        ERR_clear_error();
        return dc_why(c, "%s", buf);
    }
    if (sslerr == SSL_ERROR_SYSCALL || sslerr == SSL_ERROR_ZERO_RETURN)
        return dc_why_errno(c, sslerr == SSL_ERROR_SYSCALL ? errno : 0);
    return dc_why(c, "TLS error %d", sslerr);
}

static int dc_bytes_add(dc_bytes *b, const void *data, size_t n) {
    if (n > b->limit - b->len) return -1;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 1024;
        while (cap < b->len + n + 1) cap *= 2;
        unsigned char *p = realloc(b->p, cap);
        if (!p) return -1;
        b->p = p;
        b->cap = cap;
    }
    if (n) memcpy(b->p + b->len, data, n);
    b->len += n;
    b->p[b->len] = 0;
    return 0;
}

static int dc_bytes_printf(dc_bytes *b, const char *fmt, ...) {
    char small[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    va_end(ap);
    if (n < 0) return -1;
    if ((size_t)n < sizeof(small)) return dc_bytes_add(b, small, (size_t)n);

    char *big = malloc((size_t)n + 1);
    if (!big) return -1;
    va_start(ap, fmt);
    vsnprintf(big, (size_t)n + 1, fmt, ap);
    va_end(ap);
    int rc = dc_bytes_add(b, big, (size_t)n);
    free(big);
    return rc;
}

static int dc_is_ip_literal(const char *host) {
    unsigned char buf[16];
    return inet_pton(AF_INET, host, buf) == 1 || inet_pton(AF_INET6, host, buf) == 1;
}

#pragma mark - Context

dc_ctx *dc_ctx_new(void) {
    OPENSSL_init_ssl(0, NULL);

    dc_ctx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->ssl = SSL_CTX_new(TLS_client_method());
    if (!ctx->ssl) {
        free(ctx);
        return NULL;
    }
    SSL_CTX_set_min_proto_version(ctx->ssl, TLS1_2_VERSION);
    SSL_CTX_set_verify(ctx->ssl, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_options(ctx->ssl, SSL_OP_NO_COMPRESSION);
#ifdef SSL_OP_NO_RENEGOTIATION
    SSL_CTX_set_options(ctx->ssl, SSL_OP_NO_RENEGOTIATION);
#endif
    static const unsigned char alpn[] = "\x08http/1.1";
    SSL_CTX_set_alpn_protos(ctx->ssl, alpn, sizeof(alpn) - 1);
    return ctx;
}

int dc_ctx_add_ca_der(dc_ctx *ctx, const void *der, size_t len) {
    if (!ctx || !der || len == 0 || len > LONG_MAX) return -1;
    const unsigned char *p = der;
    X509 *cert = d2i_X509(NULL, &p, (long)len);
    if (!cert) {
        ERR_clear_error();
        return -1;
    }
    int ok = X509_STORE_add_cert(SSL_CTX_get_cert_store(ctx->ssl), cert);
    X509_free(cert);
    if (!ok) {
        unsigned long e = ERR_peek_last_error();
        ERR_clear_error();
        return ERR_GET_REASON(e) == X509_R_CERT_ALREADY_IN_HASH_TABLE ? 0 : -1;
    }
    ctx->ca_count++;
    return 0;
}

size_t dc_ctx_ca_count(const dc_ctx *ctx) {
    return ctx ? ctx->ca_count : 0;
}

void dc_ctx_free(dc_ctx *ctx) {
    if (!ctx) return;
    SSL_CTX_free(ctx->ssl);
    free(ctx);
}

#pragma mark - URL

static int dc_parse_url(const char *url, dc_url *u, dc_response *r) {
    const char *p;
    memset(u, 0, sizeof(*u));

    for (p = url; *p; p++) {
        if ((unsigned char)*p <= 0x20 || *p == 0x7f) {
            dc_fail(r, "URL contains spaces or control characters");
            return -1;
        }
    }

    if (strncasecmp(url, "https://", 8) == 0) {
        u->tls = 1;
        u->port = 443;
        p = url + 8;
    } else if (strncasecmp(url, "http://", 7) == 0) {
        u->port = 80;
        p = url + 7;
    } else {
        dc_fail(r, "only http:// and https:// URLs are supported");
        return -1;
    }

    const char *end = p + strcspn(p, "/?#");
    if (memchr(p, '@', (size_t)(end - p))) {
        dc_fail(r, "credentials in the URL are not supported");
        return -1;
    }

    const char *hs = p, *he, *portp = NULL;
    if (*p == '[') {
        const char *rb = memchr(p, ']', (size_t)(end - p));
        if (!rb || (rb + 1 < end && rb[1] != ':')) {
            dc_fail(r, "malformed IPv6 host in the URL");
            return -1;
        }
        hs = p + 1;
        he = rb;
        if (rb + 1 < end) portp = rb + 2;
    } else {
        const char *colon = memchr(p, ':', (size_t)(end - p));
        he = colon ? colon : end;
        if (colon) portp = colon + 1;
    }

    size_t hl = (size_t)(he - hs);
    if (hl == 0 || hl >= sizeof(u->host)) {
        dc_fail(r, "missing or oversized host in the URL");
        return -1;
    }
    memcpy(u->host, hs, hl);
    u->host[hl] = 0;

    if (portp) {
        unsigned long v = 0;
        const char *q;
        for (q = portp; q < end; q++) {
            if (!isdigit((unsigned char)*q) || (v = v * 10 + (unsigned long)(*q - '0')) > 65535) {
                v = 0;
                break;
            }
        }
        if (v == 0) {
            dc_fail(r, "bad port in the URL");
            return -1;
        }
        u->port = (uint16_t)v;
    }

    size_t pl = strcspn(end, "#");
    u->path = malloc(pl + 2);
    if (!u->path) {
        dc_fail(r, "out of memory");
        return -1;
    }
    if (*end == '/') {
        memcpy(u->path, end, pl);
        u->path[pl] = 0;
    } else {
        u->path[0] = '/';
        memcpy(u->path + 1, end, pl);
        u->path[pl + 1] = 0;
    }
    return 0;
}

#pragma mark - Sockets

static int dc_wait(dc_conn *c, short events) {
    for (;;) {
        long long left = c->deadline - dc_now_ms();
        if (left <= 0) return dc_why(c, "timed out");
        struct pollfd pfd;
        pfd.fd = c->fd;
        pfd.events = events;
        pfd.revents = 0;
        int n = poll(&pfd, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (n > 0) return 0;
        if (n == 0) return dc_why(c, "timed out");
        if (errno != EINTR) return dc_why_errno(c, errno);
    }
}

static int dc_socket(int family) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int dc_connect_addr(dc_conn *c, const struct sockaddr *sa, socklen_t len) {
    int fd = dc_socket(sa->sa_family);
    if (fd < 0) return dc_why_errno(c, errno);
    c->fd = fd;
    if (connect(fd, sa, len) == 0) return 0;
    if (errno != EINPROGRESS) {
        dc_why_errno(c, errno);
    } else if (dc_wait(c, POLLOUT) == 0) {
        int err = 0;
        socklen_t el = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) != 0) err = errno;
        if (err == 0) return 0;
        dc_why_errno(c, err);
    }
    close(fd);
    c->fd = -1;
    return -1;
}

static int dc_dial(dc_conn *c, const char *host, uint16_t port, int numeric) {
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[8];
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (numeric) hints.ai_flags = AI_NUMERICHOST;
    snprintf(portstr, sizeof(portstr), "%u", (unsigned)port);

    int rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0 || !res) {
        if (res) freeaddrinfo(res);
        return dc_why(c, "cannot resolve %s: %s", host, rc ? gai_strerror(rc) : "no addresses");
    }
    for (ai = res; ai; ai = ai->ai_next) {
        if (dc_connect_addr(c, ai->ai_addr, ai->ai_addrlen) == 0) {
            freeaddrinfo(res);
            return 0;
        }
        if (dc_now_ms() >= c->deadline) break;
    }
    freeaddrinfo(res);
    char detail[sizeof(c->why)];
    memcpy(detail, c->why, sizeof(detail));
    return dc_why(c, "cannot connect to %s:%u: %s", host, (unsigned)port, detail);
}

static int dc_raw_write(dc_conn *c, const void *buf, size_t len) {
    const unsigned char *p = buf;
    while (len) {
        ssize_t n = send(c->fd, p, len, DC_SEND_FLAGS);
        if (n > 0) {
            p += n;
            len -= (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (dc_wait(c, POLLOUT)) return -1;
            continue;
        }
        return dc_why_errno(c, errno);
    }
    return 0;
}

static int dc_raw_read_exact(dc_conn *c, void *buf, size_t len) {
    unsigned char *p = buf;
    while (len) {
        ssize_t n = recv(c->fd, p, len, 0);
        if (n > 0) {
            p += n;
            len -= (size_t)n;
            continue;
        }
        if (n == 0) return dc_why(c, "connection closed");
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (dc_wait(c, POLLIN)) return -1;
            continue;
        }
        return dc_why_errno(c, errno);
    }
    return 0;
}

#pragma mark - SOCKS5

static const char *dc_socks_reason(unsigned char code) {
    switch (code) {
        case 1: return "general failure";
        case 2: return "not allowed by ruleset";
        case 3: return "network unreachable";
        case 4: return "host unreachable";
        case 5: return "connection refused";
        case 6: return "TTL expired";
        case 7: return "command not supported";
        case 8: return "address type not supported";
    }
    return "unknown error";
}

static int dc_socks5(dc_conn *c, const char *host, uint16_t port) {
    static const unsigned char greet[3] = {0x05, 0x01, 0x00};
    unsigned char buf[272];
    size_t n = 0;

    if (dc_raw_write(c, greet, sizeof(greet)) || dc_raw_read_exact(c, buf, 2))
        return dc_why(c, "SOCKS5 greeting failed: %.150s", c->why);
    if (buf[0] != 0x05 || buf[1] != 0x00)
        return dc_why(c, "SOCKS5 proxy refused the no-auth method");

    buf[n++] = 0x05;
    buf[n++] = 0x01;
    buf[n++] = 0x00;
    struct in_addr a4;
    struct in6_addr a6;
    if (inet_pton(AF_INET, host, &a4) == 1) {
        buf[n++] = 0x01;
        memcpy(buf + n, &a4, 4);
        n += 4;
    } else if (inet_pton(AF_INET6, host, &a6) == 1) {
        buf[n++] = 0x04;
        memcpy(buf + n, &a6, 16);
        n += 16;
    } else {
        size_t hl = strlen(host);
        if (hl == 0 || hl > 255) return dc_why(c, "host name too long for SOCKS5");
        buf[n++] = 0x03;
        buf[n++] = (unsigned char)hl;
        memcpy(buf + n, host, hl);
        n += hl;
    }
    buf[n++] = (unsigned char)(port >> 8);
    buf[n++] = (unsigned char)(port & 0xff);

    if (dc_raw_write(c, buf, n) || dc_raw_read_exact(c, buf, 4))
        return dc_why(c, "SOCKS5 CONNECT failed: %.150s", c->why);
    if (buf[0] != 0x05) return dc_why(c, "not a SOCKS5 reply");
    if (buf[1] != 0x00)
        return dc_why(c, "SOCKS5 CONNECT to %s:%u refused: %s",
                      host, (unsigned)port, dc_socks_reason(buf[1]));

    size_t skip;
    switch (buf[3]) {
        case 0x01: skip = 4; break;
        case 0x04: skip = 16; break;
        case 0x03:
            if (dc_raw_read_exact(c, buf, 1)) return -1;
            skip = buf[0];
            break;
        default:
            return dc_why(c, "SOCKS5 reply has a bad address type");
    }
    return dc_raw_read_exact(c, buf, skip + 2);
}

#pragma mark - TLS

static int dc_tls_start(dc_conn *c, dc_ctx *ctx, const char *host) {
    if (!ctx || ctx->ca_count == 0)
        return dc_why(c, "no trusted roots loaded, refusing an unverified TLS connection");

    c->ssl = SSL_new(ctx->ssl);
    if (!c->ssl || !SSL_set_fd(c->ssl, c->fd)) return dc_why_ssl(c, SSL_ERROR_SSL);

    X509_VERIFY_PARAM *vp = SSL_get0_param(c->ssl);
    X509_VERIFY_PARAM_set_hostflags(vp, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (dc_is_ip_literal(host)) {
        if (!X509_VERIFY_PARAM_set1_ip_asc(vp, host)) return dc_why_ssl(c, SSL_ERROR_SSL);
    } else if (!SSL_set_tlsext_host_name(c->ssl, host) || !X509_VERIFY_PARAM_set1_host(vp, host, 0)) {
        return dc_why_ssl(c, SSL_ERROR_SSL);
    }

    for (;;) {
        ERR_clear_error();
        int rc = SSL_connect(c->ssl);
        if (rc == 1) return 0;
        int e = SSL_get_error(c->ssl, rc);
        if (e == SSL_ERROR_WANT_READ) {
            if (dc_wait(c, POLLIN)) return -1;
            continue;
        }
        if (e == SSL_ERROR_WANT_WRITE) {
            if (dc_wait(c, POLLOUT)) return -1;
            continue;
        }
        long verify = SSL_get_verify_result(c->ssl);
        if (verify != X509_V_OK) {
            ERR_clear_error();
            return dc_why(c, "certificate of %s rejected: %s",
                          host, X509_verify_cert_error_string(verify));
        }
        dc_why_ssl(c, e);
        char detail[sizeof(c->why)];
        memcpy(detail, c->why, sizeof(detail));
        return dc_why(c, "TLS handshake with %s failed: %.150s", host, detail);
    }
}

#pragma mark - Connection I/O

static int dc_write(dc_conn *c, const void *buf, size_t len) {
    if (!c->ssl) return dc_raw_write(c, buf, len);
    const unsigned char *p = buf;
    while (len) {
        int chunk = len > INT_MAX ? INT_MAX : (int)len;
        ERR_clear_error();
        int n = SSL_write(c->ssl, p, chunk);
        if (n > 0) {
            p += n;
            len -= (size_t)n;
            continue;
        }
        int e = SSL_get_error(c->ssl, n);
        if (e == SSL_ERROR_WANT_READ) {
            if (dc_wait(c, POLLIN)) return -1;
        } else if (e == SSL_ERROR_WANT_WRITE) {
            if (dc_wait(c, POLLOUT)) return -1;
        } else {
            return dc_why_ssl(c, e);
        }
    }
    return 0;
}

/* > 0: bytes read, 0: end of stream, -1: error. */
static ssize_t dc_read_some(dc_conn *c, void *buf, size_t cap) {
    if (!c->ssl) {
        for (;;) {
            ssize_t n = recv(c->fd, buf, cap, 0);
            if (n >= 0) return n;
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (dc_wait(c, POLLIN)) return -1;
                continue;
            }
            return dc_why_errno(c, errno);
        }
    }
    for (;;) {
        ERR_clear_error();
        int n = SSL_read(c->ssl, buf, cap > INT_MAX ? INT_MAX : (int)cap);
        if (n > 0) return n;
        int e = SSL_get_error(c->ssl, n);
        if (e == SSL_ERROR_ZERO_RETURN) return 0;
        if (e == SSL_ERROR_WANT_READ) {
            if (dc_wait(c, POLLIN)) return -1;
            continue;
        }
        if (e == SSL_ERROR_WANT_WRITE) {
            if (dc_wait(c, POLLOUT)) return -1;
            continue;
        }
        /* The peer closed TCP without close_notify. Whether that truncated
         * anything is decided by the caller from the framing. */
        if (e == SSL_ERROR_SYSCALL && n == 0 && ERR_peek_error() == 0) {
            c->unclean_eof = 1;
            return 0;
        }
#ifdef SSL_R_UNEXPECTED_EOF_WHILE_READING
        if (e == SSL_ERROR_SSL &&
            ERR_GET_REASON(ERR_peek_error()) == SSL_R_UNEXPECTED_EOF_WHILE_READING) {
            ERR_clear_error();
            c->unclean_eof = 1;
            return 0;
        }
#endif
        return dc_why_ssl(c, e);
    }
}

/* 1: more data buffered, 0: end of stream, -1: error. */
static int dc_fill(dc_conn *c) {
    if (c->roff > 0) {
        memmove(c->rbuf, c->rbuf + c->roff, c->rlen - c->roff);
        c->rlen -= c->roff;
        c->roff = 0;
    }
    if (c->rlen == sizeof(c->rbuf)) return dc_why(c, "read buffer overflow");
    ssize_t n = dc_read_some(c, c->rbuf + c->rlen, sizeof(c->rbuf) - c->rlen);
    if (n < 0) return -1;
    if (n == 0) return 0;
    c->rlen += (size_t)n;
    return 1;
}

/* One line without its CRLF; returns its length or -1. */
static long dc_read_line(dc_conn *c, char *out, size_t cap) {
    for (;;) {
        unsigned char *start = c->rbuf + c->roff;
        size_t avail = c->rlen - c->roff;
        unsigned char *nl = memchr(start, '\n', avail);
        if (nl) {
            size_t len = (size_t)(nl - start);
            size_t take = (len && start[len - 1] == '\r') ? len - 1 : len;
            if (take >= cap) return dc_why(c, "response line too long");
            memcpy(out, start, take);
            out[take] = 0;
            c->roff += len + 1;
            return (long)take;
        }
        if (avail >= cap) return dc_why(c, "response line too long");
        int f = dc_fill(c);
        if (f < 0) return -1;
        if (f == 0) return dc_why(c, "connection closed in the middle of the response");
    }
}

/* Points *p at up to max buffered bytes; returns their count, 0 at end of stream, -1 on error. */
static long dc_take(dc_conn *c, const unsigned char **p, size_t max) {
    if (c->roff == c->rlen) {
        c->roff = c->rlen = 0;
        int f = dc_fill(c);
        if (f <= 0) return f;
    }
    size_t avail = c->rlen - c->roff;
    if (avail > max) avail = max;
    *p = c->rbuf + c->roff;
    c->roff += avail;
    return (long)avail;
}

#pragma mark - HTTP

static int dc_has_header(const char *const *headers, const char *name) {
    size_t nl = strlen(name);
    if (!headers) return 0;
    for (; *headers; headers++) {
        if (strncasecmp(*headers, name, nl) == 0 && (*headers)[nl] == ':') return 1;
    }
    return 0;
}

static int dc_build_request(const dc_request *req, const dc_url *u, const char *method,
                            dc_bytes *out, dc_response *r) {
    const char *const *h;
    for (h = req->headers; h && *h; h++) {
        if (strpbrk(*h, "\r\n") || !strchr(*h, ':') || **h == ':') {
            dc_fail(r, "malformed request header");
            return -1;
        }
    }

    int v6 = strchr(u->host, ':') != NULL;
    int defaultPort = u->port == (u->tls ? 443 : 80);
    int ok = dc_bytes_printf(out, "%s %s HTTP/1.1\r\n", method, u->path) == 0;
    if (ok && !dc_has_header(req->headers, "Host")) {
        ok = defaultPort
            ? dc_bytes_printf(out, "Host: %s%s%s\r\n", v6 ? "[" : "", u->host, v6 ? "]" : "") == 0
            : dc_bytes_printf(out, "Host: %s%s%s:%u\r\n", v6 ? "[" : "", u->host, v6 ? "]" : "",
                              (unsigned)u->port) == 0;
    }
    if (ok && !dc_has_header(req->headers, "User-Agent"))
        ok = dc_bytes_printf(out, "User-Agent: dcurl/1.0\r\n") == 0;
    if (ok && !dc_has_header(req->headers, "Accept"))
        ok = dc_bytes_printf(out, "Accept: */*\r\n") == 0;
    if (ok && !dc_has_header(req->headers, "Connection"))
        ok = dc_bytes_printf(out, "Connection: close\r\n") == 0;
    if (ok && !dc_has_header(req->headers, "Content-Length") &&
        (req->body_len || !strcmp(method, "POST") || !strcmp(method, "PUT") || !strcmp(method, "PATCH")))
        ok = dc_bytes_printf(out, "Content-Length: %lu\r\n", (unsigned long)req->body_len) == 0;
    for (h = req->headers; ok && h && *h; h++)
        ok = dc_bytes_printf(out, "%s\r\n", *h) == 0;
    if (ok) ok = dc_bytes_add(out, "\r\n", 2) == 0;
    if (ok && req->body_len) ok = dc_bytes_add(out, req->body, req->body_len) == 0;

    if (!ok) dc_fail(r, "out of memory");
    return ok ? 0 : -1;
}

static int dc_body_exact(dc_conn *c, dc_bytes *out, unsigned long long n) {
    if (n > out->limit - out->len) return dc_why(c, "response body too large");
    while (n) {
        const unsigned char *p = NULL;
        long got = dc_take(c, &p, n > DC_RBUF ? DC_RBUF : (size_t)n);
        if (got < 0) return -1;
        if (got == 0) return dc_why(c, "connection closed before the body was complete");
        if (dc_bytes_add(out, p, (size_t)got)) return dc_why(c, "out of memory");
        n -= (unsigned long long)got;
    }
    return 0;
}

static int dc_body_to_eof(dc_conn *c, dc_bytes *out) {
    for (;;) {
        const unsigned char *p = NULL;
        long got = dc_take(c, &p, DC_RBUF);
        if (got < 0) return -1;
        if (got == 0) return 0;
        if (dc_bytes_add(out, p, (size_t)got)) return dc_why(c, "response body too large");
    }
}

static int dc_body_chunked(dc_conn *c, dc_bytes *out) {
    char line[DC_MAX_LINE];
    for (;;) {
        if (dc_read_line(c, line, sizeof(line)) < 0) return -1;
        if (!isxdigit((unsigned char)line[0])) return dc_why(c, "bad chunk size");
        char *end = NULL;
        errno = 0;
        unsigned long long size = strtoull(line, &end, 16);
        if (errno || (*end && *end != ';' && *end != ' ' && *end != '\t'))
            return dc_why(c, "bad chunk size");
        if (size == 0) break;
        if (dc_body_exact(c, out, size)) return -1;
        long n = dc_read_line(c, line, sizeof(line));
        if (n < 0) return -1;
        if (n != 0) return dc_why(c, "chunk is longer than announced");
    }
    for (;;) {                                    /* trailers */
        long n = dc_read_line(c, line, sizeof(line));
        if (n < 0) return -1;
        if (n == 0) return 0;
    }
}

static int dc_parse_length(const char *v, unsigned long long *out) {
    unsigned long long n = 0;
    if (!isdigit((unsigned char)*v)) return -1;
    for (; isdigit((unsigned char)*v); v++) {
        unsigned d = (unsigned)(*v - '0');
        if (n > (ULLONG_MAX - d) / 10) return -1;
        n = n * 10 + d;
    }
    while (*v == ' ' || *v == '\t') v++;
    if (*v) return -1;
    *out = n;
    return 0;
}

static int dc_read_response(dc_conn *c, const char *method, size_t max_body, dc_response *r) {
    char line[DC_MAX_LINE];
    dc_bytes head;
    dc_bytes body;
    memset(&head, 0, sizeof(head));
    memset(&body, 0, sizeof(body));
    head.limit = DC_MAX_HEADER_BLOCK;
    body.limit = max_body;

    for (;;) {
        head.len = 0;
        if (dc_read_line(c, line, sizeof(line)) < 0) goto fail;
        const char *sp = strchr(line, ' ');
        if (strncmp(line, "HTTP/1.", 7) != 0 || !sp ||
            !isdigit((unsigned char)sp[1]) || !isdigit((unsigned char)sp[2]) ||
            !isdigit((unsigned char)sp[3]) || (sp[4] && sp[4] != ' ')) {
            dc_why(c, "not an HTTP/1.x response");
            goto fail;
        }
        long code = (sp[1] - '0') * 100 + (sp[2] - '0') * 10 + (sp[3] - '0');
        if (dc_bytes_printf(&head, "%s\r\n", line)) {
            dc_why(c, "out of memory");
            goto fail;
        }

        int chunked = 0, haveLength = 0;
        unsigned long long length = 0;
        for (;;) {
            long n = dc_read_line(c, line, sizeof(line));
            if (n < 0) goto fail;
            if (n == 0) break;
            if (dc_bytes_add(&head, line, (size_t)n) || dc_bytes_add(&head, "\r\n", 2)) {
                dc_why(c, "response headers too large");
                goto fail;
            }
            char *colon = strchr(line, ':');
            if (!colon) continue;
            *colon = 0;
            char *val = colon + 1;
            while (*val == ' ' || *val == '\t') val++;

            if (strcasecmp(line, "Content-Length") == 0) {
                unsigned long long v;
                if (dc_parse_length(val, &v) || (haveLength && v != length)) {
                    dc_why(c, "bad Content-Length");
                    goto fail;
                }
                length = v;
                haveLength = 1;
            } else if (strcasecmp(line, "Transfer-Encoding") == 0) {
                const char *last = strrchr(val, ',');
                last = last ? last + 1 : val;
                while (*last == ' ' || *last == '\t') last++;
                if (strncasecmp(last, "chunked", 7) != 0) {
                    dc_why(c, "unsupported transfer encoding: %.100s", val);
                    goto fail;
                }
                chunked = 1;
            }
        }

        if (code >= 100 && code < 200 && code != 101) continue;    /* interim response */

        int rc = 0;
        if (!strcmp(method, "HEAD") || code == 101 || code == 204 || code == 304)
            rc = 0;
        else if (chunked)
            rc = dc_body_chunked(c, &body);
        else if (haveLength)
            rc = dc_body_exact(c, &body, length);
        else
            rc = dc_body_to_eof(c, &body);
        if (rc) goto fail;
        if (!body.p && dc_bytes_add(&body, "", 0)) {
            dc_why(c, "out of memory");
            goto fail;
        }

        r->status = code;
        r->headers = (char *)head.p;
        r->body = body.p;
        r->body_len = body.len;
        return 0;
    }

fail:
    free(head.p);
    free(body.p);
    dc_fail(r, "%s", c->why);
    return -1;
}

static int dc_valid_method(const char *m) {
    if (!*m) return 0;
    for (; *m; m++)
        if (!isupper((unsigned char)*m)) return 0;
    return 1;
}

#pragma mark - Entry point

int dc_perform(dc_ctx *ctx, const dc_request *req, dc_response *r) {
    memset(r, 0, sizeof(*r));
    if (!req || !req->url) {
        dc_fail(r, "no URL");
        return -1;
    }
    if (req->body_len && !req->body) {
        dc_fail(r, "body length without a body");
        return -1;
    }

    dc_url u;
    if (dc_parse_url(req->url, &u, r)) {
        free(u.path);
        return -1;
    }
    const char *method = req->method ? req->method : (req->body_len ? "POST" : "GET");
    if (!dc_valid_method(method)) {
        free(u.path);
        dc_fail(r, "bad HTTP method");
        return -1;
    }

    dc_conn *c = calloc(1, sizeof(*c));
    if (!c) {
        free(u.path);
        dc_fail(r, "out of memory");
        return -1;
    }
    c->fd = -1;
    c->deadline = dc_now_ms() + (req->timeout_ms > 0 ? req->timeout_ms : DC_DEFAULT_TIMEOUT_MS);

    dc_bytes out;
    memset(&out, 0, sizeof(out));
    out.limit = (size_t)-1;
    int rc = -1;

    if (dc_build_request(req, &u, method, &out, r)) goto done;

    if (req->socks5_port) {
        const char *proxy = req->socks5_host ? req->socks5_host : "127.0.0.1";
        if (dc_dial(c, proxy, req->socks5_port, 0) || dc_socks5(c, u.host, u.port)) {
            dc_fail(r, "%s", c->why);
            goto done;
        }
    } else if (req->connect_ip && *req->connect_ip) {
        if (dc_dial(c, req->connect_ip, u.port, 1)) {
            dc_fail(r, "%s", c->why);
            goto done;
        }
    } else if (dc_dial(c, u.host, u.port, 0)) {
        dc_fail(r, "%s", c->why);
        goto done;
    }

    if (u.tls && dc_tls_start(c, ctx, u.host)) {
        dc_fail(r, "%s", c->why);
        goto done;
    }
    if (dc_write(c, out.p, out.len)) {
        dc_fail(r, "cannot send the request: %s", c->why);
        goto done;
    }
    rc = dc_read_response(c, method, req->max_body ? req->max_body : DC_DEFAULT_MAX_BODY, r);

done:
    free(out.p);
    free(u.path);
    if (c->ssl) SSL_free(c->ssl);
    if (c->fd >= 0) close(c->fd);
    free(c);
    return rc;
}

void dc_response_free(dc_response *r) {
    if (!r) return;
    free(r->headers);
    free(r->body);
    r->headers = NULL;
    r->body = NULL;
    r->body_len = 0;
}
