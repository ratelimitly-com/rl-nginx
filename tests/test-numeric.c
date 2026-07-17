#include "rn_numeric.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int
check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        return 1;
    }
    return 0;
}

static int
expect_u32_ok(const char *text, uint32_t expected)
{
    uint32_t actual = UINT32_C(0xA5A5A5A5);

    if (rn_numeric_parse_u32((const unsigned char *) text, strlen(text),
            &actual) != 0)
    {
        fprintf(stderr, "FAIL rejected u32: %s\n", text);
        return 1;
    }
    return check(actual == expected, "parsed u32 has the wrong value");
}

static int
expect_u32_error(const char *text)
{
    uint32_t actual = UINT32_C(0xA5A5A5A5);

    if (rn_numeric_parse_u32((const unsigned char *) text, strlen(text),
            &actual) == 0)
    {
        fprintf(stderr, "FAIL accepted invalid u32: %s\n", text);
        return 1;
    }
    return check(actual == UINT32_C(0xA5A5A5A5),
        "failed u32 parse changed its output");
}

static int
expect_rate_ok(const char *text, uint32_t expected_rate,
    uint32_t expected_window_ms)
{
    uint32_t rate = UINT32_C(0xA5A5A5A5);
    uint32_t window_ms = UINT32_C(0x5A5A5A5A);

    if (rn_numeric_parse_rate((const unsigned char *) text, strlen(text),
            &rate, &window_ms) != 0)
    {
        fprintf(stderr, "FAIL rejected rate: %s\n", text);
        return 1;
    }
    if (rate != expected_rate || window_ms != expected_window_ms) {
        fprintf(stderr,
            "FAIL wrong rate result: %s -> rate=%u window_ms=%u\n",
            text, rate, window_ms);
        return 1;
    }
    return 0;
}

static int
expect_rate_error(const char *text)
{
    uint32_t rate = UINT32_C(0xA5A5A5A5);
    uint32_t window_ms = UINT32_C(0x5A5A5A5A);

    if (rn_numeric_parse_rate((const unsigned char *) text, strlen(text),
            &rate, &window_ms) == 0)
    {
        fprintf(stderr, "FAIL accepted invalid rate: %s\n", text);
        return 1;
    }
    return check(rate == UINT32_C(0xA5A5A5A5)
            && window_ms == UINT32_C(0x5A5A5A5A),
        "failed rate parse changed an output");
}

int
main(void)
{
    uint32_t narrowed = UINT32_C(0xA5A5A5A5);

    if (expect_u32_ok("0", 0)
        || expect_u32_ok("4294967295", UINT32_MAX)
        || expect_u32_error("4294967296")
        || expect_u32_error("18446744073709551616")
        || expect_u32_error("12x")
        || expect_u32_error(""))
    {
        return 1;
    }

    if (check(rn_numeric_u32_from_u64(UINT32_MAX, &narrowed) == 0
            && narrowed == UINT32_MAX,
            "rejected largest protocol duration")
        || check(rn_numeric_u32_from_u64(UINT64_C(4294967296), &narrowed) != 0,
            "accepted first oversized protocol duration")
        || check(narrowed == UINT32_MAX,
            "failed duration narrowing changed its output"))
    {
        return 1;
    }

    if (check(rn_numeric_ttl_ms_until(1000, 1000) == 0,
            "expired DNS deadline returned a positive TTL")
        || check(rn_numeric_ttl_ms_until(1001, 1000) == 1000,
            "DNS deadline was not converted from remaining seconds")
        || check(rn_numeric_ttl_ms_until(UINT64_C(5294967), UINT64_C(1000000))
                == UINT32_C(4294967000),
            "largest whole-second DNS TTL was not preserved")
        || check(rn_numeric_ttl_ms_until(UINT64_C(5294968), UINT64_C(1000000))
                == UINT32_MAX,
            "oversized DNS TTL was not saturated")
        || check(rn_numeric_ttl_ms_until(UINT64_MAX, 0) == UINT32_MAX,
            "extreme DNS TTL was not saturated"))
    {
        return 1;
    }

    if (expect_rate_ok("4294967295r/s", UINT32_MAX, 1000)
        || expect_rate_error("4294967296r/s")
        || expect_rate_error("18446744073709551616r/s")
        || expect_rate_ok("1r/s", 1, 1000)
        || expect_rate_ok("1r/0s", 1, 1000)
        || expect_rate_ok("1r/4294967s", 1, UINT32_C(4294967000))
        || expect_rate_error("1r/4294968s")
        || expect_rate_ok("1r/71582m", 1, UINT32_C(4294920000))
        || expect_rate_error("1r/71583m")
        || expect_rate_ok("1r/1193h", 1, UINT32_C(4294800000))
        || expect_rate_error("1r/1194h")
        || expect_rate_error("1r/18446744073709551616s")
        || expect_rate_error("0r/s")
        || expect_rate_error("1r/d")
        || expect_rate_error("1r/suffix"))
    {
        return 1;
    }

    puts("PASS numeric boundaries preserve protocol widths");
    return 0;
}
