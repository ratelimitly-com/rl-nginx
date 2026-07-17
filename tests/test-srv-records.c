#include "rn_srv_records.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t calls;
    size_t fail_on;
    size_t live;
} test_alloc_ctx_t;

static void *
test_alloc(size_t size, void *data)
{
    test_alloc_ctx_t *ctx = data;
    void *ptr;

    ctx->calls++;
    if (ctx->fail_on != 0 && ctx->calls == ctx->fail_on) {
        return NULL;
    }
    ptr = malloc(size);
    if (ptr != NULL) {
        ctx->live++;
    }
    return ptr;
}

static void
test_free(void *ptr, void *data)
{
    test_alloc_ctx_t *ctx = data;

    if (ptr != NULL) {
        ctx->live--;
        free(ptr);
    }
}

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
    static const unsigned char first_target[] = "s-1.localhost";
    static const unsigned char second_target[] = "s-2.localhost";
    rn_srv_source_t sources[2];
    rn_srv_records_t records;
    test_alloc_ctx_t alloc_ctx;
    size_t fail_on;

    memset(sources, 0, sizeof(sources));
    sources[0].target = first_target;
    sources[0].target_len = sizeof(first_target) - 1;
    sources[0].port = 19080;
    sources[0].priority = 10;
    sources[0].weight = 50;
    sources[0].ttl_ms = 30000;
    sources[1].target = second_target;
    sources[1].target_len = sizeof(second_target) - 1;
    sources[1].port = 19081;
    sources[1].priority = 11;
    sources[1].weight = 51;
    sources[1].ttl_ms = 31000;

    for (fail_on = 1; fail_on <= 4; fail_on++) {
        memset(&alloc_ctx, 0, sizeof(alloc_ctx));
        alloc_ctx.fail_on = fail_on;
        memset(&records, 0xA5, sizeof(records));
        if (check(rn_srv_records_build(sources, 2, test_alloc, test_free,
                    &alloc_ctx, &records) != 0,
                "injected allocation failure was accepted")
            || check(records.records == NULL && records.targets == NULL
                    && records.count == 0,
                "failed build returned a partial record array")
            || check(alloc_ctx.live == 0,
                "failed build leaked an allocation"))
        {
            return 1;
        }
    }

    memset(&alloc_ctx, 0, sizeof(alloc_ctx));
    memset(&records, 0, sizeof(records));
    sources[1].target = NULL;
    if (check(rn_srv_records_build(sources, 2, test_alloc, test_free,
                &alloc_ctx, &records) != 0,
            "invalid target was accepted")
        || check(alloc_ctx.live == 0,
            "invalid target cleanup leaked an allocation"))
    {
        return 1;
    }
    sources[1].target = second_target;

    memset(&alloc_ctx, 0, sizeof(alloc_ctx));
    memset(&records, 0, sizeof(records));
    if (check(rn_srv_records_build(sources, 2, test_alloc, test_free,
                &alloc_ctx, &records) == 0,
            "valid records failed to build")
        || check(records.count == 2,
            "valid build returned the wrong count")
        || check(strcmp(records.records[0].target, "s-1.localhost") == 0
                && strcmp(records.records[1].target, "s-2.localhost") == 0,
            "valid build returned the wrong targets")
        || check(records.records[1].port == 19081
                && records.records[1].priority == 11
                && records.records[1].weight == 51
                && records.records[1].ttl_ms == 31000,
            "valid build returned the wrong metadata")
        || check(alloc_ctx.live == 4,
            "valid build has the wrong allocation ownership"))
    {
        rn_srv_records_free(&records, test_free, &alloc_ctx);
        return 1;
    }
    rn_srv_records_free(&records, test_free, &alloc_ctx);
    rn_srv_records_free(&records, test_free, &alloc_ctx);
    if (check(alloc_ctx.live == 0,
            "record cleanup leaked or double-freed an allocation"))
    {
        return 1;
    }

    puts("PASS srv record allocation is atomic");
    return 0;
}
