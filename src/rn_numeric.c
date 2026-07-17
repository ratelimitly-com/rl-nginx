#include "rn_numeric.h"

#include <stdint.h>

int
rn_numeric_parse_u32(const unsigned char *data, size_t len, uint32_t *out)
{
    uint32_t digit;
    uint32_t value;
    size_t i;

    if (data == NULL || len == 0 || out == NULL) {
        return -1;
    }

    value = 0;
    for (i = 0; i < len; i++) {
        if (data[i] < '0' || data[i] > '9') {
            return -1;
        }
        digit = (uint32_t) (data[i] - '0');
        if (value > (UINT32_MAX - digit) / 10) {
            return -1;
        }
        value = value * 10 + digit;
    }
    *out = value;
    return 0;
}

int
rn_numeric_u32_from_u64(uint64_t value, uint32_t *out)
{
    if (out == NULL || value > UINT32_MAX) {
        return -1;
    }
    *out = (uint32_t) value;
    return 0;
}

uint32_t
rn_numeric_ttl_ms_until(uint64_t expires_at_s, uint64_t now_s)
{
    uint64_t remaining_s;

    if (expires_at_s <= now_s) {
        return 0;
    }
    remaining_s = expires_at_s - now_s;
    if (remaining_s > UINT32_MAX / 1000) {
        return UINT32_MAX;
    }
    return (uint32_t) remaining_s * 1000;
}

int
rn_numeric_parse_rate(const unsigned char *data, size_t len,
    uint32_t *out_rate, uint32_t *out_window_ms)
{
    uint32_t digit;
    uint32_t rate;
    uint32_t window;
    uint32_t factor;
    size_t pos;

    if (data == NULL || len == 0 || out_rate == NULL || out_window_ms == NULL) {
        return -1;
    }

    rate = 0;
    pos = 0;
    while (pos < len && data[pos] >= '0' && data[pos] <= '9') {
        digit = (uint32_t) (data[pos] - '0');
        if (rate > (UINT32_MAX - digit) / 10) {
            return -1;
        }
        rate = rate * 10 + digit;
        pos++;
    }
    if (rate == 0 || pos >= len || data[pos++] != 'r'
        || pos >= len || data[pos++] != '/')
    {
        return -1;
    }

    window = 0;
    while (pos < len && data[pos] >= '0' && data[pos] <= '9') {
        digit = (uint32_t) (data[pos] - '0');
        if (window > (UINT32_MAX - digit) / 10) {
            return -1;
        }
        window = window * 10 + digit;
        pos++;
    }
    if (window == 0) {
        window = 1;
    }
    if (pos + 1 != len) {
        return -1;
    }

    switch (data[pos]) {
    case 's':
        factor = 1000;
        break;
    case 'm':
        factor = 60000;
        break;
    case 'h':
        factor = 3600000;
        break;
    default:
        return -1;
    }
    if (window > UINT32_MAX / factor) {
        return -1;
    }

    *out_rate = rate;
    *out_window_ms = window * factor;
    return 0;
}
