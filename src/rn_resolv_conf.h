#ifndef RN_RESOLV_CONF_H
#define RN_RESOLV_CONF_H

#include <stddef.h>

/*
 * Output buffer size a caller must provide for one nameserver argument. It
 * holds the longest value resolv.conf can name, a bracketed IPv6 literal, and
 * the terminating NUL that ngx_resolver_create() reads past the reported
 * length.
 */
#define RN_RESOLV_NAMESERVER_MAX 256

typedef enum {
    /* The line is not a nameserver directive. */
    RN_RESOLV_NAMESERVER_NONE = 0,
    /* An IPv4 literal or host name, copied verbatim. */
    RN_RESOLV_NAMESERVER_INET,
    /* An IPv6 literal, wrapped in the brackets nginx's parser requires. */
    RN_RESOLV_NAMESERVER_INET6,
    /* A nameserver nginx cannot parse; the output holds it for reporting. */
    RN_RESOLV_NAMESERVER_UNUSABLE
} rn_resolv_nameserver_t;

/*
 * Converts the nameserver of one /etc/resolv.conf line into an nginx resolver
 * argument. The output is always NUL-terminated within its capacity and
 * out_len reports its length excluding that NUL. Only RN_RESOLV_NAMESERVER_INET
 * and RN_RESOLV_NAMESERVER_INET6 produce a usable argument; an unusable entry
 * is still copied, truncated to the capacity, so a caller can name it.
 */
rn_resolv_nameserver_t rn_resolv_conf_nameserver(const char *line,
    size_t line_len, char *out, size_t out_capacity, size_t *out_len);

#endif
