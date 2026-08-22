#include "rn_resolv_conf.h"

#include <string.h>

#define RN_RESOLV_DIRECTIVE "nameserver"
#define RN_RESOLV_DIRECTIVE_LEN (sizeof(RN_RESOLV_DIRECTIVE) - 1)

static int
rn_resolv_is_blank(char c)
{
    return c == ' ' || c == '\t';
}

static int
rn_resolv_ends_field(char c)
{
    /* Field separators, line endings, and both resolv.conf comment markers. */
    return rn_resolv_is_blank(c) || c == '\0' || c == '\r' || c == '\n'
        || c == '#' || c == ';';
}

/*
 * Copies an address into the output buffer, truncating it to the capacity.
 * Returns 0 when the address did not fit.
 */
static int
rn_resolv_store(const char *address, size_t len, char *out, size_t out_capacity,
    size_t *out_len)
{
    int complete;

    complete = len + 1 <= out_capacity;
    if (!complete) {
        len = out_capacity - 1;
    }
    memcpy(out, address, len);
    out[len] = '\0';
    *out_len = len;
    return complete;
}

rn_resolv_nameserver_t
rn_resolv_conf_nameserver(const char *line, size_t line_len, char *out,
    size_t out_capacity, size_t *out_len)
{
    const char *p;
    const char *end;
    const char *address;
    size_t      len;
    int         bracketed;

    if (out == NULL || out_capacity == 0 || out_len == NULL) {
        return RN_RESOLV_NAMESERVER_NONE;
    }

    out[0] = '\0';
    *out_len = 0;

    if (line == NULL) {
        return RN_RESOLV_NAMESERVER_NONE;
    }

    p = line;
    end = line + line_len;
    while (p < end && rn_resolv_is_blank(*p)) {
        p++;
    }

    /* The keyword must be a complete field; "nameserverX" is another directive. */
    if ((size_t) (end - p) < RN_RESOLV_DIRECTIVE_LEN
        || memcmp(p, RN_RESOLV_DIRECTIVE, RN_RESOLV_DIRECTIVE_LEN) != 0)
    {
        return RN_RESOLV_NAMESERVER_NONE;
    }
    p += RN_RESOLV_DIRECTIVE_LEN;
    if (p < end && !rn_resolv_ends_field(*p)) {
        return RN_RESOLV_NAMESERVER_NONE;
    }

    while (p < end && rn_resolv_is_blank(*p)) {
        p++;
    }
    address = p;
    while (p < end && !rn_resolv_ends_field(*p)) {
        p++;
    }
    len = (size_t) (p - address);

    if (len == 0) {
        return RN_RESOLV_NAMESERVER_UNUSABLE;
    }

    /*
     * A zone index (fe80::1%eth0) is valid in resolv.conf, but ngx_inet6_addr()
     * rejects it. Report it instead of failing the whole configuration.
     */
    if (memchr(address, '%', len) != NULL) {
        rn_resolv_store(address, len, out, out_capacity, out_len);
        return RN_RESOLV_NAMESERVER_UNUSABLE;
    }

    bracketed = address[0] == '[';
    if (bracketed && (len < 3 || address[len - 1] != ']')) {
        rn_resolv_store(address, len, out, out_capacity, out_len);
        return RN_RESOLV_NAMESERVER_UNUSABLE;
    }

    if (bracketed || memchr(address, ':', len) == NULL) {
        /* Already in the form ngx_parse_url() expects. */
        if (!rn_resolv_store(address, len, out, out_capacity, out_len)) {
            return RN_RESOLV_NAMESERVER_UNUSABLE;
        }
        return bracketed ? RN_RESOLV_NAMESERVER_INET6
                         : RN_RESOLV_NAMESERVER_INET;
    }

    /*
     * ngx_parse_url() selects its IPv6 parser only for a bracketed literal. A
     * bare IPv6 address is read as host:port and rejected as an invalid port.
     */
    if (len + 3 > out_capacity) {
        rn_resolv_store(address, len, out, out_capacity, out_len);
        return RN_RESOLV_NAMESERVER_UNUSABLE;
    }
    out[0] = '[';
    memcpy(out + 1, address, len);
    out[len + 1] = ']';
    out[len + 2] = '\0';
    *out_len = len + 2;
    return RN_RESOLV_NAMESERVER_INET6;
}
