#ifndef RN_NUMERIC_H
#define RN_NUMERIC_H

#include <stddef.h>
#include <stdint.h>

int rn_numeric_parse_u32(
    const unsigned char *data,
    size_t len,
    uint32_t *out
);

int rn_numeric_u32_from_u64(uint64_t value, uint32_t *out);

uint32_t rn_numeric_ttl_ms_until(uint64_t expires_at_s, uint64_t now_s);

int rn_numeric_parse_rate(
    const unsigned char *data,
    size_t len,
    uint32_t *out_rate,
    uint32_t *out_window_ms
);

#endif
