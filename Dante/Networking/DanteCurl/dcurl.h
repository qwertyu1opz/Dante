
/*
 * dcurl — Dante's own tiny HTTP(S) client: HTTP/1.1 over OpenSSL, directly or
 * through a SOCKS5 proxy that resolves the host name (curl's --socks5-hostname).
 * Certificates are always verified against the roots added to the context.
 */

#ifndef DCURL_H
#define DCURL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_ctx dc_ctx;

/* One context holds the trust roots and TLS settings; it is safe to share
 * between threads once the roots are added. */
dc_ctx *dc_ctx_new(void);
int     dc_ctx_add_ca_der(dc_ctx *ctx, const void *der, size_t len);   /* 0 on success */
size_t  dc_ctx_ca_count(const dc_ctx *ctx);
void    dc_ctx_free(dc_ctx *ctx);

typedef struct {
    const char *method;             /* NULL: POST when there is a body, GET otherwise */
    const char *url;                /* http:// or https://, IPv6 literals in brackets */
    const char *const *headers;     /* "Name: value" strings, NULL-terminated; may be NULL */
    const void *body;
    size_t      body_len;
    const char *socks5_host;        /* NULL: 127.0.0.1 */
    uint16_t    socks5_port;        /* 0: connect directly */
    const char *connect_ip;         /* direct only: dial this address instead of resolving the host */
    int         timeout_ms;         /* whole transfer; 0: 30 s */
    size_t      max_body;           /* 0: 8 MB */
} dc_request;

typedef struct {
    long           status;          /* final HTTP status code */
    char          *headers;         /* raw header block of the final response, NUL-terminated */
    unsigned char *body;            /* decoded body (de-chunked), NUL-terminated for convenience */
    size_t         body_len;
    char           error[256];      /* set when dc_perform fails */
} dc_response;

/* Returns 0 when an HTTP response was received (whatever its status),
 * -1 on a transport, TLS or protocol error described in resp->error.
 * Call dc_response_free afterwards in both cases. */
int  dc_perform(dc_ctx *ctx, const dc_request *req, dc_response *resp);
void dc_response_free(dc_response *resp);

#ifdef __cplusplus
}
#endif

#endif
