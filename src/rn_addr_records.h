#ifndef RN_ADDR_RECORDS_H
#define RN_ADDR_RECORDS_H

#include <stddef.h>

#include "r_client_io.h"

typedef struct {
    const void *sockaddr;
    size_t socklen;
} rn_addr_source_t;

size_t rn_addr_records_compact(const rn_addr_source_t *sources,
    size_t source_count, r_addr_t *out, size_t out_capacity);

#endif
