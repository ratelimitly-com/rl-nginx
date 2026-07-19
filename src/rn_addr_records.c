#include "rn_addr_records.h"

#include <string.h>

size_t
rn_addr_records_compact(const rn_addr_source_t *sources, size_t source_count,
    r_addr_t *out, size_t out_capacity)
{
    size_t i;
    size_t out_count;

    if (sources == NULL || source_count == 0 || out == NULL
        || out_capacity == 0)
    {
        return 0;
    }

    out_count = 0;
    for (i = 0; i < source_count && out_count < out_capacity; i++) {
        if (sources[i].sockaddr == NULL || sources[i].socklen == 0
            || sources[i].socklen > sizeof(out[out_count].sa))
        {
            continue;
        }
        memset(&out[out_count], 0, sizeof(out[out_count]));
        memcpy(&out[out_count].sa, sources[i].sockaddr, sources[i].socklen);
        out[out_count].len = (socklen_t) sources[i].socklen;
        out_count++;
    }

    return out_count;
}
