#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <ngx_resolver.h>

#include "r_client.h"
#include "rn_addr_records.h"
#include "rn_async_state.h"
#include "rn_numeric.h"
#include "rn_srv_records.h"

#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define RN_REBIND_RETRY_MS 1000
#define RN_INIT_RETRY_INITIAL_MS 1000
#define RN_INIT_RETRY_MAX_MS 5000
#define RN_UDP_READ_BATCH_MAX 64
#define RN_MAX_BUCKET_LEN 1024
#define RN_MAX_SERVICE_LEN 1024
#define RN_MAX_LABEL_LEN 256

typedef enum {
    RN_POLICY_STANDARD = 0,
    RN_POLICY_SINGLE_ROUND,
    RN_POLICY_CUSTOM,
} rn_policy_kind_t;

typedef struct {
    ngx_str_t name;
    ngx_str_t bucket_template;
    ngx_http_complex_value_t bucket_cv;
    ngx_str_t rate_template;
    ngx_http_complex_value_t rate_cv;
} rn_zone_t;

typedef struct {
    ngx_str_t name;
    ngx_str_t service_template;
    ngx_http_complex_value_t service_cv;
    ngx_str_t threshold_template;
    ngx_http_complex_value_t threshold_cv;
    uint32_t ttl_ms;
    uint32_t max_samples;
    uint32_t buffer_size;
    ngx_flag_t buffer_size_set;
    uint32_t min_sample_threshold;
} rn_guard_t;

typedef struct {
    ngx_str_t name;
    ngx_array_t zones; /* array of ngx_str_t */
} rn_group_t;

typedef struct {
    ngx_array_t *zones;   /* rn_zone_t[] */
    ngx_array_t *guards;  /* rn_guard_t[] */
    ngx_array_t *groups;  /* rn_group_t[] */

    ngx_str_t tenant_dns;
    uint64_t key_id;
    r_auth_type_t auth_type;
    ngx_str_t auth_key;
    uint32_t latency_buffer_size_max;
    uint32_t dedup_ttl_ms_max;

    r_request_policy_t request_policy;
    rn_policy_kind_t request_policy_kind;
    ngx_flag_t request_policy_set;
    ngx_flag_t fail_open;

    ngx_flag_t enabled;
    struct rn_worker_ctx *worker;

    ngx_str_t bind_addr;
    struct sockaddr_storage bind_sockaddr;
    socklen_t bind_socklen;
    ngx_resolver_t *resolver;
    ngx_msec_t resolver_timeout;
    ngx_msec_t init_retry_at;
    ngx_msec_t init_retry_delay;
    ngx_flag_t debug;
    ngx_flag_t debug_set;
#if (RN_TEST_FAULT_INJECTION)
    ngx_str_t test_fault;
#endif
} rn_main_conf_t;

typedef enum {
    RN_RULE_ZONE = 0,
    RN_RULE_GROUP = 1,
} rn_rule_kind_t;

typedef struct {
    rn_rule_kind_t kind;
    ngx_str_t name;
    ngx_array_t guards; /* ngx_str_t[] */
} rn_rule_ref_t;

typedef struct {
    ngx_flag_t enabled;
    ngx_array_t *rules; /* rn_rule_ref_t[] */
    ngx_str_t label_template;
    ngx_http_complex_value_t label_cv;
    ngx_flag_t label_set;
} rn_srv_conf_t;

typedef struct {
    ngx_flag_t enabled;
    ngx_array_t *rules; /* rn_rule_ref_t[] */
    ngx_str_t label_template;
    ngx_http_complex_value_t label_cv;
    ngx_flag_t label_set;
} rn_loc_conf_t;

typedef struct rn_worker_ctx {
    r_client_t *client;
    r_client_config_t client_cfg;
    r_request_policy_t policy;
    r_io_ops_t io_ops;
    r_resolver_ops_t resolver_ops;
    ngx_resolver_t *resolver;
    ngx_msec_t resolver_timeout;
    ngx_socket_t udp_fd;
    int udp_family;
    ngx_connection_t *udp_conn;
    ngx_event_t udp_read;
    ngx_log_t *log;
    ngx_uint_t inflight;
    ngx_flag_t rebind_pending;
    ngx_flag_t rebind_scheduled;
    ngx_event_t rebind_event;
    /* Diagnostic invariant: socket replacement must observe this as false. */
    ngx_flag_t udp_read_active;
    struct sockaddr_storage bind_sockaddr;
    socklen_t bind_socklen;
    ngx_flag_t debug;
#if (RN_TEST_FAULT_INJECTION)
    ngx_str_t test_fault;
#endif
} rn_worker_ctx_t;

/* Admission outcome and completion cause are separate axes.  The pair
 * distinguishes, for example, timeout fail-open from a valid allow. */
typedef enum {
    RN_ADMISSION_NONE = 0,
    RN_ADMISSION_WAITING,
    RN_ADMISSION_VALID_ALLOW,
    RN_ADMISSION_VALID_DENY,
    RN_ADMISSION_FAIL_OPEN,
    RN_ADMISSION_FAIL_CLOSE,
    RN_ADMISSION_INTERNAL_ERROR,
    RN_ADMISSION_ABORTED
} rn_admission_outcome_t;

typedef enum {
    RN_COMPLETION_NONE = 0,
    RN_COMPLETION_VALID_VERDICT,
    RN_COMPLETION_START_FAILURE,
    RN_COMPLETION_DEPENDENCY_ERROR,
    RN_COMPLETION_TIMEOUT,
    RN_COMPLETION_CARDINALITY_MISMATCH,
    RN_COMPLETION_NGINX_ERROR,
    RN_COMPLETION_CLIENT_ABORT
} rn_completion_cause_t;

typedef struct {
    ngx_http_request_t *r;
    rn_worker_ctx_t *worker;
    r_client_req_t *req;
    r_service_latency_report_t *lat_reports;
    size_t lat_report_count;
    size_t expected_guard_count;
    size_t expected_resource_count;
    ngx_event_t timer;
    /* Stack observer used only while r_client_on_timeout may call back. */
    ngx_flag_t *timeout_completed;
    ngx_int_t decision;
    rn_admission_outcome_t admission_outcome;
    rn_completion_cause_t completion_cause;
    ngx_flag_t waiting;
    ngx_flag_t done;
    ngx_flag_t nginx_counted;
    ngx_flag_t inflight_counted;
    ngx_flag_t lat_report_enabled;
    ngx_flag_t lat_report_sent;
} rn_req_ctx_t;

static ngx_int_t ngx_http_rn_add_variables(ngx_conf_t *cf);
static ngx_int_t ngx_http_rn_init(ngx_conf_t *cf);
static void rn_exit_process(ngx_cycle_t *cycle);

static void *ngx_http_rn_create_main_conf(ngx_conf_t *cf);
static void *ngx_http_rn_create_srv_conf(ngx_conf_t *cf);
static void *ngx_http_rn_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_rn_merge_srv_conf(ngx_conf_t *cf, void *parent, void *child);
static char *ngx_http_rn_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child);

static char *ngx_http_rn_set_tenant(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_set_auth_key(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_set_policy(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_set_fail(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_set_bind(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_set_debug(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_guard(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_group(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_rule(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_rn_label(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);

static rn_zone_t *rn_find_zone(rn_main_conf_t *mcf, ngx_str_t *name);
static rn_guard_t *rn_find_guard(rn_main_conf_t *mcf, ngx_str_t *name);
static rn_group_t *rn_find_group(rn_main_conf_t *mcf, ngx_str_t *name);
static ngx_int_t rn_worker_init(rn_main_conf_t *mcf);
static ngx_int_t rn_worker_ensure(rn_main_conf_t *mcf);
static ngx_int_t rn_rebind_socket(rn_worker_ctx_t *worker);
static void rn_worker_cleanup(rn_worker_ctx_t *worker);
static void rn_schedule_rebind(rn_worker_ctx_t *worker);
static void rn_schedule_rebind_after(rn_worker_ctx_t *worker, ngx_msec_t delay);
static void rn_rebind_handler(ngx_event_t *ev);
static void rn_udp_read_handler(ngx_event_t *ev);
static void rn_request_timeout_handler(ngx_event_t *ev);
static void rn_request_teardown(
    rn_req_ctx_t *ctx,
    r_client_req_t *completed_req,
    ngx_flag_t cancel
);
static void rn_request_cleanup(void *data);
static rn_req_ctx_t *rn_get_request_ctx(ngx_http_request_t *r);
#if (RN_TEST_FAULT_INJECTION)
static ngx_flag_t rn_test_fault_active(rn_worker_ctx_t *worker, const char *name);
#endif
static void rn_rate_cb(void *user, r_client_req_t *req, int status, const r_rate_limit_result_t *result);
static ngx_int_t ngx_http_rn_log_handler(ngx_http_request_t *r);
static ngx_int_t ngx_http_rn_verdict_variable(
    ngx_http_request_t *r,
    ngx_http_variable_value_t *v,
    uintptr_t data
);
static void rn_hex16(const uint8_t in[16], u_char out[33]);
static void rn_hex_id(const uint8_t in[16], u_char out[33]);
static const char *rn_rclient_status_name(int status);
static ngx_int_t rn_build_zone_resource(
    ngx_http_request_t *r,
    rn_worker_ctx_t *worker,
    rn_zone_t *zone,
    r_resource_request_t *out
);
static ngx_int_t rn_zone_rate_for_request(
    ngx_http_request_t *r,
    rn_zone_t *zone,
    uint32_t *out_rate,
    uint32_t *out_window_ms
);
static ngx_int_t rn_parse_protocol_duration_ms(
    ngx_str_t *value,
    uint32_t *out_ms
);
static ngx_int_t rn_parse_policy_schedule(
    ngx_str_t *value,
    r_ha_schedule_t *out_schedule
);
static ngx_int_t rn_policy_horizon_ms(
    const r_request_policy_t *policy,
    uint32_t max_ttl_ms,
    uint32_t *out_horizon_ms
);
static const char *rn_policy_kind_name(rn_policy_kind_t kind);
static ngx_flag_t rn_has_literal_value_quotes(ngx_str_t *value);
static ngx_int_t rn_build_guard_entries(
    ngx_http_request_t *r,
    rn_worker_ctx_t *worker,
    rn_main_conf_t *mcf,
    rn_guard_t *guard,
    r_latency_guard_t *out_guard,
    r_service_latency_report_t *out_report
);

static ngx_command_t ngx_http_rn_commands[] = {
    { ngx_string("ratelimitly_tenant"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_set_tenant,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_auth_key"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_set_auth_key,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_policy"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_1MORE,
      ngx_http_rn_set_policy,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_fail"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_set_fail,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_bind"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_set_bind,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_debug"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_set_debug,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

#if (RN_TEST_FAULT_INJECTION)
    { ngx_string("ratelimitly_test_fault"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_conf_set_str_slot,
      NGX_HTTP_MAIN_CONF_OFFSET,
      offsetof(rn_main_conf_t, test_fault),
      NULL },
#endif

    { ngx_string("ratelimitly_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE3,
      ngx_http_rn_zone,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_guard"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_1MORE,
      ngx_http_rn_guard,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_group"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_2MORE,
      ngx_http_rn_group,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly_label"),
      NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_rn_label,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("ratelimitly"),
      NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_1MORE,
      ngx_http_rn_rule,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    ngx_null_command
};

static ngx_http_variable_t ngx_http_rn_variables[] = {
    { ngx_string("ratelimitly_verdict"), NULL,
      ngx_http_rn_verdict_variable, 0, NGX_HTTP_VAR_NOCACHEABLE, 0 },

    ngx_http_null_variable
};

static ngx_http_module_t ngx_http_rn_module_ctx = {
    ngx_http_rn_add_variables, /* preconfiguration */
    ngx_http_rn_init,     /* postconfiguration */

    ngx_http_rn_create_main_conf, /* create main configuration */
    NULL,                          /* init main configuration */

    ngx_http_rn_create_srv_conf,  /* create server configuration */
    ngx_http_rn_merge_srv_conf,   /* merge server configuration */

    ngx_http_rn_create_loc_conf,  /* create location configuration */
    ngx_http_rn_merge_loc_conf    /* merge location configuration */
};

ngx_module_t ngx_http_rn_module = {
    NGX_MODULE_V1,
    &ngx_http_rn_module_ctx,
    ngx_http_rn_commands,
    NGX_HTTP_MODULE,
    NULL,                 /* init master */
    NULL,                 /* init module */
    NULL,                 /* init process */
    NULL,                 /* init thread */
    NULL,                 /* exit thread */
    rn_exit_process,      /* exit process */
    NULL,                 /* exit master */
    NGX_MODULE_V1_PADDING
};

static ngx_int_t
ngx_http_rn_add_variables(ngx_conf_t *cf) {
    ngx_http_variable_t *var;
    ngx_http_variable_t *v;

    for (v = ngx_http_rn_variables; v->name.len; v++) {
        var = ngx_http_add_variable(cf, &v->name, v->flags);
        if (var == NULL) {
            return NGX_ERROR;
        }
        var->get_handler = v->get_handler;
        var->data = v->data;
    }

    return NGX_OK;
}

static rn_req_ctx_t *
rn_get_request_ctx(ngx_http_request_t *r) {
    ngx_http_cleanup_t *cln;
    rn_req_ctx_t *ctx;

    if (r == NULL) {
        return NULL;
    }

    ctx = ngx_http_get_module_ctx(r, ngx_http_rn_module);
    if (ctx != NULL) {
        return ctx;
    }

    /*
     * ngx_http_internal_redirect() clears every module context but preserves
     * the main request pool and its cleanup list.  Recover the admission
     * context from that request-lifetime owner so internal routing cannot
     * issue a second RateLimitly request for the same external HTTP request.
     */
    for (cln = r->cleanup; cln != NULL; cln = cln->next) {
        if (cln->handler != rn_request_cleanup) {
            continue;
        }
        ctx = cln->data;
        if (ctx != NULL && ctx->r == r) {
            ngx_http_set_ctx(r, ctx, ngx_http_rn_module);
            return ctx;
        }
    }

    return NULL;
}

static ngx_int_t
ngx_http_rn_verdict_variable(
    ngx_http_request_t *r,
    ngx_http_variable_value_t *v,
    uintptr_t data
) {
    static ngx_str_t allow = ngx_string("allow");
    static ngx_str_t deny = ngx_string("deny");
    ngx_str_t *value;
    rn_req_ctx_t *ctx;

    (void) data;

    ctx = rn_get_request_ctx(r);
    if (ctx == NULL) {
        v->not_found = 1;
        return NGX_OK;
    }

    if (ctx->admission_outcome == RN_ADMISSION_VALID_ALLOW) {
        value = &allow;
    } else if (ctx->admission_outcome == RN_ADMISSION_VALID_DENY) {
        value = &deny;
    } else {
        v->not_found = 1;
        return NGX_OK;
    }

    v->valid = 1;
    v->no_cacheable = 0;
    v->not_found = 0;
    v->len = value->len;
    v->data = value->data;

    return NGX_OK;
}

static ngx_int_t
ngx_http_rn_handler(ngx_http_request_t *r) {
    rn_loc_conf_t *lcf;
    rn_main_conf_t *mcf;
    rn_worker_ctx_t *worker;
    rn_req_ctx_t *ctx;
    r_client_req_t *req = NULL;
    r_resource_request_t *resources;
    r_latency_guard_t *guards = NULL;
    r_service_latency_report_t *lat_reports = NULL;
    rn_guard_t **guard_defs = NULL;
    ngx_uint_t total = 0;
    ngx_uint_t total_guard_refs = 0;
    ngx_uint_t guard_idx = 0;
    ngx_uint_t idx = 0;
    ngx_uint_t i, j, k;
    rn_rule_ref_t *rules;
    ngx_str_t label = ngx_null_string;
    const char *label_ptr = NULL;
    size_t label_len = 0;
    ngx_http_cleanup_t *cln;

    /*
     * The access-phase checker skips subrequests before calling access
     * handlers.  Preserve that contract now that admission runs in the
     * generic pre-content phase.
     */
    if (r != r->main) {
        return NGX_DECLINED;
    }

    ctx = rn_get_request_ctx(r);
    lcf = ngx_http_get_module_loc_conf(r, ngx_http_rn_module);
    mcf = ngx_http_get_module_main_conf(r, ngx_http_rn_module);
    if (lcf == NULL || !lcf->enabled) {
        if (mcf && mcf->debug) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                "rn: bypass uri=%V reason=loc_disabled", &r->uri);
        }
        return NGX_DECLINED;
    }
    if (mcf == NULL || !mcf->enabled) {
        if (mcf && mcf->debug) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                "rn: bypass uri=%V reason=main_disabled", &r->uri);
        }
        return NGX_DECLINED;
    }
    if (ctx != NULL) {
        if (ctx->done) {
            return ctx->decision;
        }
        if (ctx->waiting) {
            return NGX_AGAIN;
        }
    }
    if (mcf->worker == NULL && rn_worker_ensure(mcf) != NGX_OK) {
        return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
    }
    worker = mcf->worker;
    if (worker == NULL || worker->client == NULL) {
        if (mcf->debug) {
            ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                "rn: bypass uri=%V reason=no_client fail_open=%d",
                &r->uri, (int) mcf->fail_open);
        }
        return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
    }

    if (lcf->rules == NULL || lcf->rules->nelts == 0) {
        if (mcf->debug) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                "rn: bypass uri=%V reason=no_rules", &r->uri);
        }
        return NGX_DECLINED;
    }
    rules = lcf->rules->elts;
    for (i = 0; i < lcf->rules->nelts; i++) {
        total_guard_refs += rules[i].guards.nelts;
        if (rules[i].kind == RN_RULE_ZONE) {
            total++;
        } else {
            rn_group_t *group = rn_find_group(mcf, &rules[i].name);
            if (group == NULL) {
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            total += group->zones.nelts;
        }
    }
    if (total == 0) {
        if (mcf->debug) {
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                "rn: bypass uri=%V reason=empty_rule_expansion", &r->uri);
        }
        return NGX_DECLINED;
    }

    resources = ngx_pcalloc(r->pool, total * sizeof(r_resource_request_t));
    if (resources == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    if (total_guard_refs > 0) {
        guards = ngx_pcalloc(r->pool, total_guard_refs * sizeof(r_latency_guard_t));
        lat_reports = ngx_pcalloc(r->pool, total_guard_refs * sizeof(r_service_latency_report_t));
        guard_defs = ngx_pcalloc(r->pool, total_guard_refs * sizeof(rn_guard_t *));
        if (guards == NULL || lat_reports == NULL || guard_defs == NULL) {
            return NGX_HTTP_INTERNAL_SERVER_ERROR;
        }
    }

    for (i = 0; i < lcf->rules->nelts; i++) {
        ngx_str_t *guard_names = rules[i].guards.elts;
        for (k = 0; k < rules[i].guards.nelts; k++) {
            rn_guard_t *guard = rn_find_guard(mcf, &guard_names[k]);
            ngx_flag_t already_added = 0;
            ngx_uint_t g;

            if (guard == NULL) {
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            for (g = 0; g < guard_idx; g++) {
                if (guard_defs[g] == guard) {
                    already_added = 1;
                    break;
                }
            }
            if (already_added) {
                continue;
            }

            ngx_int_t guard_rc = rn_build_guard_entries(
                r, worker, mcf, guard, &guards[guard_idx], &lat_reports[guard_idx]);
            if (guard_rc == NGX_HTTP_INTERNAL_SERVER_ERROR) {
                if (mcf->debug) {
                    ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                        "rn: guard_build_failed guard=%V rc=internal_error",
                        &guard->name);
                }
                return NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
            if (guard_rc != NGX_OK) {
                if (mcf->debug) {
                    ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                        "rn: guard_build_failed guard=%V rc=%i fail_open=%d",
                        &guard->name, guard_rc, mcf->fail_open);
                }
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            guard_defs[guard_idx] = guard;
            guard_idx++;
        }

        if (rules[i].kind == RN_RULE_ZONE) {
            rn_zone_t *zone = rn_find_zone(mcf, &rules[i].name);
            ngx_int_t build_rc;
            if (zone == NULL) {
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            build_rc = rn_build_zone_resource(r, worker, zone, &resources[idx]);
            if (build_rc == NGX_HTTP_INTERNAL_SERVER_ERROR) {
                if (mcf->debug) {
                    ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                        "rn: zone_build_failed zone=%V rc=internal_error",
                        &zone->name);
                }
                return NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
            if (build_rc != NGX_OK) {
                if (mcf->debug) {
                    ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                        "rn: zone_build_failed zone=%V rc=%i fail_open=%d",
                        &zone->name, build_rc, mcf->fail_open);
                }
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            idx++;
        } else {
            rn_group_t *group = rn_find_group(mcf, &rules[i].name);
            ngx_str_t *zones;
            if (group == NULL) {
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            zones = group->zones.elts;
            for (j = 0; j < group->zones.nelts; j++) {
                rn_zone_t *zone = rn_find_zone(mcf, &zones[j]);
                ngx_int_t build_rc;
                if (zone == NULL) {
                    return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
                }
                build_rc = rn_build_zone_resource(r, worker, zone, &resources[idx]);
                if (build_rc == NGX_HTTP_INTERNAL_SERVER_ERROR) {
                    if (mcf->debug) {
                        ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                            "rn: zone_build_failed group=%V zone=%V rc=internal_error",
                            &group->name, &zone->name);
                    }
                    return NGX_HTTP_INTERNAL_SERVER_ERROR;
                }
                if (build_rc != NGX_OK) {
                    if (mcf->debug) {
                        ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                            "rn: zone_build_failed group=%V zone=%V rc=%i fail_open=%d",
                            &group->name, &zone->name, build_rc, mcf->fail_open);
                    }
                    return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
                }
                idx++;
            }
        }
    }

    if (lcf->label_set) {
        if (ngx_http_complex_value(r, &lcf->label_cv, &label) != NGX_OK) {
            if (mcf->debug) {
                ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                    "rn: label_build_failed uri=%V fail_open=%d", &r->uri, mcf->fail_open);
            }
            return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
        }
        if (label.len > 0) {
            if (label.len > RN_MAX_LABEL_LEN) {
                if (mcf->debug) {
                    ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                        "rn: label_build_failed uri=%V reason=too_long len=%uz max=%d fail_open=%d",
                        &r->uri, label.len, RN_MAX_LABEL_LEN, mcf->fail_open);
                }
                return mcf->fail_open ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
            }
            label_ptr = (const char *) label.data;
            label_len = label.len;
        }
    }

    ctx = ngx_pcalloc(r->pool, sizeof(rn_req_ctx_t));
    if (ctx == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ctx->r = r;
    ctx->worker = worker;
    ctx->timer.handler = rn_request_timeout_handler;
    ctx->timer.data = ctx;
    ctx->timer.log = worker->log;
    ctx->lat_reports = lat_reports;
    ctx->lat_report_count = guard_idx;
    ctx->expected_guard_count = guard_idx;
    ctx->expected_resource_count = idx;
    ctx->waiting = 0;
    ctx->done = 0;
    ctx->decision = NGX_DECLINED;
    ctx->admission_outcome = RN_ADMISSION_NONE;
    ctx->completion_cause = RN_COMPLETION_NONE;
    ctx->nginx_counted = 0;
    ctx->inflight_counted = 0;
    ctx->lat_report_enabled = (guard_idx > 0);
    ctx->lat_report_sent = 0;
    ngx_http_set_ctx(r, ctx, ngx_http_rn_module);

    cln = ngx_http_cleanup_add(r, 0);
    if (cln == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    cln->handler = rn_request_cleanup;
    cln->data = ctx;

    int async_rc = r_client_check_rate_limit_async_borrowed(
        worker->client,
        resources,
        idx,
        guards,
        guard_idx,
        label_ptr,
        label_len,
        rn_rate_cb,
        r,
        &req
    );
    if (async_rc != RCLIENT_OK) {
        if (mcf->debug) {
            ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                "rn: async_start_failed uri=%V rc=%d(%s) resources=%uz guards=%uz label_len=%uz fail_open=%d",
                &r->uri, async_rc, rn_rclient_status_name(async_rc),
                idx, guard_idx, label_len, mcf->fail_open);
        }
        ctx->decision = mcf->fail_open
            ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
        ctx->admission_outcome = mcf->fail_open
            ? RN_ADMISSION_FAIL_OPEN : RN_ADMISSION_FAIL_CLOSE;
        ctx->completion_cause = RN_COMPLETION_START_FAILURE;
        ctx->done = 1;
        return ctx->decision;
    }

    ctx->req = req;
    worker->inflight++;
    ctx->inflight_counted = 1;

    uint64_t deadline_ms = 0;
    if (r_client_request_deadline_ms(req, &deadline_ms) == RCLIENT_OK) {
        uint64_t now_ms = worker->io_ops.now_ms(worker);
        ngx_msec_t delay = 0;
        if (deadline_ms > now_ms) {
            delay = (ngx_msec_t)(deadline_ms - now_ms);
        }
        ngx_add_timer(&ctx->timer, delay);
    }

    ctx->waiting = 1;
    ctx->admission_outcome = RN_ADMISSION_WAITING;
    r->main->count++;
    ctx->nginx_counted = 1;

    if (r->connection->read->ready) {
        ngx_post_event(r->connection->read, &ngx_posted_events);
    } else if (ngx_handle_read_event(r->connection->read, 0) != NGX_OK) {
        rn_request_teardown(ctx, NULL, 1);
        ctx->decision = NGX_HTTP_INTERNAL_SERVER_ERROR;
        ctx->admission_outcome = RN_ADMISSION_INTERNAL_ERROR;
        ctx->completion_cause = RN_COMPLETION_NGINX_ERROR;
        ctx->done = 1;
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    r->read_event_handler = ngx_http_test_reading;

#if (RN_TEST_FAULT_INJECTION)
    /*
     * Remove the incidental client-read wakeup which would otherwise hide a
     * missing posted-request drain after the asynchronous verdict callback.
     */
    if (rn_test_fault_active(worker, "posted-request-drain")
        && r->connection->read->posted)
    {
        ngx_delete_posted_event(r->connection->read);
    }
#endif

    return NGX_AGAIN;
}

static ngx_int_t
ngx_http_rn_init(ngx_conf_t *cf) {
    ngx_http_handler_pt *h;
    ngx_array_t *handlers;
    ngx_http_core_main_conf_t *cmcf;
    ngx_http_core_loc_conf_t *clcf;
    rn_main_conf_t *mcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);
    if (cmcf == NULL) {
        return NGX_ERROR;
    }

    handlers = &cmcf->phases[NGX_HTTP_PRECONTENT_PHASE].handlers;
    h = ngx_array_push(handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }
    /*
     * nginx executes a phase's handler array in reverse.  Keep RateLimitly at
     * index zero so access-approved routing/preparation handlers run first and
     * a RateLimitly allow is the final transition into content processing.
     */
    h = handlers->elts;
    if (handlers->nelts > 1) {
        ngx_memmove(&h[1], &h[0],
            (handlers->nelts - 1) * sizeof(ngx_http_handler_pt));
    }
    h[0] = ngx_http_rn_handler;

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_LOG_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }
    *h = ngx_http_rn_log_handler;

    mcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_rn_module);
    if (mcf && mcf->enabled) {
        uint32_t policy_horizon_ms;
        uint32_t max_ttl_ms;

        if (mcf->tenant_dns.len == 0) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0, "ratelimitly_tenant is required");
            return NGX_ERROR;
        }
        if (mcf->auth_key.len == 0) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0, "ratelimitly_auth_key is required");
            return NGX_ERROR;
        }
        max_ttl_ms = mcf->dedup_ttl_ms_max == 0
            ? UINT32_MAX : mcf->dedup_ttl_ms_max;
        if (rn_policy_horizon_ms(&mcf->request_policy, max_ttl_ms,
                &policy_horizon_ms) != NGX_OK)
        {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                "ratelimitly_policy horizon is invalid or exceeds the "
                "API-key dedup_ttl_ms_max of %uDms", max_ttl_ms);
            return NGX_ERROR;
        }
        clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
        if (clcf == NULL || clcf->resolver == NULL
            || clcf->resolver->connections.nelts == 0)
        {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                "ratelimitly requires resolver in the http context");
            return NGX_ERROR;
        }
        mcf->resolver = clcf->resolver;
        mcf->resolver_timeout = clcf->resolver_timeout;
    }

    return NGX_OK;
}

static void *
ngx_http_rn_create_main_conf(ngx_conf_t *cf) {
    rn_main_conf_t *mcf;

    mcf = ngx_pcalloc(cf->pool, sizeof(rn_main_conf_t));
    if (mcf == NULL) {
        return NULL;
    }

    mcf->zones = NULL;
    mcf->guards = NULL;
    mcf->groups = NULL;
    mcf->tenant_dns.len = 0;
    mcf->tenant_dns.data = NULL;
    mcf->key_id = 0;
    mcf->auth_type = (r_auth_type_t) 0;
    mcf->auth_key.len = 0;
    mcf->auth_key.data = NULL;
    mcf->dedup_ttl_ms_max = 0;
    r_client_default_request_policy(&mcf->request_policy);
    mcf->request_policy_kind = RN_POLICY_STANDARD;
    mcf->request_policy_set = 0;
    mcf->fail_open = 1;
    mcf->enabled = 0;
    mcf->worker = NULL;
    mcf->bind_addr.len = 0;
    mcf->bind_addr.data = NULL;
    mcf->bind_socklen = 0;
    mcf->resolver = NULL;
    mcf->resolver_timeout = 0;
    mcf->init_retry_at = 0;
    mcf->init_retry_delay = 0;
    mcf->debug = 0;
    mcf->debug_set = 0;

    return mcf;
}

static void *
ngx_http_rn_create_srv_conf(ngx_conf_t *cf) {
    rn_srv_conf_t *scf;

    scf = ngx_pcalloc(cf->pool, sizeof(rn_srv_conf_t));
    if (scf == NULL) {
        return NULL;
    }

    scf->enabled = NGX_CONF_UNSET;
    scf->rules = NULL;
    scf->label_template.len = 0;
    scf->label_template.data = NULL;
    scf->label_set = 0;

    return scf;
}

static void *
ngx_http_rn_create_loc_conf(ngx_conf_t *cf) {
    rn_loc_conf_t *lcf;

    lcf = ngx_pcalloc(cf->pool, sizeof(rn_loc_conf_t));
    if (lcf == NULL) {
        return NULL;
    }

    lcf->enabled = NGX_CONF_UNSET;
    lcf->rules = NULL;
    lcf->label_template.len = 0;
    lcf->label_template.data = NULL;
    lcf->label_set = 0;

    return lcf;
}

static char *
ngx_http_rn_merge_srv_conf(ngx_conf_t *cf, void *parent, void *child) {
    rn_srv_conf_t *prev = parent;
    rn_srv_conf_t *conf = child;

    ngx_conf_merge_value(conf->enabled, prev->enabled, 0);
    if (conf->rules == NULL) {
        conf->rules = prev->rules;
    }
    if (!conf->label_set && prev->label_set) {
        conf->label_template = prev->label_template;
        conf->label_cv = prev->label_cv;
        conf->label_set = prev->label_set;
    }
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child) {
    rn_loc_conf_t *prev = parent;
    rn_loc_conf_t *conf = child;

    ngx_conf_merge_value(conf->enabled, prev->enabled, 0);
    if (conf->rules == NULL) {
        conf->rules = prev->rules;
    }
    if (!conf->label_set && prev->label_set) {
        conf->label_template = prev->label_template;
        conf->label_cv = prev->label_cv;
        conf->label_set = prev->label_set;
    }
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_set_tenant(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;

    if (mcf->tenant_dns.data != NULL) {
        return "is duplicate";
    }
    mcf->tenant_dns = value[1];
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_set_auth_key(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    if (mcf->auth_key.data != NULL) {
        return "is duplicate";
    }

    if (value[1].len == 0) {
        return "ratelimitly_auth_key requires a bech32 key";
    }

    char *key = (char *)ngx_pnalloc(cf->pool, value[1].len + 1);
    if (key == NULL) {
        return NGX_CONF_ERROR;
    }
    ngx_memcpy(key, value[1].data, value[1].len);
    key[value[1].len] = '\0';

    r_auth_key_info_t info;
    if (r_client_parse_auth_key(key, &info) != RCLIENT_OK) {
        return "invalid ratelimitly_auth_key bech32 value";
    }

    mcf->auth_key = value[1];
    mcf->auth_type = info.type;
    mcf->key_id = info.key_id;
    mcf->latency_buffer_size_max = info.latency_buffer_size_max;
    mcf->dedup_ttl_ms_max = info.dedup_ttl_ms_max;
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_set_policy(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    r_request_policy_t policy;
    rn_policy_kind_t kind;
    ngx_uint_t i;
    ngx_flag_t unit_set = 0;
    ngx_flag_t replays_set = 0;
    ngx_flag_t replay_gap_set = 0;
    ngx_flag_t final_wait_set = 0;
    ngx_flag_t completion_delivery_set = 0;

    if (mcf->request_policy_set) {
        return "is duplicate";
    }

    r_client_default_request_policy(&policy);
    if (value[1].len == sizeof("standard") - 1
        && ngx_strncmp(value[1].data, "standard", value[1].len) == 0)
    {
        kind = RN_POLICY_STANDARD;
    } else if (value[1].len == sizeof("single_round") - 1
        && ngx_strncmp(value[1].data, "single_round", value[1].len) == 0)
    {
        kind = RN_POLICY_SINGLE_ROUND;
        policy.replay_count = 0;
        policy.final_receive_units = 0;
        policy.completion_delivery = false;
    } else if (value[1].len == sizeof("custom") - 1
        && ngx_strncmp(value[1].data, "custom", value[1].len) == 0)
    {
        kind = RN_POLICY_CUSTOM;
        ngx_memzero(&policy, sizeof(policy));
    } else {
        return "invalid ratelimitly_policy name";
    }

    for (i = 2; i < cf->args->nelts; i++) {
        ngx_str_t arg_value;
        uint32_t number;

        if (value[i].len >= sizeof("unit=") - 1
            && ngx_strncmp(value[i].data, "unit=", sizeof("unit=") - 1) == 0)
        {
            if (unit_set) {
                return "duplicate ratelimitly_policy unit=";
            }
            arg_value.data = value[i].data + sizeof("unit=") - 1;
            arg_value.len = value[i].len - (sizeof("unit=") - 1);
            if (rn_parse_protocol_duration_ms(&arg_value, &number) != NGX_OK) {
                return "invalid ratelimitly_policy unit";
            }
            policy.unit_ms = number;
            unit_set = 1;
            continue;
        }

        if (kind != RN_POLICY_CUSTOM) {
            return kind == RN_POLICY_STANDARD
                ? "ratelimitly_policy standard accepts only unit="
                : "ratelimitly_policy single_round accepts only unit=";
        }

        if (value[i].len >= sizeof("replays=") - 1
            && ngx_strncmp(value[i].data, "replays=", sizeof("replays=") - 1) == 0)
        {
            if (replays_set) {
                return "duplicate ratelimitly_policy replays=";
            }
            arg_value.data = value[i].data + sizeof("replays=") - 1;
            arg_value.len = value[i].len - (sizeof("replays=") - 1);
            if (rn_numeric_parse_u32(arg_value.data, arg_value.len, &number) != 0
                || number > R_CLIENT_HA_MAX_REPLAY_COUNT)
            {
                return "invalid ratelimitly_policy replays";
            }
            policy.replay_count = number;
            replays_set = 1;
        } else if (value[i].len >= sizeof("replay_gap=") - 1
            && ngx_strncmp(value[i].data, "replay_gap=",
                sizeof("replay_gap=") - 1) == 0)
        {
            if (replay_gap_set) {
                return "duplicate ratelimitly_policy replay_gap=";
            }
            arg_value.data = value[i].data + sizeof("replay_gap=") - 1;
            arg_value.len = value[i].len - (sizeof("replay_gap=") - 1);
            if (rn_parse_policy_schedule(&arg_value, &policy.replay_gap)
                    != NGX_OK
                || policy.replay_gap.initial_units == 0)
            {
                return "invalid ratelimitly_policy replay_gap";
            }
            replay_gap_set = 1;
        } else if (value[i].len >= sizeof("final_wait_units=") - 1
            && ngx_strncmp(value[i].data, "final_wait_units=",
                sizeof("final_wait_units=") - 1) == 0)
        {
            if (final_wait_set) {
                return "duplicate ratelimitly_policy final_wait_units=";
            }
            arg_value.data = value[i].data + sizeof("final_wait_units=") - 1;
            arg_value.len = value[i].len
                - (sizeof("final_wait_units=") - 1);
            if (rn_numeric_parse_u32(arg_value.data, arg_value.len, &number)
                != 0)
            {
                return "invalid ratelimitly_policy final_wait_units";
            }
            policy.final_receive_units = number;
            final_wait_set = 1;
        } else if (value[i].len >= sizeof("completion_delivery=") - 1
            && ngx_strncmp(value[i].data, "completion_delivery=",
                sizeof("completion_delivery=") - 1) == 0)
        {
            if (completion_delivery_set) {
                return "duplicate ratelimitly_policy completion_delivery=";
            }
            arg_value.data = value[i].data
                + sizeof("completion_delivery=") - 1;
            arg_value.len = value[i].len
                - (sizeof("completion_delivery=") - 1);
            if (arg_value.len == 2
                && ngx_strncmp(arg_value.data, "on", 2) == 0)
            {
                policy.completion_delivery = true;
            } else if (arg_value.len == 3
                && ngx_strncmp(arg_value.data, "off", 3) == 0)
            {
                policy.completion_delivery = false;
            } else {
                return "invalid ratelimitly_policy completion_delivery";
            }
            completion_delivery_set = 1;
        } else {
            return "invalid ratelimitly_policy custom argument";
        }
    }

    if (kind == RN_POLICY_CUSTOM
        && (!unit_set || !replays_set || !replay_gap_set
            || !final_wait_set || !completion_delivery_set))
    {
        return "ratelimitly_policy custom requires unit=, replays=, replay_gap=, final_wait_units=, and completion_delivery=";
    }

    uint32_t horizon_ms = 0;
    if (rn_policy_horizon_ms(&policy, UINT32_MAX, &horizon_ms) != NGX_OK)
    {
        return "ratelimitly_policy horizon exceeds the wire limit";
    }

    mcf->request_policy = policy;
    mcf->request_policy_kind = kind;
    mcf->request_policy_set = 1;
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_set_fail(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;

    if (value[1].len == 4 && ngx_strncmp(value[1].data, "open", 4) == 0) {
        mcf->fail_open = 1;
        return NGX_CONF_OK;
    }
    if (value[1].len == 5 && ngx_strncmp(value[1].data, "close", 5) == 0) {
        mcf->fail_open = 0;
        return NGX_CONF_OK;
    }

    return "invalid ratelimitly_fail value";
}

static char *
ngx_http_rn_set_bind(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    ngx_addr_t addr;

    if (mcf->bind_addr.data != NULL) {
        return "is duplicate";
    }
    ngx_memzero(&addr, sizeof(addr));
    if (ngx_parse_addr(cf->pool, &addr, value[1].data, value[1].len) != NGX_OK
        || (addr.sockaddr->sa_family != AF_INET
            && addr.sockaddr->sa_family != AF_INET6)
        || addr.socklen > sizeof(mcf->bind_sockaddr))
    {
        return "invalid ratelimitly_bind address";
    }
    mcf->bind_addr = value[1];
    ngx_memcpy(&mcf->bind_sockaddr, addr.sockaddr, addr.socklen);
    mcf->bind_socklen = addr.socklen;
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_set_debug(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;

    if (mcf->debug_set) {
        return "is duplicate";
    }
    if (value[1].len == 2 && ngx_strncmp(value[1].data, "on", 2) == 0) {
        mcf->debug = 1;
        mcf->debug_set = 1;
        return NGX_CONF_OK;
    }
    if (value[1].len == 3 && ngx_strncmp(value[1].data, "off", 3) == 0) {
        mcf->debug = 0;
        mcf->debug_set = 1;
        return NGX_CONF_OK;
    }
    return "invalid ratelimitly_debug value";
}

static ngx_int_t
rn_parse_protocol_duration_ms(ngx_str_t *value, uint32_t *out_ms) {
    ngx_msec_t ms;

    if (value == NULL || out_ms == NULL || value->len == 0) {
        return NGX_ERROR;
    }

    ms = ngx_parse_time(value, 0);
    if (ms == 0 || ms == (ngx_msec_t) NGX_ERROR
        || rn_numeric_u32_from_u64((uint64_t) ms, out_ms) != 0)
    {
        return NGX_ERROR;
    }

    return NGX_OK;
}

static ngx_int_t
rn_parse_schedule_number(
    u_char **cursor,
    u_char *end,
    ngx_flag_t require_separator,
    uint32_t *out
) {
    u_char *separator;
    ngx_str_t number;

    if (cursor == NULL || *cursor == NULL || *cursor >= end || out == NULL) {
        return NGX_ERROR;
    }

    separator = ngx_strlchr(*cursor, end, ':');
    if (require_separator) {
        if (separator == NULL) {
            return NGX_ERROR;
        }
        number.data = *cursor;
        number.len = (size_t) (separator - *cursor);
        *cursor = separator + 1;
    } else {
        if (separator != NULL) {
            return NGX_ERROR;
        }
        number.data = *cursor;
        number.len = (size_t) (end - *cursor);
        *cursor = end;
    }

    if (number.len == 0
        || rn_numeric_parse_u32(number.data, number.len, out) != 0)
    {
        return NGX_ERROR;
    }
    return NGX_OK;
}

static ngx_int_t
rn_parse_policy_schedule(ngx_str_t *value, r_ha_schedule_t *out_schedule) {
    u_char *cursor;
    u_char *end;
    uint32_t initial;
    uint32_t growth;
    uint32_t maximum;

    if (value == NULL || out_schedule == NULL || value->len == 0) {
        return NGX_ERROR;
    }
    cursor = value->data;
    end = value->data + value->len;
    ngx_memzero(out_schedule, sizeof(*out_schedule));

    if (value->len > sizeof("fixed:") - 1
        && ngx_strncmp(cursor, "fixed:", sizeof("fixed:") - 1) == 0)
    {
        cursor += sizeof("fixed:") - 1;
        if (rn_parse_schedule_number(&cursor, end, 0, &initial) != NGX_OK) {
            return NGX_ERROR;
        }
        out_schedule->kind = R_HA_SCHEDULE_FIXED;
        out_schedule->initial_units = initial;
        out_schedule->max_units = initial;
        return NGX_OK;
    }

    if (value->len > sizeof("linear:") - 1
        && ngx_strncmp(cursor, "linear:", sizeof("linear:") - 1) == 0)
    {
        cursor += sizeof("linear:") - 1;
        if (rn_parse_schedule_number(&cursor, end, 1, &initial) != NGX_OK
            || rn_parse_schedule_number(&cursor, end, 1, &growth) != NGX_OK
            || rn_parse_schedule_number(&cursor, end, 0, &maximum) != NGX_OK
            || growth == 0 || initial > maximum)
        {
            return NGX_ERROR;
        }
        out_schedule->kind = R_HA_SCHEDULE_LINEAR;
        out_schedule->initial_units = initial;
        out_schedule->max_units = maximum;
        out_schedule->growth.linear_step_units = growth;
        return NGX_OK;
    }

    if (value->len > sizeof("exponential:") - 1
        && ngx_strncmp(cursor, "exponential:",
            sizeof("exponential:") - 1) == 0)
    {
        cursor += sizeof("exponential:") - 1;
        if (rn_parse_schedule_number(&cursor, end, 1, &initial) != NGX_OK
            || rn_parse_schedule_number(&cursor, end, 1, &growth) != NGX_OK
            || rn_parse_schedule_number(&cursor, end, 0, &maximum) != NGX_OK
            || growth < 2 || initial > maximum)
        {
            return NGX_ERROR;
        }
        out_schedule->kind = R_HA_SCHEDULE_EXPONENTIAL;
        out_schedule->initial_units = initial;
        out_schedule->max_units = maximum;
        out_schedule->growth.exponential_factor = growth;
        return NGX_OK;
    }

    return NGX_ERROR;
}

static ngx_int_t
rn_policy_schedule_units(
    const r_ha_schedule_t *schedule,
    uint32_t round,
    uint32_t *out_units
) {
    uint32_t value;

    if (schedule == NULL || out_units == NULL
        || schedule->initial_units > schedule->max_units)
    {
        return NGX_ERROR;
    }

    value = schedule->initial_units;
    switch (schedule->kind) {
    case R_HA_SCHEDULE_FIXED:
        break;
    case R_HA_SCHEDULE_LINEAR:
        if (schedule->growth.linear_step_units == 0) {
            return NGX_ERROR;
        }
        if (round > (schedule->max_units - value)
            / schedule->growth.linear_step_units)
        {
            value = schedule->max_units;
        } else {
            value += round * schedule->growth.linear_step_units;
        }
        break;
    case R_HA_SCHEDULE_EXPONENTIAL:
        if (schedule->growth.exponential_factor < 2) {
            return NGX_ERROR;
        }
        while (round-- > 0 && value < schedule->max_units) {
            if (value > schedule->max_units
                / schedule->growth.exponential_factor)
            {
                value = schedule->max_units;
            } else {
                value *= schedule->growth.exponential_factor;
            }
        }
        break;
    default:
        return NGX_ERROR;
    }

    *out_units = value;
    return NGX_OK;
}

static ngx_int_t
rn_policy_horizon_ms(
    const r_request_policy_t *policy,
    uint32_t max_ttl_ms,
    uint32_t *out_horizon_ms
) {
    uint64_t total_units = 0;
    uint64_t max_units;
    uint32_t round;

    if (policy == NULL || out_horizon_ms == NULL || policy->unit_ms == 0
        || policy->unit_ms > max_ttl_ms
        || policy->replay_count > R_CLIENT_HA_MAX_REPLAY_COUNT
        || policy->replay_gap.initial_units == 0)
    {
        return NGX_ERROR;
    }

    max_units = max_ttl_ms / policy->unit_ms;
    for (round = 0; round <= policy->replay_count; round++) {
        uint32_t gap_units;

        if (rn_policy_schedule_units(&policy->replay_gap, round, &gap_units)
                != NGX_OK)
        {
            return NGX_ERROR;
        }
        if (gap_units > max_units - total_units) {
            return NGX_ERROR;
        }
        total_units += gap_units;
    }

    if (policy->final_receive_units > max_units - total_units) {
        return NGX_ERROR;
    }
    total_units += policy->final_receive_units;
    if (total_units == 0) {
        return NGX_ERROR;
    }

    *out_horizon_ms = (uint32_t) (total_units * policy->unit_ms);
    return NGX_OK;
}

static const char *
rn_policy_kind_name(rn_policy_kind_t kind) {
    switch (kind) {
    case RN_POLICY_STANDARD:
        return "standard";
    case RN_POLICY_SINGLE_ROUND:
        return "single_round";
    case RN_POLICY_CUSTOM:
        return "custom";
    default:
        return "unknown";
    }
}

static ngx_flag_t
rn_has_literal_value_quotes(ngx_str_t *value) {
    u_char first;

    if (value == NULL || value->len < 2) {
        return 0;
    }
    first = value->data[0];
    return (first == '"' || first == '\'')
        && value->data[value->len - 1] == first;
}

static ngx_int_t
rn_build_zone_resource(
    ngx_http_request_t *r,
    rn_worker_ctx_t *worker,
    rn_zone_t *zone,
    r_resource_request_t *out
) {
    ngx_str_t bucket = ngx_null_string;
    uint32_t zone_rate_limit = 0;
    uint32_t zone_window_ms = 0;

    if (r == NULL || worker == NULL || zone == NULL || out == NULL) {
        return NGX_ERROR;
    }

    if (ngx_http_complex_value(r, &zone->bucket_cv, &bucket) != NGX_OK
        || bucket.len == 0 || bucket.len > RN_MAX_BUCKET_LEN)
    {
        return NGX_ERROR;
    }
    if (rn_zone_rate_for_request(r, zone, &zone_rate_limit,
            &zone_window_ms) != NGX_OK)
    {
        return NGX_ERROR;
    }
    if (r_client_derive_bucket_id(bucket.data, bucket.len, zone_window_ms,
            zone_rate_limit, out->bucket_id) != RCLIENT_OK)
    {
        return NGX_ERROR;
    }
    if (worker->debug) {
        u_char hex[33];
        rn_hex_id(out->bucket_id, hex);
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: bucket zone=%V id=%s", &zone->name, hex);
    }

    out->window_size_ms = zone_window_ms;
    out->rate_limit = zone_rate_limit;
    out->tokens_requested = 1;
    return NGX_OK;
}

static ngx_int_t
rn_zone_rate_for_request(
    ngx_http_request_t *r,
    rn_zone_t *zone,
    uint32_t *out_rate,
    uint32_t *out_window_ms
) {
    if (r == NULL || zone == NULL || out_rate == NULL || out_window_ms == NULL) {
        return NGX_ERROR;
    }

    ngx_str_t rate = ngx_null_string;
    if (ngx_http_complex_value(r, &zone->rate_cv, &rate) != NGX_OK) {
        return NGX_ERROR;
    }
    return rn_numeric_parse_rate(rate.data, rate.len, out_rate, out_window_ms)
        == 0 ? NGX_OK : NGX_ERROR;
}

static ngx_int_t
rn_build_guard_entries(
    ngx_http_request_t *r,
    rn_worker_ctx_t *worker,
    rn_main_conf_t *mcf,
    rn_guard_t *guard,
    r_latency_guard_t *out_guard,
    r_service_latency_report_t *out_report
) {
    ngx_str_t service = ngx_null_string;
    ngx_str_t threshold = ngx_null_string;
    uint32_t threshold_ms = 0;

    if (r == NULL || worker == NULL || mcf == NULL || guard == NULL
        || out_guard == NULL || out_report == NULL) {
        return NGX_ERROR;
    }

    if (ngx_http_complex_value(r, &guard->service_cv, &service) != NGX_OK
        || service.len == 0 || service.len > RN_MAX_SERVICE_LEN)
    {
        return NGX_ERROR;
    }
    if (ngx_http_complex_value(r, &guard->threshold_cv, &threshold) != NGX_OK) {
        return NGX_ERROR;
    }
    if (rn_parse_protocol_duration_ms(&threshold, &threshold_ms) != NGX_OK) {
        return NGX_ERROR;
    }

    out_guard->threshold_ms = threshold_ms;
    out_guard->ttl_ms = guard->ttl_ms;
    out_guard->max_samples = guard->max_samples;
    out_guard->buffer_size = guard->buffer_size_set
        ? guard->buffer_size : mcf->latency_buffer_size_max;
    if (out_guard->buffer_size == 0) {
        return NGX_ERROR;
    }
    out_guard->min_sample_threshold = guard->min_sample_threshold;
    if (r_client_derive_latency_tracker_id(service.data, service.len,
            out_guard->ttl_ms, out_guard->max_samples,
            out_guard->buffer_size, out_guard->min_sample_threshold,
            out_guard->latency_tracker_id) != RCLIENT_OK)
    {
        return NGX_ERROR;
    }

    ngx_memcpy(out_report->latency_tracker_id,
        out_guard->latency_tracker_id,
        sizeof(out_report->latency_tracker_id));
    out_report->observed_latency = 0;
    out_report->ttl_ms = guard->ttl_ms;
    out_report->max_samples = guard->max_samples;
    out_report->buffer_size = out_guard->buffer_size;
    out_report->min_sample_threshold = guard->min_sample_threshold;

    if (worker->debug) {
        u_char hex[33];
        rn_hex_id(out_guard->latency_tracker_id, hex);
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: guard=%V latency_tracker_id=%s threshold_ms=%uD",
            &guard->name, hex, out_guard->threshold_ms);
    }

    return NGX_OK;
}

static char *
ngx_http_rn_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    ngx_uint_t i;
    ngx_str_t zone_name = value[1];
    ngx_str_t bucket = ngx_null_string;
    ngx_str_t rate = ngx_null_string;
    uint32_t static_rate;
    uint32_t static_window_ms;

    if (zone_name.len == 0 || ngx_strlchr(zone_name.data, zone_name.data + zone_name.len, '=') != NULL) {
        return "ratelimitly_zone requires positional <name> as first argument";
    }

    for (i = 2; i < cf->args->nelts; i++) {
        if (ngx_strncmp(value[i].data, "bucket=", 7) == 0) {
            bucket.data = value[i].data + 7;
            bucket.len = value[i].len - 7;
        } else if (ngx_strncmp(value[i].data, "rate=", 5) == 0) {
            rate.data = value[i].data + 5;
            rate.len = value[i].len - 5;
        } else {
            return "invalid ratelimitly_zone argument";
        }
    }

    if (bucket.len == 0 || rate.len == 0) {
        return "ratelimitly_zone requires <name>, bucket=, rate=";
    }
    if (rn_has_literal_value_quotes(&bucket)) {
        return "quote the complete bucket= argument, not only its value";
    }
    if (ngx_http_script_variables_count(&bucket) == 0
        && bucket.len > RN_MAX_BUCKET_LEN)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "ratelimitly_zone bucket is %uz bytes; maximum is %d",
            bucket.len, RN_MAX_BUCKET_LEN);
        return NGX_CONF_ERROR;
    }
    if (ngx_http_script_variables_count(&rate) == 0
        && rn_numeric_parse_rate(rate.data, rate.len, &static_rate,
            &static_window_ms) != 0)
    {
        return "invalid ratelimitly_zone rate";
    }

    if (mcf->zones == NULL) {
        mcf->zones = ngx_array_create(cf->pool, 4, sizeof(rn_zone_t));
        if (mcf->zones == NULL) {
            return NGX_CONF_ERROR;
        }
    }
    if (rn_find_zone(mcf, &zone_name) != NULL) {
        return "duplicate ratelimitly_zone name";
    }

    rn_zone_t *zone = ngx_array_push(mcf->zones);
    if (zone == NULL) {
        return NGX_CONF_ERROR;
    }
    ngx_memzero(zone, sizeof(*zone));
    zone->name = zone_name;
    zone->bucket_template = bucket;
    zone->rate_template = rate;

    ngx_http_compile_complex_value_t ccv;
    ngx_memzero(&ccv, sizeof(ccv));
    ccv.cf = cf;
    ccv.value = &zone->bucket_template;
    ccv.complex_value = &zone->bucket_cv;
    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(&ccv, sizeof(ccv));
    ccv.cf = cf;
    ccv.value = &zone->rate_template;
    ccv.complex_value = &zone->rate_cv;
    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}

static char *
ngx_http_rn_group(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    ngx_uint_t i;

    if (cf->args->nelts < 3) {
        return "ratelimitly_group requires name and at least one zone=";
    }
    if (value[1].len == 0
        || ngx_strlchr(value[1].data, value[1].data + value[1].len, '=') != NULL)
    {
        return "ratelimitly_group requires positional <name> as first argument";
    }

    if (mcf->groups == NULL) {
        mcf->groups = ngx_array_create(cf->pool, 2, sizeof(rn_group_t));
        if (mcf->groups == NULL) {
            return NGX_CONF_ERROR;
        }
    }
    if (rn_find_group(mcf, &value[1]) != NULL) {
        return "duplicate ratelimitly_group name";
    }

    rn_group_t *group = ngx_array_push(mcf->groups);
    if (group == NULL) {
        return NGX_CONF_ERROR;
    }
    ngx_memzero(group, sizeof(*group));
    group->name = value[1];
    if (ngx_array_init(&group->zones, cf->pool, cf->args->nelts - 2, sizeof(ngx_str_t)) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    for (i = 2; i < cf->args->nelts; i++) {
        if (ngx_strncmp(value[i].data, "zone=", 5) != 0) {
            return "ratelimitly_group expects zone=... entries";
        }
        ngx_str_t zname;
        zname.data = value[i].data + 5;
        zname.len = value[i].len - 5;
        if (zname.len == 0) {
            return "ratelimitly_group requires nonempty zone= references";
        }
        if (rn_find_zone(mcf, &zname) == NULL) {
            return "ratelimitly_group references unknown zone";
        }
        ngx_str_t *z = ngx_array_push(&group->zones);
        if (z == NULL) {
            return NGX_CONF_ERROR;
        }
        *z = zname;
    }

    return NGX_CONF_OK;
}

static char *
ngx_http_rn_guard(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_main_conf_t *mcf = conf;
    ngx_str_t *value = cf->args->elts;
    ngx_uint_t i;
    ngx_str_t guard_name = value[1];
    ngx_str_t service = ngx_null_string;
    ngx_str_t threshold = ngx_null_string;
    uint32_t ttl_ms = 30000;
    uint32_t max_samples = 128;
    uint32_t buffer_size;
    ngx_flag_t buffer_size_set = 0;
    uint32_t min_sample_threshold = 8;
    uint32_t static_threshold_ms;

    if (cf->args->nelts < 4) {
        return "ratelimitly_guard requires <name>, service=, threshold=";
    }
    if (guard_name.len == 0 || ngx_strlchr(guard_name.data, guard_name.data + guard_name.len, '=') != NULL) {
        return "ratelimitly_guard requires positional <name> as first argument";
    }

    for (i = 2; i < cf->args->nelts; i++) {
        if (ngx_strncmp(value[i].data, "service=", 8) == 0) {
            service.data = value[i].data + 8;
            service.len = value[i].len - 8;
        } else if (ngx_strncmp(value[i].data, "threshold=", 10) == 0) {
            threshold.data = value[i].data + 10;
            threshold.len = value[i].len - 10;
        } else if (ngx_strncmp(value[i].data, "ttl=", 4) == 0) {
            ngx_str_t ttl;
            ttl.data = value[i].data + 4;
            ttl.len = value[i].len - 4;
            if (rn_parse_protocol_duration_ms(&ttl, &ttl_ms) != NGX_OK) {
                return "invalid ratelimitly_guard ttl";
            }
        } else if (ngx_strncmp(value[i].data, "max_samples=", 12) == 0) {
            ngx_str_t n;
            n.data = value[i].data + 12;
            n.len = value[i].len - 12;
            if (rn_numeric_parse_u32(n.data, n.len, &max_samples) != 0
                || max_samples == 0)
            {
                return "invalid ratelimitly_guard max_samples";
            }
        } else if (ngx_strncmp(value[i].data, "buffer_size=", 12) == 0) {
            ngx_str_t n;
            n.data = value[i].data + 12;
            n.len = value[i].len - 12;
            if (rn_numeric_parse_u32(n.data, n.len, &buffer_size) != 0
                || buffer_size == 0)
            {
                return "invalid ratelimitly_guard buffer_size";
            }
            buffer_size_set = 1;
        } else if (ngx_strncmp(value[i].data, "min_sample_threshold=", 21) == 0) {
            ngx_str_t n;
            n.data = value[i].data + 21;
            n.len = value[i].len - 21;
            if (rn_numeric_parse_u32(n.data, n.len,
                    &min_sample_threshold) != 0)
            {
                return "invalid ratelimitly_guard min_sample_threshold";
            }
        } else {
            return "invalid ratelimitly_guard argument";
        }
    }

    if (service.len == 0 || threshold.len == 0) {
        return "ratelimitly_guard requires <name>, service=, threshold=";
    }
    if (rn_has_literal_value_quotes(&service)) {
        return "quote the complete service= argument, not only its value";
    }
    if (ngx_http_script_variables_count(&service) == 0
        && service.len > RN_MAX_SERVICE_LEN)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "ratelimitly_guard service is %uz bytes; maximum is %d",
            service.len, RN_MAX_SERVICE_LEN);
        return NGX_CONF_ERROR;
    }
    if (ngx_http_script_variables_count(&threshold) == 0
        && rn_parse_protocol_duration_ms(&threshold,
            &static_threshold_ms) != NGX_OK)
    {
        return "invalid ratelimitly_guard threshold";
    }

    if (mcf->guards == NULL) {
        mcf->guards = ngx_array_create(cf->pool, 4, sizeof(rn_guard_t));
        if (mcf->guards == NULL) {
            return NGX_CONF_ERROR;
        }
    }
    if (rn_find_guard(mcf, &guard_name) != NULL) {
        return "duplicate ratelimitly_guard name";
    }

    rn_guard_t *guard = ngx_array_push(mcf->guards);
    if (guard == NULL) {
        return NGX_CONF_ERROR;
    }
    ngx_memzero(guard, sizeof(*guard));
    guard->name = guard_name;
    guard->service_template = service;
    guard->threshold_template = threshold;
    guard->ttl_ms = ttl_ms;
    guard->max_samples = max_samples;
    guard->buffer_size_set = buffer_size_set;
    if (buffer_size_set) {
        guard->buffer_size = buffer_size;
    }
    guard->min_sample_threshold = min_sample_threshold;

    ngx_http_compile_complex_value_t ccv;
    ngx_memzero(&ccv, sizeof(ccv));
    ccv.cf = cf;
    ccv.value = &guard->service_template;
    ccv.complex_value = &guard->service_cv;
    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(&ccv, sizeof(ccv));
    ccv.cf = cf;
    ccv.value = &guard->threshold_template;
    ccv.complex_value = &guard->threshold_cv;
    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}

static char *
ngx_http_rn_rule(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_loc_conf_t *lcf = conf;
    ngx_str_t *value = cf->args->elts;
    rn_rule_ref_t *rule = NULL;
    rn_main_conf_t *mcf;
    ngx_uint_t i;
    ngx_str_t zone_name = ngx_null_string;
    ngx_str_t group_name = ngx_null_string;
    ngx_flag_t zone_seen = 0;
    ngx_flag_t group_seen = 0;
    ngx_array_t *guard_names = NULL;

    if (lcf->rules == NULL) {
        lcf->rules = ngx_array_create(cf->pool, 2, sizeof(rn_rule_ref_t));
        if (lcf->rules == NULL) {
            return NGX_CONF_ERROR;
        }
    }
    mcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_rn_module);
    guard_names = ngx_array_create(cf->pool, 2, sizeof(ngx_str_t));
    if (guard_names == NULL) {
        return NGX_CONF_ERROR;
    }

    for (i = 1; i < cf->args->nelts; i++) {
        if (ngx_strncmp(value[i].data, "zone=", 5) == 0) {
            if (group_seen || zone_seen) {
                return "ratelimitly expects exactly one of zone= or group=";
            }
            zone_seen = 1;
            zone_name.data = value[i].data + 5;
            zone_name.len = value[i].len - 5;
        } else if (ngx_strncmp(value[i].data, "group=", 6) == 0) {
            if (zone_seen || group_seen) {
                return "ratelimitly expects exactly one of zone= or group=";
            }
            group_seen = 1;
            group_name.data = value[i].data + 6;
            group_name.len = value[i].len - 6;
        } else if (ngx_strncmp(value[i].data, "guard=", 6) == 0) {
            ngx_str_t gname;
            ngx_str_t *g;
            gname.data = value[i].data + 6;
            gname.len = value[i].len - 6;
            if (gname.len == 0) {
                return "ratelimitly requires nonempty guard= references";
            }
            if (rn_find_guard(mcf, &gname) == NULL) {
                return "ratelimitly references unknown guard";
            }
            g = ngx_array_push(guard_names);
            if (g == NULL) {
                return NGX_CONF_ERROR;
            }
            *g = gname;
        } else {
            return "ratelimitly expects zone=, group=, and optional guard=";
        }
    }

    if (!zone_seen && !group_seen) {
        return "ratelimitly requires zone=<name> or group=<name>";
    }
    if ((zone_seen && zone_name.len == 0)
        || (group_seen && group_name.len == 0))
    {
        return "ratelimitly requires a nonempty zone= or group= reference";
    }
    if (zone_seen) {
        if (rn_find_zone(mcf, &zone_name) == NULL) {
            return "ratelimitly references unknown zone";
        }
        rule = ngx_array_push(lcf->rules);
        if (rule == NULL) {
            return NGX_CONF_ERROR;
        }
        ngx_memzero(rule, sizeof(*rule));
        rule->kind = RN_RULE_ZONE;
        rule->name = zone_name;
    } else {
        if (rn_find_group(mcf, &group_name) == NULL) {
            return "ratelimitly references unknown group";
        }
        rule = ngx_array_push(lcf->rules);
        if (rule == NULL) {
            return NGX_CONF_ERROR;
        }
        ngx_memzero(rule, sizeof(*rule));
        rule->kind = RN_RULE_GROUP;
        rule->name = group_name;
    }

    if (ngx_array_init(&rule->guards, cf->pool,
                       (guard_names->nelts > 0) ? guard_names->nelts : 1,
                       sizeof(ngx_str_t)) != NGX_OK) {
        return NGX_CONF_ERROR;
    }
    if (guard_names->nelts > 0) {
        ngx_str_t *src = guard_names->elts;
        for (i = 0; i < guard_names->nelts; i++) {
            ngx_str_t *dst = ngx_array_push(&rule->guards);
            if (dst == NULL) {
                return NGX_CONF_ERROR;
            }
            *dst = src[i];
        }
    }

    lcf->enabled = 1;
    if (mcf) {
        mcf->enabled = 1;
    }
    return NGX_CONF_OK;
}

static char *
ngx_http_rn_label(ngx_conf_t *cf, ngx_command_t *cmd, void *conf) {
    rn_loc_conf_t *lcf = conf;
    ngx_str_t *value = cf->args->elts;

    if (ngx_http_script_variables_count(&value[1]) == 0
        && value[1].len > RN_MAX_LABEL_LEN)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
            "ratelimitly_label is %uz bytes; maximum is %d",
            value[1].len, RN_MAX_LABEL_LEN);
        return NGX_CONF_ERROR;
    }

    lcf->label_template = value[1];
    ngx_http_compile_complex_value_t ccv;
    ngx_memzero(&ccv, sizeof(ccv));
    ccv.cf = cf;
    ccv.value = &lcf->label_template;
    ccv.complex_value = &lcf->label_cv;
    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }
    lcf->label_set = 1;
    return NGX_CONF_OK;
}

static rn_zone_t *
rn_find_zone(rn_main_conf_t *mcf, ngx_str_t *name) {
    if (mcf == NULL || mcf->zones == NULL || name == NULL) {
        return NULL;
    }
    rn_zone_t *zones = mcf->zones->elts;
    for (ngx_uint_t i = 0; i < mcf->zones->nelts; i++) {
        if (zones[i].name.len == name->len
            && ngx_strncmp(zones[i].name.data, name->data, name->len) == 0) {
            return &zones[i];
        }
    }
    return NULL;
}

static rn_guard_t *
rn_find_guard(rn_main_conf_t *mcf, ngx_str_t *name) {
    if (mcf == NULL || mcf->guards == NULL || name == NULL) {
        return NULL;
    }
    rn_guard_t *guards = mcf->guards->elts;
    for (ngx_uint_t i = 0; i < mcf->guards->nelts; i++) {
        if (guards[i].name.len == name->len
            && ngx_strncmp(guards[i].name.data, name->data, name->len) == 0) {
            return &guards[i];
        }
    }
    return NULL;
}

static rn_group_t *
rn_find_group(rn_main_conf_t *mcf, ngx_str_t *name) {
    if (mcf == NULL || mcf->groups == NULL || name == NULL) {
        return NULL;
    }
    rn_group_t *groups = mcf->groups->elts;
    for (ngx_uint_t i = 0; i < mcf->groups->nelts; i++) {
        if (groups[i].name.len == name->len
            && ngx_strncmp(groups[i].name.data, name->data, name->len) == 0) {
            return &groups[i];
        }
    }
    return NULL;
}

static const char *
rn_auth_type_name(r_auth_type_t t) {
    switch (t) {
    case R_AUTH_COOKIE:
        return "cookie";
    case R_AUTH_AES_GCM:
        return "aes";
    default:
        return "unknown";
    }
}

static uint16_t
rn_read_le16(const uint8_t *p) {
    if (p == NULL) {
        return 0;
    }
    return (uint16_t) (p[0] | ((uint16_t) p[1] << 8));
}

static uint64_t
rn_read_le64(const uint8_t *p) {
    if (p == NULL) {
        return 0;
    }
    return ((uint64_t) p[0])
        | ((uint64_t) p[1] << 8)
        | ((uint64_t) p[2] << 16)
        | ((uint64_t) p[3] << 24)
        | ((uint64_t) p[4] << 32)
        | ((uint64_t) p[5] << 40)
        | ((uint64_t) p[6] << 48)
        | ((uint64_t) p[7] << 56);
}

static const char *
rn_auth_tlv_name(uint16_t tlv_type) {
    switch (tlv_type) {
    case 0x4143:
        return "cookie";
    case 0x4541:
        return "aes";
    default:
        return "unknown";
    }
}

static const char *
rn_rclient_status_name(int status) {
    switch (status) {
    case RCLIENT_OK:
        return "ok";
    case RCLIENT_ERR_IO:
        return "io";
    case RCLIENT_ERR_TIMEOUT:
        return "timeout";
    case RCLIENT_ERR_PROTOCOL:
        return "protocol";
    case RCLIENT_ERR_AUTH:
        return "auth";
    case RCLIENT_ERR_DNS:
        return "dns";
    case RCLIENT_ERR_CONFIG:
        return "config";
    case RCLIENT_ERR_NOMEM:
        return "nomem";
    default:
        return "unknown";
    }
}

static int
rn_udp_send(void *ctx, const r_addr_t *to, const uint8_t *buf, size_t len) {
    rn_worker_ctx_t *worker = ctx;
    if (worker == NULL || worker->udp_fd == (ngx_socket_t) -1 || to == NULL || buf == NULL) {
        return -1;
    }
    if (worker->debug) {
        u_char text[NGX_SOCKADDR_STRLEN];
        size_t n = ngx_sock_ntop((struct sockaddr *)&to->sa, to->len, text, sizeof(text), 1);
        if (n >= sizeof(text)) {
            n = sizeof(text) - 1;
        }
        text[n] = '\0';
        if (len >= 44) {
            uint16_t tlv_type = rn_read_le16(buf);
            uint16_t tlv_size = rn_read_le16(buf + 2);
            if (tlv_type == 0x4C52 && tlv_size >= 40 && tlv_size <= len) {
                uint64_t key_id = rn_read_le64(buf + 4);
                uint16_t auth_tlv_type = rn_read_le16(buf + 40);
                uint16_t auth_tlv_size = rn_read_le16(buf + 42);
                u_char hex[33];
                rn_hex16((const uint8_t *) (buf + 12), hex);
                ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                    "rn: udp_send to=%s len=%uz key_id=%uL req_id=%s auth_tlv=%s(%ui) auth_size=%ui",
                    text, len, (unsigned long) key_id, hex,
                    rn_auth_tlv_name(auth_tlv_type), (unsigned) auth_tlv_type,
                    (unsigned) auth_tlv_size);
            } else {
                ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                    "rn: udp_send to=%s len=%uz", text, len);
            }
        } else {
            ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                "rn: udp_send to=%s len=%uz", text, len);
        }
    }
    struct sockaddr_storage dest = to->sa;
    socklen_t dest_len = (socklen_t) to->len;

    if (worker->udp_family == AF_INET6 && dest.ss_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *) &dest;
        struct sockaddr_in6 mapped;
        ngx_memzero(&mapped, sizeof(mapped));
        mapped.sin6_family = AF_INET6;
        mapped.sin6_port = sin->sin_port;
        mapped.sin6_addr.s6_addr[10] = 0xff;
        mapped.sin6_addr.s6_addr[11] = 0xff;
        ngx_memcpy(&mapped.sin6_addr.s6_addr[12], &sin->sin_addr, 4);
        ngx_memcpy(&dest, &mapped, sizeof(mapped));
        dest_len = sizeof(mapped);
    }

    ssize_t n = sendto(worker->udp_fd, buf, len, 0, (struct sockaddr *) &dest, dest_len);
    if (n < 0 || (size_t) n != len) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, ngx_socket_errno,
                "rn: udp_send failed (len=%uz)", len);
        }
        return -1;
    }
    return 0;
}

static uint64_t
rn_now_ms(void *ctx) {
    (void) ctx;
    ngx_time_t *tp = ngx_timeofday();
    if (tp == NULL) {
        return 0;
    }
    return (uint64_t) tp->sec * 1000u + (uint64_t) tp->msec;
}

static void
rn_log(void *ctx, r_log_level_t level, const char *msg) {
    rn_worker_ctx_t *worker = ctx;
    ngx_log_t *log = worker ? worker->log : ngx_cycle->log;
    if (log == NULL || msg == NULL) {
        return;
    }
    ngx_uint_t ngx_level = NGX_LOG_INFO;
    if (level == R_LOG_ERROR) {
        ngx_level = NGX_LOG_ERR;
    } else if (level == R_LOG_WARN) {
        ngx_level = NGX_LOG_WARN;
    } else if (level == R_LOG_DEBUG) {
        ngx_level = NGX_LOG_DEBUG;
    }
    ngx_log_error(ngx_level, log, 0, "rn: %s", msg);
}

static void
rn_on_steering_feedback(void *ctx, bool keep_port) {
    rn_worker_ctx_t *worker = ctx;
    if (worker == NULL || keep_port) {
        return;
    }
    worker->rebind_pending = 1;
    if (worker->debug) {
        ngx_log_error(NGX_LOG_INFO, worker->log, 0, "rn: steering_feedback=0 (rebind pending)");
    }
    rn_schedule_rebind(worker);
}

#if (RN_TEST_FAULT_INJECTION)
static ngx_flag_t
rn_test_fault_active(rn_worker_ctx_t *worker, const char *name)
{
    size_t name_len;

    if (worker == NULL || name == NULL || worker->test_fault.len == 0) {
        return 0;
    }
    name_len = ngx_strlen(name);
    if (worker->test_fault.len != name_len
        || ngx_strncmp(worker->test_fault.data, name, name_len) != 0)
    {
        return 0;
    }
    ngx_log_error(NGX_LOG_NOTICE, worker->log, 0,
        "rn: test fault injected: %s", name);
    return 1;
}
#endif

typedef struct {
    rn_worker_ctx_t *worker;
    r_dns_srv_cb srv_cb;
    r_dns_addr_cb addr_cb;
    void *user;
    u_char *name_buf;
    size_t name_len;
    u_char *service_buf;
    size_t service_len;
    rn_async_state_t start_state;
} rn_dns_req_t;

static void rn_resolve_srv_handler(ngx_resolver_ctx_t *ctx);
static void rn_resolve_addr_handler(ngx_resolver_ctx_t *ctx);

static void
rn_dns_req_release(rn_dns_req_t *req)
{
    if (req == NULL) {
        return;
    }
    if (req->name_buf != NULL) {
        ngx_free(req->name_buf);
        req->name_buf = NULL;
    }
    if (req->service_buf != NULL) {
        ngx_free(req->service_buf);
        req->service_buf = NULL;
    }
    ngx_free(req);
}

static void
rn_dns_discard_unstarted(ngx_resolver_ctx_t *rctx, rn_dns_req_t *req)
{
    if (rctx != NULL) {
        rctx->data = NULL;
        ngx_resolve_name_done(rctx);
    }
    rn_dns_req_release(req);
}

static void *
rn_dns_alloc(rn_worker_ctx_t *worker, size_t size, const char *fault)
{
#if (RN_TEST_FAULT_INJECTION)
    if (rn_test_fault_active(worker, fault)) {
        return NULL;
    }
#else
    (void) fault;
#endif
    return ngx_alloc(size, worker->log);
}

static ngx_int_t
rn_resolve_name_start(rn_worker_ctx_t *worker, ngx_resolver_ctx_t *rctx,
    const char *fault)
{
#if (RN_TEST_FAULT_INJECTION)
    if (rn_test_fault_active(worker, fault)) {
        /* Model ngx_resolve_name()'s NGX_ERROR ownership contract: the
         * resolver context is no longer live when the call returns. */
        rctx->data = NULL;
        ngx_resolve_name_done(rctx);
        return NGX_ERROR;
    }
#else
    (void) worker;
    (void) fault;
#endif
    return ngx_resolve_name(rctx);
}

static void *
rn_srv_ngx_alloc(size_t size, void *ctx) {
    rn_worker_ctx_t *worker = ctx;
    return ngx_alloc(size, worker->log);
}

static void
rn_srv_ngx_free(void *ptr, void *ctx) {
    (void) ctx;
    ngx_free(ptr);
}

static int
rn_resolve_srv(void *ctx, const char *name, r_dns_req_id_t *out_req_id, r_dns_srv_cb cb, void *user) {
    rn_worker_ctx_t *worker = ctx;
    ngx_resolver_ctx_t *rctx;
    rn_dns_req_t *req;
    ngx_int_t resolve_rc;

    if (out_req_id != NULL) {
        *out_req_id = 0;
    }
    if (worker == NULL || worker->resolver == NULL || name == NULL
        || out_req_id == NULL || cb == NULL)
    {
        return -1;
    }

    rctx = ngx_resolve_start(worker->resolver, NULL);
    if (rctx == NULL || rctx == (ngx_resolver_ctx_t *) NGX_NO_RESOLVER) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, 0,
                "rn: resolve_srv start_failed name=%s no_resolver_ctx=1", name);
        }
        return -1;
    }

    req = rn_dns_alloc(worker, sizeof(rn_dns_req_t),
        "resolver-srv-request");
    if (req == NULL) {
        rn_dns_discard_unstarted(rctx, NULL);
        return -1;
    }
    ngx_memzero(req, sizeof(*req));
    req->worker = worker;
    req->srv_cb = cb;
    req->user = user;
    req->name_len = ngx_strlen(name);
    req->name_buf = rn_dns_alloc(worker, req->name_len + 1,
        "resolver-srv-name");
    if (req->name_buf == NULL) {
        rn_dns_discard_unstarted(rctx, req);
        return -1;
    }
    ngx_memcpy(req->name_buf, name, req->name_len);
    req->name_buf[req->name_len] = '\0';

    /* split service and domain for SRV lookups: _service._proto.domain */
    u_char *first = (u_char *)ngx_strlchr(req->name_buf, req->name_buf + req->name_len, '.');
    u_char *second = NULL;
    if (first) {
        second = (u_char *)ngx_strlchr(first + 1, req->name_buf + req->name_len, '.');
    }
    if (second) {
        req->service_len = (size_t)(second - req->name_buf);
        req->service_buf = rn_dns_alloc(worker, req->service_len,
            "resolver-srv-service");
        if (req->service_buf == NULL) {
            rn_dns_discard_unstarted(rctx, req);
            return -1;
        }
        ngx_memcpy(req->service_buf, req->name_buf, req->service_len);

        size_t domain_len = (size_t)((req->name_buf + req->name_len) - (second + 1));
        u_char *domain_buf = rn_dns_alloc(worker, domain_len + 1,
            "resolver-srv-domain");
        if (domain_buf == NULL) {
            rn_dns_discard_unstarted(rctx, req);
            return -1;
        }
        ngx_memcpy(domain_buf, second + 1, domain_len);
        domain_buf[domain_len] = '\0';
        ngx_free(req->name_buf);
        req->name_buf = domain_buf;
        req->name_len = domain_len;
    }

    rctx->name.len = req->name_len;
    rctx->name.data = req->name_buf;
    if (req->service_buf) {
        rctx->service.len = req->service_len;
        rctx->service.data = req->service_buf;
    } else {
        rctx->service.len = 0;
        rctx->service.data = NULL;
    }
    rctx->handler = rn_resolve_srv_handler;
    rctx->data = req;
    rctx->timeout = worker->resolver_timeout;

    if (worker->debug) {
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: resolve_srv start name=%s timeout_ms=%M", name,
            worker->resolver_timeout);
    }

    rn_async_state_begin(&req->start_state);
    resolve_rc = rn_resolve_name_start(worker, rctx, "resolver-srv-start");
    if (!rn_async_state_finish(&req->start_state, resolve_rc == NGX_OK)) {
        /* The handler completed synchronous success; nginx freed rctx on
         * NGX_ERROR. In both cases only module allocations remain. */
        rn_dns_req_release(req);
        return resolve_rc == NGX_OK ? 0 : -1;
    }

    *out_req_id = (r_dns_req_id_t)(uintptr_t) rctx;
    return 0;
}

static int
rn_resolve_addrs(void *ctx, const char *name, r_dns_req_id_t *out_req_id, r_dns_addr_cb cb, void *user) {
    rn_worker_ctx_t *worker = ctx;
    ngx_resolver_ctx_t *rctx;
    rn_dns_req_t *req;
    ngx_int_t resolve_rc;

    if (out_req_id != NULL) {
        *out_req_id = 0;
    }
    if (worker == NULL || worker->resolver == NULL || name == NULL
        || out_req_id == NULL || cb == NULL)
    {
        return -1;
    }

    rctx = ngx_resolve_start(worker->resolver, NULL);
    if (rctx == NULL || rctx == (ngx_resolver_ctx_t *) NGX_NO_RESOLVER) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, 0,
                "rn: resolve_addrs start_failed name=%s no_resolver_ctx=1", name);
        }
        return -1;
    }

    req = rn_dns_alloc(worker, sizeof(rn_dns_req_t),
        "resolver-addr-request");
    if (req == NULL) {
        rn_dns_discard_unstarted(rctx, NULL);
        return -1;
    }
    ngx_memzero(req, sizeof(*req));
    req->worker = worker;
    req->addr_cb = cb;
    req->user = user;
    req->name_len = ngx_strlen(name);
    req->name_buf = rn_dns_alloc(worker, req->name_len + 1,
        "resolver-addr-name");
    if (req->name_buf == NULL) {
        rn_dns_discard_unstarted(rctx, req);
        return -1;
    }
    ngx_memcpy(req->name_buf, name, req->name_len);
    req->name_buf[req->name_len] = '\0';

    rctx->name.len = req->name_len;
    rctx->name.data = req->name_buf;
    rctx->handler = rn_resolve_addr_handler;
    rctx->data = req;
    rctx->timeout = worker->resolver_timeout;

    if (worker->debug) {
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: resolve_addrs start name=%s timeout_ms=%M", name,
            worker->resolver_timeout);
    }

    rn_async_state_begin(&req->start_state);
    resolve_rc = rn_resolve_name_start(worker, rctx, "resolver-addr-start");
    if (!rn_async_state_finish(&req->start_state, resolve_rc == NGX_OK)) {
        /* The handler completed synchronous success; nginx freed rctx on
         * NGX_ERROR. In both cases only module allocations remain. */
        rn_dns_req_release(req);
        return resolve_rc == NGX_OK ? 0 : -1;
    }

    *out_req_id = (r_dns_req_id_t)(uintptr_t) rctx;
    return 0;
}

static void
rn_resolve_cancel(void *ctx, r_dns_req_id_t req_id) {
    rn_worker_ctx_t *worker = ctx;
    ngx_resolver_ctx_t *rctx = (ngx_resolver_ctx_t *)(uintptr_t) req_id;
    rn_dns_req_t *req;
    r_dns_srv_cb srv_cb;
    r_dns_addr_cb addr_cb;
    void *user;

    if (worker == NULL || rctx == NULL) {
        return;
    }

    req = rctx->data;
    if (req == NULL) {
        return;
    }

    srv_cb = req->srv_cb;
    addr_cb = req->addr_cb;
    user = req->user;
    rctx->data = NULL;
    rn_async_state_complete(&req->start_state);
    ngx_resolve_name_done(rctx);
    rn_dns_req_release(req);

    /* The C client permits late callbacks after cancellation.  Completing the
     * cancelled lookup here lets it retire its lookup state immediately. */
    if (srv_cb != NULL) {
        srv_cb(user, RCLIENT_ERR_DNS, NULL, 0);
    } else if (addr_cb != NULL) {
        addr_cb(user, RCLIENT_ERR_DNS, NULL, 0);
    }
}

static void
rn_close_udp_endpoint(ngx_connection_t *conn, ngx_socket_t fd)
{
    if (conn != NULL) {
        ngx_close_connection(conn);
    } else if (fd != (ngx_socket_t) -1) {
        ngx_close_socket(fd);
    }
}

static ngx_int_t
rn_open_socket_candidate(rn_worker_ctx_t *worker, ngx_socket_t *out_fd,
    int *out_family, ngx_connection_t **out_conn)
{
    struct sockaddr_storage ss;
    socklen_t slen;
    ngx_socket_t s;
    ngx_connection_t *conn;
    int family;

    if (worker == NULL || out_fd == NULL || out_family == NULL
        || out_conn == NULL)
    {
        return NGX_ERROR;
    }
    *out_fd = (ngx_socket_t) -1;
    *out_family = AF_UNSPEC;
    *out_conn = NULL;

    ngx_memzero(&ss, sizeof(ss));
    slen = worker->bind_socklen;
    if (slen != 0) {
        ngx_memcpy(&ss, &worker->bind_sockaddr, slen);
        family = ss.ss_family;
    } else {
        family = AF_INET6;
    }

    s = ngx_socket(family, SOCK_DGRAM, 0);
    if (s != (ngx_socket_t) -1 && family == AF_INET6) {
        int v6only = 0;
        (void) setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
            sizeof(v6only));
    }
    if (s == (ngx_socket_t) -1 && slen == 0 && family == AF_INET6) {
        family = AF_INET;
        s = ngx_socket(family, SOCK_DGRAM, 0);
    }
    if (s == (ngx_socket_t) -1) {
        return NGX_ERROR;
    }
    if (ngx_nonblocking(s) == -1) {
        ngx_close_socket(s);
        return NGX_ERROR;
    }

    if (slen == 0) {
        if (family == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *) &ss;
            sin->sin_family = AF_INET;
            sin->sin_port = htons(0);
            sin->sin_addr.s_addr = htonl(INADDR_ANY);
            slen = sizeof(*sin);
        } else {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *) &ss;
            sin6->sin6_family = AF_INET6;
            sin6->sin6_port = htons(0);
            sin6->sin6_addr = in6addr_any;
            slen = sizeof(*sin6);
        }
    } else if (ss.ss_family == AF_INET) {
        ((struct sockaddr_in *) &ss)->sin_port = htons(0);
    } else {
        ((struct sockaddr_in6 *) &ss)->sin6_port = htons(0);
    }

    if (bind(s, (struct sockaddr *) &ss, slen) != 0) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, ngx_socket_errno,
                "rn: bind failed");
        }
        ngx_close_socket(s);
        return NGX_ERROR;
    }

    conn = ngx_get_connection(s, worker->log);
    if (conn == NULL) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, 0,
                "rn: ngx_get_connection failed");
        }
        ngx_close_socket(s);
        return NGX_ERROR;
    }
    conn->data = worker;
    conn->read->log = worker->log;
    conn->write->log = worker->log;
    conn->read->data = conn;
    conn->write->data = conn;
    conn->read->handler = rn_udp_read_handler;
    if (ngx_add_event(conn->read, NGX_READ_EVENT, 0) != NGX_OK) {
        if (worker->debug) {
            ngx_log_error(NGX_LOG_WARN, worker->log, 0,
                "rn: ngx_add_event failed");
        }
        ngx_close_connection(conn);
        return NGX_ERROR;
    }

    *out_fd = s;
    *out_family = family;
    *out_conn = conn;
    return NGX_OK;
}

static void
rn_resolve_srv_handler(ngx_resolver_ctx_t *ctx) {
    rn_dns_req_t *req = ctx ? ctx->data : NULL;
    if (req == NULL || req->srv_cb == NULL) {
        if (ctx) {
            ngx_resolve_name_done(ctx);
        }
        return;
    }

    ctx->data = NULL;
    rn_async_state_complete(&req->start_state);

    if (ctx->state != 0 || ctx->nsrvs == 0) {
        req->srv_cb(req->user, -1, NULL, 0);
    } else {
        rn_srv_source_t *sources;
        rn_srv_records_t result;
        uint32_t ttl_ms;
        time_t now_s;

        ngx_memzero(&result, sizeof(result));
        now_s = ngx_time();
        ttl_ms = 0;
        if (ctx->valid > now_s) {
            ttl_ms = rn_numeric_ttl_ms_until((uint64_t) ctx->valid,
                (uint64_t) now_s);
        }
        if (ctx->nsrvs > SIZE_MAX / sizeof(rn_srv_source_t)) {
            req->srv_cb(req->user, -1, NULL, 0);
        } else {
            sources = ngx_alloc(ctx->nsrvs * sizeof(rn_srv_source_t),
                req->worker->log);
            if (sources == NULL) {
                req->srv_cb(req->user, -1, NULL, 0);
            } else {
                for (ngx_uint_t i = 0; i < ctx->nsrvs; i++) {
                    ngx_resolver_srv_name_t *srv = &ctx->srvs[i];
                    sources[i].target = srv->name.data;
                    sources[i].target_len = srv->name.len;
                    sources[i].port = (uint16_t) srv->port;
                    sources[i].priority = (uint16_t) srv->priority;
                    sources[i].weight = (uint16_t) srv->weight;
                    sources[i].ttl_ms = ttl_ms;
                }
                if (rn_srv_records_build(sources, ctx->nsrvs,
                        rn_srv_ngx_alloc, rn_srv_ngx_free, req->worker,
                        &result) != 0)
                {
                    req->srv_cb(req->user, -1, NULL, 0);
                } else {
                    if (req->worker->debug) {
                        for (size_t i = 0; i < result.count; i++) {
                            ngx_log_error(NGX_LOG_DEBUG, req->worker->log, 0,
                                "rn: SRV target=%s port=%ui ttl=%uD",
                                result.records[i].target,
                                result.records[i].port,
                                result.records[i].ttl_ms);
                        }
                    }
                    req->srv_cb(req->user, 0, result.records, result.count);
                }
                rn_srv_records_free(&result, rn_srv_ngx_free, req->worker);
                ngx_free(sources);
            }
        }
    }

    ngx_resolve_name_done(ctx);
    if (!rn_async_state_is_starting(&req->start_state)) {
        rn_dns_req_release(req);
    }
}

static void
rn_resolve_addr_handler(ngx_resolver_ctx_t *ctx) {
    rn_dns_req_t *req = ctx ? ctx->data : NULL;
    if (req == NULL || req->addr_cb == NULL) {
        if (ctx) {
            ngx_resolve_name_done(ctx);
        }
        return;
    }

    ctx->data = NULL;
    rn_async_state_complete(&req->start_state);

    if (ctx->state != 0 || ctx->naddrs == 0) {
        req->addr_cb(req->user, -1, NULL, 0);
    } else {
        rn_addr_source_t *sources = NULL;
        r_addr_t *addrs = NULL;
        size_t addr_count;

        if (ctx->naddrs > SIZE_MAX / sizeof(r_addr_t)
            || ctx->naddrs > SIZE_MAX / sizeof(rn_addr_source_t))
        {
            req->addr_cb(req->user, -1, NULL, 0);
        } else {
            addrs = ngx_alloc(ctx->naddrs * sizeof(r_addr_t), req->worker->log);
            sources = ngx_alloc(ctx->naddrs * sizeof(rn_addr_source_t),
                req->worker->log);
            if (addrs == NULL || sources == NULL) {
                req->addr_cb(req->user, -1, NULL, 0);
            } else {
                for (ngx_uint_t i = 0; i < ctx->naddrs; i++) {
                    ngx_resolver_addr_t *addr = &ctx->addrs[i];
                    sources[i].sockaddr = addr->sockaddr;
                    sources[i].socklen = addr->socklen;
                }
                addr_count = rn_addr_records_compact(sources, ctx->naddrs,
                    addrs, ctx->naddrs);
                if (req->worker->debug) {
                    for (size_t i = 0; i < addr_count; i++) {
                        struct sockaddr *addr = (struct sockaddr *) &addrs[i].sa;
                        socklen_t addr_len = addrs[i].len;
                        u_char text[NGX_SOCKADDR_STRLEN];
                        size_t n = ngx_sock_ntop(addr, addr_len, text,
                            sizeof(text), 0);
                        if (n >= sizeof(text)) {
                            n = sizeof(text) - 1;
                        }
                        text[n] = '\0';
                        ngx_log_error(NGX_LOG_DEBUG, req->worker->log, 0,
                            "rn: addr=%s", text);
                    }
                }
                if (addr_count == 0) {
                    req->addr_cb(req->user, -1, NULL, 0);
                } else {
                    req->addr_cb(req->user, 0, addrs, addr_count);
                }
            }
        }
        if (sources != NULL) {
            ngx_free(sources);
        }
        if (addrs != NULL) {
            ngx_free(addrs);
        }
    }

    ngx_resolve_name_done(ctx);
    if (!rn_async_state_is_starting(&req->start_state)) {
        rn_dns_req_release(req);
    }
}

static ngx_int_t
rn_rebind_socket(rn_worker_ctx_t *worker) {
    ngx_socket_t new_fd;
    ngx_socket_t old_fd;
    ngx_connection_t *new_conn;
    ngx_connection_t *old_conn;
    int new_family;

    if (worker == NULL) {
        return NGX_ERROR;
    }
#if (RN_TEST_FAULT_INJECTION)
    if (rn_test_fault_active(worker, "rebind-open")) {
        return NGX_ERROR;
    }
#endif
    if (worker->debug) {
        ngx_log_error(NGX_LOG_DEBUG, ngx_cycle->log, 0,
            "rn: rebind_socket udp_read_active=%d", (int) worker->udp_read_active);
    }

    if (rn_open_socket_candidate(worker, &new_fd, &new_family, &new_conn)
        != NGX_OK)
    {
        return NGX_ERROR;
    }

    old_fd = worker->udp_fd;
    old_conn = worker->udp_conn;
    worker->udp_fd = new_fd;
    worker->udp_family = new_family;
    worker->udp_conn = new_conn;
    worker->rebind_pending = 0;
    rn_close_udp_endpoint(old_conn, old_fd);
    if (worker->debug) {
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: UDP source socket rebound");
    }
    return NGX_OK;
}

static void
rn_worker_cleanup(rn_worker_ctx_t *worker)
{
    if (worker == NULL) {
        return;
    }
    if (worker->rebind_event.timer_set) {
        ngx_del_timer(&worker->rebind_event);
    }
    worker->rebind_scheduled = 0;
    worker->rebind_pending = 0;

    /* Destroy the client while its resolver and UDP adapter context is live. */
    if (worker->client != NULL) {
        r_client_destroy(worker->client);
        worker->client = NULL;
    }
    rn_close_udp_endpoint(worker->udp_conn, worker->udp_fd);
    worker->udp_conn = NULL;
    worker->udp_fd = (ngx_socket_t) -1;
    worker->udp_family = AF_UNSPEC;
    worker->inflight = 0;
}

static void
rn_worker_release_config_buffers(rn_worker_ctx_t *worker, char *dns,
    char *secret, size_t secret_len)
{
    if (worker != NULL) {
        worker->client_cfg.tenant.dns_name = NULL;
        worker->client_cfg.tenant.auth.secret = NULL;
        worker->client_cfg.tenant.auth.secret_len = 0;
    }
    if (secret != NULL) {
        ngx_explicit_memzero(secret, secret_len);
        ngx_free(secret);
    }
    if (dns != NULL) {
        ngx_free(dns);
    }
}

static ngx_int_t
rn_worker_init(rn_main_conf_t *mcf) {
    rn_worker_ctx_t *worker;
    ngx_socket_t udp_fd;
    ngx_connection_t *udp_conn;
    int udp_family;
    char *dns;
    char *secret;
    int rc;

    if (mcf == NULL) {
        return NGX_ERROR;
    }
    if (mcf->worker != NULL) {
        return NGX_OK;
    }

    worker = ngx_alloc(sizeof(rn_worker_ctx_t), ngx_cycle->log);
    if (worker == NULL) {
        return NGX_ERROR;
    }
    ngx_memzero(worker, sizeof(*worker));
    worker->udp_fd = (ngx_socket_t) -1;
    worker->udp_family = AF_UNSPEC;
    worker->log = ngx_cycle->log;
    worker->resolver = mcf->resolver;
    worker->resolver_timeout = mcf->resolver_timeout;
    worker->debug = mcf->debug;
#if (RN_TEST_FAULT_INJECTION)
    worker->test_fault = mcf->test_fault;
#endif
    worker->rebind_event.handler = rn_rebind_handler;
    worker->rebind_event.data = worker;
    worker->rebind_event.log = worker->log;
    worker->rebind_event.cancelable = 1;

    if (mcf->bind_socklen != 0) {
        ngx_memcpy(&worker->bind_sockaddr, &mcf->bind_sockaddr,
            mcf->bind_socklen);
        worker->bind_socklen = mcf->bind_socklen;
    }

    worker->io_ops.ctx = worker;
    worker->io_ops.udp_send = rn_udp_send;
    worker->io_ops.now_ms = rn_now_ms;
    worker->io_ops.log = rn_log;
    worker->io_ops.on_steering_feedback = rn_on_steering_feedback;

    worker->resolver_ops.ctx = worker;
    worker->resolver_ops.resolve_srv = rn_resolve_srv;
    worker->resolver_ops.resolve_addrs = rn_resolve_addrs;
    worker->resolver_ops.cancel = rn_resolve_cancel;

    ngx_memzero(&worker->client_cfg, sizeof(worker->client_cfg));
    dns = NULL;
    secret = NULL;
    dns = rn_dns_alloc(worker, mcf->tenant_dns.len + 1,
        "worker-tenant");
    if (dns == NULL) {
        goto failed;
    }
    ngx_memcpy(dns, mcf->tenant_dns.data, mcf->tenant_dns.len);
    dns[mcf->tenant_dns.len] = '\0';
    worker->client_cfg.tenant.dns_name = dns;
    worker->client_cfg.tenant.key_id = mcf->key_id;

    worker->client_cfg.tenant.auth.type = mcf->auth_type;
    if (mcf->auth_key.len > 0) {
        secret = rn_dns_alloc(worker, mcf->auth_key.len + 1,
            "worker-secret");
        if (secret == NULL) {
            goto failed;
        }
        ngx_memcpy(secret, mcf->auth_key.data, mcf->auth_key.len);
        secret[mcf->auth_key.len] = '\0';
        worker->client_cfg.tenant.auth.secret = secret;
        worker->client_cfg.tenant.auth.secret_len = mcf->auth_key.len;
    } else {
        worker->client_cfg.tenant.auth.secret = NULL;
        worker->client_cfg.tenant.auth.secret_len = 0;
    }

    worker->policy = mcf->request_policy;
    worker->client_cfg.request_policy = &worker->policy;

    if (worker->debug) {
        uint32_t horizon_ms = 0;

        (void) rn_policy_horizon_ms(&worker->policy, UINT32_MAX,
            &horizon_ms);
        ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
            "rn: client cfg key_id=%uL auth=%s tenant=%V policy=%s "
            "unit_ms=%uL replays=%uD final_wait_units=%uD "
            "completion_delivery=%s horizon_ms=%uD",
            (unsigned long) mcf->key_id, rn_auth_type_name(mcf->auth_type),
            &mcf->tenant_dns, rn_policy_kind_name(mcf->request_policy_kind),
            (unsigned long) worker->policy.unit_ms,
            worker->policy.replay_count, worker->policy.final_receive_units,
            worker->policy.completion_delivery ? "on" : "off", horizon_ms);
    }

    if (rn_open_socket_candidate(worker, &udp_fd, &udp_family, &udp_conn)
        != NGX_OK)
    {
        goto failed;
    }
    worker->udp_fd = udp_fd;
    worker->udp_family = udp_family;
    worker->udp_conn = udp_conn;

#if (RN_TEST_FAULT_INJECTION)
    if (rn_test_fault_active(worker, "client-create")) {
        rc = RCLIENT_ERR_CONFIG;
    } else
#endif
    {
        rc = r_client_create(&worker->client_cfg, &worker->io_ops,
            &worker->resolver_ops, &worker->client);
    }
    if (rc != RCLIENT_OK) {
        ngx_log_error(NGX_LOG_WARN, worker->log, 0,
            "rn: r_client_create failed rc=%d tenant=%V key_id=%uL auth=%s",
            rc, &mcf->tenant_dns, (unsigned long) mcf->key_id,
            rn_auth_type_name(mcf->auth_type));
        goto failed;
    }
#if (RN_TEST_FAULT_INJECTION)
    if (rn_test_fault_active(worker, "post-client-create")) {
        goto failed;
    }
#endif

    rn_worker_release_config_buffers(worker, dns, secret,
        mcf->auth_key.len + (secret != NULL ? 1 : 0));
    mcf->worker = worker;
    return NGX_OK;

failed:
    rn_worker_release_config_buffers(worker, dns, secret,
        mcf->auth_key.len + (secret != NULL ? 1 : 0));
    rn_worker_cleanup(worker);
    ngx_free(worker);
    return NGX_ERROR;
}

static ngx_int_t
rn_worker_ensure(rn_main_conf_t *mcf)
{
    ngx_msec_t delay;

    if (mcf == NULL) {
        return NGX_ERROR;
    }
    if (mcf->worker != NULL) {
        return NGX_OK;
    }
    if (mcf->init_retry_at != 0
        && (ngx_msec_int_t) (mcf->init_retry_at - ngx_current_msec) > 0)
    {
        return NGX_AGAIN;
    }

    mcf->init_retry_at = 0;
    if (rn_worker_init(mcf) == NGX_OK) {
        mcf->init_retry_delay = 0;
        return NGX_OK;
    }

    delay = mcf->init_retry_delay;
    if (delay == 0) {
        delay = RN_INIT_RETRY_INITIAL_MS;
    }
    mcf->init_retry_at = ngx_current_msec + delay;
    mcf->init_retry_delay = delay < RN_INIT_RETRY_MAX_MS / 2
        ? delay * 2 : RN_INIT_RETRY_MAX_MS;
    ngx_log_error(NGX_LOG_WARN, ngx_cycle->log, 0,
        "rn: worker initialization failed; retrying after %Mms", delay);
    return NGX_ERROR;
}

static void
rn_exit_process(ngx_cycle_t *cycle) {
    rn_main_conf_t *mcf;
    rn_worker_ctx_t *worker;

    mcf = ngx_http_cycle_get_module_main_conf(cycle, ngx_http_rn_module);
    if (mcf == NULL || mcf->worker == NULL) {
        return;
    }
    worker = mcf->worker;
    mcf->worker = NULL;
    rn_worker_cleanup(worker);
    ngx_free(worker);
}

static void
rn_schedule_rebind(rn_worker_ctx_t *worker) {
    rn_schedule_rebind_after(worker, 0);
}

static void
rn_schedule_rebind_after(rn_worker_ctx_t *worker, ngx_msec_t delay) {
    if (worker == NULL || !worker->rebind_pending || worker->inflight != 0
        || worker->rebind_scheduled)
    {
        return;
    }

    worker->rebind_scheduled = 1;
    ngx_add_timer(&worker->rebind_event, delay);
}

static void
rn_rebind_handler(ngx_event_t *ev) {
    rn_worker_ctx_t *worker;

    if (ev == NULL || ev->data == NULL) {
        return;
    }
    worker = ev->data;
    worker->rebind_scheduled = 0;

    if (!worker->rebind_pending || worker->inflight != 0) {
        return;
    }
    if (worker->udp_read_active) {
        rn_schedule_rebind_after(worker, 1);
        return;
    }

    if (rn_rebind_socket(worker) != NGX_OK) {
        ngx_log_error(NGX_LOG_WARN, worker->log, 0,
            "rn: UDP socket rebind failed; retaining current endpoint and retrying");
        rn_schedule_rebind_after(worker, RN_REBIND_RETRY_MS);
    }
}

static void
rn_udp_read_handler(ngx_event_t *ev) {
    ngx_uint_t received;

    if (ev == NULL || ev->data == NULL) {
        return;
    }
    ngx_connection_t *c = ev->data;
    rn_worker_ctx_t *worker = c->data;
    if (worker == NULL || worker->client == NULL) {
        return;
    }
    worker->udp_read_active = 1;
    received = 0;

    for (;;) {
        u_char buf[2048];
        struct sockaddr_storage sa;
        socklen_t slen = sizeof(sa);
        ssize_t n = recvfrom(c->fd, buf, sizeof(buf), 0,
            (struct sockaddr *) &sa, &slen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                worker->udp_read_active = 0;
                return;
            }
            if (worker->debug) {
                ngx_log_error(NGX_LOG_WARN, worker->log, ngx_socket_errno,
                    "rn: recvfrom failed");
            }
            worker->udp_read_active = 0;
            return;
        }
        if (n == 0) {
            worker->udp_read_active = 0;
            return;
        }
        r_addr_t from;
        ngx_memzero(&from, sizeof(from));
        ngx_memcpy(&from.sa, &sa, slen);
        from.len = slen;
        if (worker->debug) {
            if (n >= 28) {
                uint16_t tlv_type = (uint16_t) (buf[0] | (buf[1] << 8));
                uint16_t tlv_size = (uint16_t) (buf[2] | (buf[3] << 8));
                if (tlv_type == 0x4C52 && tlv_size >= 40 && (size_t) n >= tlv_size) {
                    u_char hex[33];
                    rn_hex16((const uint8_t *)(buf + 12), hex);
                    uint64_t server_id = 0;
                    ngx_memcpy(&server_id, buf + 4, sizeof(server_id));
                    ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                        "rn: recvfrom %z bytes server_id=%uL req_id=%s",
                        n, (unsigned long) server_id, hex);
                } else {
                    ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                        "rn: recvfrom %z bytes", n);
                }
            } else {
                ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                    "rn: recvfrom %z bytes", n);
            }
        }
        (void) r_client_on_datagram(worker->client, buf, (size_t) n, &from);
        received++;
        if (received == RN_UDP_READ_BATCH_MAX) {
            worker->udp_read_active = 0;
            ngx_log_debug1(NGX_LOG_DEBUG_EVENT, worker->log, 0,
                "rn: UDP receive batch exhausted; yielding after %ui datagrams",
                received);
            ngx_post_event(ev, &ngx_posted_next_events);
            return;
        }
    }
}

static void
rn_request_timeout_handler(ngx_event_t *ev) {
    rn_req_ctx_t *ctx;
    rn_worker_ctx_t *worker;
    r_client_req_t *req;
    ngx_http_request_t *r;
    ngx_flag_t completed;
    uint64_t deadline_ms;
    uint64_t now_ms;
    int rc;

    if (ev == NULL || ev->data == NULL) {
        return;
    }
    ctx = ev->data;
    if (ctx == NULL || ctx->worker == NULL || ctx->worker->client == NULL || ctx->req == NULL) {
        return;
    }

    worker = ctx->worker;
    req = ctx->req;
    r = ctx->r;
    now_ms = worker->io_ops.now_ms(worker);
    deadline_ms = 0;
    if (r_client_request_deadline_ms(req, &deadline_ms) == RCLIENT_OK
        && deadline_ms > now_ms)
    {
        ngx_add_timer(&ctx->timer, (ngx_msec_t) (deadline_ms - now_ms));
        return;
    }

    /*
     * A terminal timeout synchronously invokes rn_rate_cb and may release the
     * request pool containing ctx. Observe that callback through stack storage
     * before touching ctx again. Nonterminal round transitions keep the
     * request live and publish a later deadline which must be re-armed.
     */
    completed = 0;
    ctx->timeout_completed = &completed;
    rc = r_client_on_timeout(worker->client, req, now_ms);
    if (completed) {
        return;
    }
    ctx->timeout_completed = NULL;

    if (rc != RCLIENT_OK) {
        r_client_cancel_request(worker->client, req);
        rn_rate_cb(r, req, rc, NULL);
        return;
    }
    deadline_ms = 0;
    if (r_client_request_deadline_ms(req, &deadline_ms) != RCLIENT_OK) {
        r_client_cancel_request(worker->client, req);
        rn_rate_cb(r, req, RCLIENT_ERR_CONFIG, NULL);
        return;
    }
    now_ms = worker->io_ops.now_ms(worker);
    ngx_add_timer(&ctx->timer, deadline_ms > now_ms
        ? (ngx_msec_t) (deadline_ms - now_ms) : 0);
}

static void
rn_request_teardown(rn_req_ctx_t *ctx, r_client_req_t *completed_req,
    ngx_flag_t cancel)
{
    rn_worker_ctx_t *worker;
    r_client_req_t *owned_req;

    /* This is the only function that releases asynchronous request
     * ownership. Every flag is cleared even when teardown is called twice. */
    if (ctx == NULL) {
        return;
    }
    worker = ctx->worker;
    owned_req = ctx->req;

    if (!cancel && owned_req != completed_req) {
        return;
    }
    if (ctx->timer.timer_set) {
        ngx_del_timer(&ctx->timer);
    }

    ctx->req = NULL;
    if (cancel && owned_req != NULL && worker != NULL && worker->client != NULL) {
        r_client_cancel_request(worker->client, owned_req);
    }

    if (ctx->inflight_counted) {
        if (worker != NULL && worker->inflight > 0) {
            worker->inflight--;
        }
        ctx->inflight_counted = 0;
    }
    if (ctx->nginx_counted) {
        if (ctx->r != NULL && ctx->r->main != NULL && ctx->r->main->count > 0) {
            ctx->r->main->count--;
        }
        ctx->nginx_counted = 0;
    }
    ctx->waiting = 0;

    rn_schedule_rebind(worker);
}

static void
rn_request_cleanup(void *data) {
    rn_req_ctx_t *ctx = data;
    if (ctx != NULL) {
        if (ctx->admission_outcome == RN_ADMISSION_WAITING) {
            ctx->admission_outcome = RN_ADMISSION_ABORTED;
            ctx->completion_cause = RN_COMPLETION_CLIENT_ABORT;
        }
        rn_request_teardown(ctx, NULL, 1);
        ctx->r = NULL;
    }
}

static ngx_int_t
ngx_http_rn_log_handler(ngx_http_request_t *r) {
    rn_req_ctx_t *ctx;
    rn_worker_ctx_t *worker;
    ngx_time_t *tp;
    uint64_t start_ms;
    uint64_t end_ms;
    uint64_t observed;
    size_t i;
    int rc;

    if (r == NULL || r != r->main) {
        return NGX_OK;
    }

    ctx = ngx_http_get_module_ctx(r, ngx_http_rn_module);
    if (ctx == NULL || !ctx->lat_report_enabled || ctx->lat_report_sent) {
        return NGX_OK;
    }
    if (r->connection == NULL || r->connection->timedout
        || r->connection->error || r->connection->destroyed)
    {
        ctx->admission_outcome = RN_ADMISSION_ABORTED;
        ctx->completion_cause = RN_COMPLETION_CLIENT_ABORT;
        ctx->lat_report_sent = 1;
        return NGX_OK;
    }
    if (ctx->admission_outcome != RN_ADMISSION_VALID_ALLOW
        || ctx->lat_reports == NULL || ctx->lat_report_count == 0)
    {
        ctx->lat_report_sent = 1;
        return NGX_OK;
    }

    worker = ctx->worker;
    if (worker == NULL || worker->client == NULL) {
        ctx->lat_report_sent = 1;
        return NGX_OK;
    }

    tp = ngx_timeofday();
    if (tp == NULL) {
        ctx->lat_report_sent = 1;
        return NGX_OK;
    }

    start_ms = (uint64_t) r->start_sec * 1000u + (uint64_t) r->start_msec;
    end_ms = (uint64_t) tp->sec * 1000u + (uint64_t) tp->msec;
    observed = (end_ms > start_ms) ? (end_ms - start_ms) : 0;
    if (observed == 0) {
        /* Avoid 0ms samples; they make strict 1ms guards trivially pass. */
        observed = 1;
    }
    if (observed > 0xFFFFFFFFu) {
        observed = 0xFFFFFFFFu;
    }

    for (i = 0; i < ctx->lat_report_count; i++) {
        ctx->lat_reports[i].observed_latency = (uint32_t) observed;
    }

    rc = r_client_report_latency(worker->client, ctx->lat_reports, ctx->lat_report_count);
    if (worker->debug) {
        ngx_uint_t lvl = (rc == RCLIENT_OK) ? NGX_LOG_DEBUG : NGX_LOG_WARN;
        ngx_log_error(lvl, worker->log, 0,
            "rn: latency_report count=%uz observed_ms=%uL rc=%d",
            ctx->lat_report_count, (unsigned long) observed, rc);
    }
    ctx->lat_report_sent = 1;
    return NGX_OK;
}

static void
rn_rate_cb(void *user, r_client_req_t *req, int status, const r_rate_limit_result_t *result) {
    ngx_http_request_t *r = user;
    ngx_connection_t *c;
    if (r == NULL) {
        return;
    }
    c = r->connection;
    if (c == NULL) {
        return;
    }
    rn_req_ctx_t *ctx = ngx_http_get_module_ctx(r, ngx_http_rn_module);
    rn_main_conf_t *mcf = ngx_http_get_module_main_conf(r, ngx_http_rn_module);
    rn_worker_ctx_t *worker;
    if (ctx == NULL || ctx->worker == NULL) {
        return;
    }
    worker = ctx->worker;
    if (ctx->req != req) {
        ngx_log_error(NGX_LOG_ALERT, worker->log, 0,
            "rn: completion callback does not own the active request");
        return;
    }
    if (ctx->timeout_completed != NULL) {
        *ctx->timeout_completed = 1;
        ctx->timeout_completed = NULL;
    }
    rn_request_teardown(ctx, req, 0);

    ngx_int_t rc;
    ngx_flag_t cardinality_mismatch = 0;
    if (status == RCLIENT_OK && result
        && (result->guard_count != ctx->expected_guard_count
            || result->resource_count != ctx->expected_resource_count))
    {
        cardinality_mismatch = 1;
        ngx_log_error(NGX_LOG_WARN, worker->log, 0,
            "rn: response_cardinality_mismatch expected_guards=%uz "
            "actual_guards=%uz expected_resources=%uz actual_resources=%uz "
            "fail_open=%d",
            ctx->expected_guard_count, result->guard_count,
            ctx->expected_resource_count, result->resource_count,
            (int) (mcf && mcf->fail_open));
        rc = (mcf && mcf->fail_open) ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
        ctx->admission_outcome = (mcf && mcf->fail_open)
            ? RN_ADMISSION_FAIL_OPEN : RN_ADMISSION_FAIL_CLOSE;
        ctx->completion_cause = RN_COMPLETION_CARDINALITY_MISMATCH;

    } else if (status == RCLIENT_OK && result) {
        ngx_flag_t allow = result->success ? 1 : 0;
        size_t i;

        if (allow) {
            for (i = 0; i < result->guard_count; i++) {
                if (!result->guards[i].passed) {
                    allow = 0;
                    break;
                }
            }
        }
        if (allow) {
            for (i = 0; i < result->resource_count; i++) {
                if (result->resources[i].tokens_deficit != 0) {
                    allow = 0;
                    break;
                }
            }
        }
        rc = allow ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
        ctx->admission_outcome = allow
            ? RN_ADMISSION_VALID_ALLOW : RN_ADMISSION_VALID_DENY;
        ctx->completion_cause = RN_COMPLETION_VALID_VERDICT;
    } else {
        rc = (mcf && mcf->fail_open) ? NGX_OK : NGX_HTTP_TOO_MANY_REQUESTS;
        ctx->admission_outcome = (mcf && mcf->fail_open)
            ? RN_ADMISSION_FAIL_OPEN : RN_ADMISSION_FAIL_CLOSE;
        ctx->completion_cause = (status == RCLIENT_ERR_TIMEOUT)
            ? RN_COMPLETION_TIMEOUT : RN_COMPLETION_DEPENDENCY_ERROR;
    }
    if (worker->debug && !cardinality_mismatch) {
        if (status == RCLIENT_OK && result) {
            ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                "rn: result success=%d server_id=%uL",
                result->success ? 1 : 0, (unsigned long) result->server_id);
        } else {
            ngx_log_error(NGX_LOG_DEBUG, worker->log, 0,
                "rn: result error status=%d", status);
        }
    }

    ctx->decision = rc;
    ctx->done = 1;
    ctx->waiting = 0;

    /*
     * Resume phase processing directly. Finalizing with NGX_DECLINED clears
     * r->content_handler, which breaks content handlers installed by other
     * directives such as proxy_pass. This callback runs from the module's UDP
     * event rather than nginx's request event handler, so it must also perform
     * the posted-request drain normally done by ngx_http_request_handler().
     * Keep only the connection pointer across phase processing because the
     * request itself may be finalized and released there.
     */
    r->write_event_handler = ngx_http_core_run_phases;
    ngx_http_core_run_phases(r);
    ngx_http_run_posted_requests(c);
}

static void
rn_hex16(const uint8_t in[16], u_char out[33]) {
    static const u_char *hex = (u_char *)"0123456789abcdef";
    for (ngx_uint_t i = 0; i < 16; i++) {
        out[i * 2] = hex[(in[i] >> 4) & 0x0f];
        out[i * 2 + 1] = hex[in[i] & 0x0f];
    }
    out[32] = '\0';
}

static void
rn_hex_id(const uint8_t in[16], u_char out[33]) {
    rn_hex16(in, out);
}
