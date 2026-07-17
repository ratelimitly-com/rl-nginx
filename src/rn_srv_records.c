#include "rn_srv_records.h"

#include <stdint.h>
#include <string.h>

void
rn_srv_records_free(rn_srv_records_t *records, rn_srv_free_pt free_fn,
    void *alloc_ctx)
{
    size_t i;

    if (records == NULL || free_fn == NULL) {
        return;
    }
    if (records->targets != NULL) {
        for (i = 0; i < records->count; i++) {
            if (records->targets[i] != NULL) {
                free_fn(records->targets[i], alloc_ctx);
            }
        }
        free_fn(records->targets, alloc_ctx);
    }
    if (records->records != NULL) {
        free_fn(records->records, alloc_ctx);
    }
    memset(records, 0, sizeof(*records));
}

int
rn_srv_records_build(const rn_srv_source_t *sources, size_t count,
    rn_srv_alloc_pt alloc, rn_srv_free_pt free_fn, void *alloc_ctx,
    rn_srv_records_t *out)
{
    size_t i;

    if (out == NULL) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (sources == NULL || count == 0 || alloc == NULL || free_fn == NULL
        || count > SIZE_MAX / sizeof(r_srv_record_t)
        || count > SIZE_MAX / sizeof(char *))
    {
        return -1;
    }

    out->records = alloc(count * sizeof(r_srv_record_t), alloc_ctx);
    if (out->records == NULL) {
        return -1;
    }
    memset(out->records, 0, count * sizeof(r_srv_record_t));

    out->targets = alloc(count * sizeof(char *), alloc_ctx);
    if (out->targets == NULL) {
        rn_srv_records_free(out, free_fn, alloc_ctx);
        return -1;
    }
    memset(out->targets, 0, count * sizeof(char *));
    out->count = count;

    for (i = 0; i < count; i++) {
        if (sources[i].target == NULL || sources[i].target_len == 0
            || sources[i].target_len == SIZE_MAX)
        {
            rn_srv_records_free(out, free_fn, alloc_ctx);
            return -1;
        }
        out->targets[i] = alloc(sources[i].target_len + 1, alloc_ctx);
        if (out->targets[i] == NULL) {
            rn_srv_records_free(out, free_fn, alloc_ctx);
            return -1;
        }
        memcpy(out->targets[i], sources[i].target, sources[i].target_len);
        out->targets[i][sources[i].target_len] = '\0';

        out->records[i].target = out->targets[i];
        out->records[i].port = sources[i].port;
        out->records[i].priority = sources[i].priority;
        out->records[i].weight = sources[i].weight;
        out->records[i].ttl_ms = sources[i].ttl_ms;
    }

    return 0;
}
