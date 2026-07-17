#ifndef RN_SRV_RECORDS_H
#define RN_SRV_RECORDS_H

#include <stddef.h>
#include <stdint.h>

#include <r_client_io.h>

typedef struct {
    const unsigned char *target;
    size_t target_len;
    uint16_t port;
    uint16_t priority;
    uint16_t weight;
    uint32_t ttl_ms;
} rn_srv_source_t;

typedef void *(*rn_srv_alloc_pt)(size_t size, void *ctx);
typedef void (*rn_srv_free_pt)(void *ptr, void *ctx);

typedef struct {
    r_srv_record_t *records;
    char **targets;
    size_t count;
} rn_srv_records_t;

int rn_srv_records_build(
    const rn_srv_source_t *sources,
    size_t count,
    rn_srv_alloc_pt alloc,
    rn_srv_free_pt free_fn,
    void *alloc_ctx,
    rn_srv_records_t *out
);

void rn_srv_records_free(
    rn_srv_records_t *records,
    rn_srv_free_pt free_fn,
    void *alloc_ctx
);

#endif
