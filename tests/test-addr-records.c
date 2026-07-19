#include "rn_addr_records.h"

#include <arpa/inet.h>
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

int
main(void)
{
    struct sockaddr_in ipv4;
    struct sockaddr_in6 ipv6;
    unsigned char oversized[sizeof(struct sockaddr_storage) + 1];
    rn_addr_source_t sources[5];
    r_addr_t records[3];
    size_t count;

    memset(&ipv4, 0, sizeof(ipv4));
    ipv4.sin_family = AF_INET;
    ipv4.sin_port = htons(19080);
    if (inet_pton(AF_INET, "192.0.2.10", &ipv4.sin_addr) != 1) {
        return 1;
    }
    memset(&ipv6, 0, sizeof(ipv6));
    ipv6.sin6_family = AF_INET6;
    ipv6.sin6_port = htons(19081);
    if (inet_pton(AF_INET6, "2001:db8::10", &ipv6.sin6_addr) != 1) {
        return 1;
    }
    memset(oversized, 0x5a, sizeof(oversized));
    sources[0] = (rn_addr_source_t) { &ipv4, sizeof(ipv4) };
    sources[1] = (rn_addr_source_t) { oversized, sizeof(oversized) };
    sources[2] = (rn_addr_source_t) { NULL, sizeof(ipv4) };
    sources[3] = (rn_addr_source_t) { &ipv6, sizeof(ipv6) };
    sources[4] = (rn_addr_source_t) { &ipv4, 0 };

    memset(records, 0xa5, sizeof(records));
    count = rn_addr_records_compact(sources, 5, records, 3);
    if (check(count == 2, "valid addresses were not compacted")
        || check(records[0].len == sizeof(ipv4)
            && records[1].len == sizeof(ipv6),
            "compacted address lengths are wrong")
        || check(memcmp(&records[0].sa, &ipv4, sizeof(ipv4)) == 0
            && memcmp(&records[1].sa, &ipv6, sizeof(ipv6)) == 0,
            "compacted addresses are out of order or corrupted"))
    {
        return 1;
    }

    memset(records, 0xa5, sizeof(records));
    if (check(rn_addr_records_compact(sources, 5, records, 1) == 1,
            "output capacity was not respected")
        || check(records[0].len == sizeof(ipv4),
            "capacity-limited output selected the wrong address")
        || check(rn_addr_records_compact(&sources[1], 2, records, 3) == 0,
            "an oversized or null address was reported as valid")
        || check(rn_addr_records_compact(NULL, 5, records, 3) == 0,
            "null source array was accepted")
        || check(rn_addr_records_compact(sources, 5, NULL, 3) == 0,
            "null output array was accepted"))
    {
        return 1;
    }

    puts("PASS resolver addresses are compacted to the reported count");
    return 0;
}
