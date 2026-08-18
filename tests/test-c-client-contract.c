#include <arpa/inet.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "r_client.h"
#include "r_test_responder.h"

typedef enum {
    RESOLVER_SYNCHRONOUS = 0,
    RESOLVER_PENDING = 1,
} resolver_mode_t;

typedef struct {
    resolver_mode_t resolver_mode;
    bool fail_send;
    uint64_t now_ms;
    uint8_t packet[2048];
    size_t packet_len;
    size_t send_count;
    size_t rate_callback_count;
    int rate_status;
    r_client_req_t *expected_request;
    bool callback_request_matched;
    bool callback_had_result;
    size_t callback_resource_count;
    size_t callback_guard_count;
    r_dns_srv_cb pending_srv_callback;
    void *pending_srv_user;
    r_dns_req_id_t pending_srv_id;
    size_t cancel_count;
    size_t synchronous_cancel_callback_count;
} fixture_t;

static int
check(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL C-client contract: %s\n", message);
        return 1;
    }
    return 0;
}

static int
capture_send(void *user, const r_addr_t *to, const uint8_t *buf, size_t len)
{
    fixture_t *fixture = user;

    (void) to;
    if (fixture->fail_send || len > sizeof(fixture->packet)) {
        return -1;
    }
    memcpy(fixture->packet, buf, len);
    fixture->packet_len = len;
    fixture->send_count++;
    return 0;
}

static uint64_t
fixture_now_ms(void *user)
{
    fixture_t *fixture = user;

    return fixture->now_ms;
}

static int
resolve_srv(void *user, const char *name, r_dns_req_id_t *out_req_id,
    r_dns_srv_cb callback, void *callback_user)
{
    fixture_t *fixture = user;

    if (strcmp(name, "_ratelimitly._udp.contract.example.invalid") != 0) {
        return RCLIENT_ERR_DNS;
    }
    if (fixture->resolver_mode == RESOLVER_PENDING) {
        fixture->pending_srv_callback = callback;
        fixture->pending_srv_user = callback_user;
        fixture->pending_srv_id = 101u;
        if (out_req_id != NULL) {
            *out_req_id = fixture->pending_srv_id;
        }
        return RCLIENT_OK;
    }

    r_srv_record_t record = {
        .target = "s-1.localhost",
        .port = 39080u,
        .priority = 0u,
        .weight = 0u,
        .ttl_ms = 60000u,
    };
    callback(callback_user, RCLIENT_OK, &record, 1u);
    return RCLIENT_OK;
}

static int
resolve_addrs(void *user, const char *name, r_dns_req_id_t *out_req_id,
    r_dns_addr_cb callback, void *callback_user)
{
    fixture_t *fixture = user;
    r_addr_t address;
    struct sockaddr_in *ipv4;

    (void) out_req_id;
    if (fixture->resolver_mode != RESOLVER_SYNCHRONOUS
        || strcmp(name, "s-1.localhost") != 0)
    {
        return RCLIENT_ERR_DNS;
    }
    memset(&address, 0, sizeof(address));
    ipv4 = (struct sockaddr_in *) &address.sa;
    ipv4->sin_family = AF_INET;
    ipv4->sin_port = htons(39080u);
    if (inet_pton(AF_INET, "127.0.0.1", &ipv4->sin_addr) != 1) {
        return RCLIENT_ERR_DNS;
    }
    address.len = sizeof(*ipv4);
    callback(callback_user, RCLIENT_OK, &address, 1u);
    return RCLIENT_OK;
}

static void
cancel_resolve(void *user, r_dns_req_id_t request_id)
{
    fixture_t *fixture = user;
    r_dns_srv_cb callback;
    void *callback_user;

    fixture->cancel_count++;
    if (request_id != fixture->pending_srv_id
        || fixture->pending_srv_callback == NULL)
    {
        return;
    }
    callback = fixture->pending_srv_callback;
    callback_user = fixture->pending_srv_user;
    fixture->pending_srv_callback = NULL;
    fixture->pending_srv_user = NULL;
    callback(callback_user, RCLIENT_ERR_DNS, NULL, 0u);
    fixture->synchronous_cancel_callback_count++;
}

static void
rate_callback(void *user, r_client_req_t *request, int status,
    const r_rate_limit_result_t *result)
{
    fixture_t *fixture = user;

    fixture->rate_callback_count++;
    fixture->rate_status = status;
    fixture->callback_request_matched = request == fixture->expected_request;
    fixture->callback_had_result = result != NULL;
    if (result != NULL) {
        fixture->callback_resource_count = result->resource_count;
        fixture->callback_guard_count = result->guard_count;
    }
}

static r_client_t *
create_client(fixture_t *fixture)
{
    char auth_key[192];
    char dns_name[64];
    r_auth_key_info_t key_info;
    r_io_ops_t io;
    r_resolver_ops_t resolver;
    r_request_policy_t policy;
    r_client_config_t config;
    r_client_t *client = NULL;
    size_t auth_len = strlen(R_TEST_RESPONDER_AES_KEY);

    if (auth_len + 1u > sizeof(auth_key)) {
        return NULL;
    }
    memcpy(auth_key, R_TEST_RESPONDER_AES_KEY, auth_len + 1u);
    memcpy(dns_name, "contract.example.invalid",
        sizeof("contract.example.invalid"));
    memset(&key_info, 0, sizeof(key_info));
    if (r_client_parse_auth_key(auth_key, &key_info) != RCLIENT_OK) {
        return NULL;
    }
    if (key_info.format_version != 1u
        || key_info.rate_window_size_ms_max != UINT32_MAX)
    {
        return NULL;
    }

    memset(&io, 0, sizeof(io));
    io.ctx = fixture;
    io.udp_send = capture_send;
    io.now_ms = fixture_now_ms;

    memset(&resolver, 0, sizeof(resolver));
    resolver.ctx = fixture;
    resolver.resolve_srv = resolve_srv;
    resolver.resolve_addrs = resolve_addrs;
    resolver.cancel = cancel_resolve;

    r_client_default_request_policy(&policy);
    policy.unit_ms = 25u;

    memset(&config, 0, sizeof(config));
    config.tenant.dns_name = dns_name;
    config.tenant.key_id = key_info.key_id;
    config.tenant.auth.type = key_info.type;
    config.tenant.auth.secret = auth_key;
    config.tenant.auth.secret_len = auth_len;
    config.request_policy = &policy;

    if (r_client_create(&config, &io, &resolver, &client) != RCLIENT_OK) {
        return NULL;
    }

    /* rl-nginx releases these borrowed create-time inputs immediately. */
    memset(auth_key, 0xa5, sizeof(auth_key));
    memset(dns_name, 0xa5, sizeof(dns_name));
    memset(&policy, 0xa5, sizeof(policy));
    memset(&config, 0xa5, sizeof(config));
    return client;
}

static void
fill_guard(r_latency_guard_t *guard)
{
    memset(guard, 0, sizeof(*guard));
    memcpy(guard->latency_tracker_id, "contract-service", 16u);
    guard->threshold_ms = 50u;
    guard->ttl_ms = 1000u;
    guard->max_samples = 10u;
    guard->buffer_size = 16u;
    guard->min_sample_threshold = 1u;
}

static void
fill_request(r_resource_request_t *resource, r_latency_guard_t *guard,
    char label[16])
{
    memset(resource, 0, sizeof(*resource));
    memcpy(resource->bucket_id, "contract-bucket", 15u);
    resource->window_size_ms = 1000u;
    resource->rate_limit = 10u;
    resource->tokens_requested = 1u;

    fill_guard(guard);
    memcpy(label, "contract-label", sizeof("contract-label"));
}

static int
submit_borrowed(r_client_t *client, fixture_t *fixture,
    r_resource_request_t *resource, r_latency_guard_t *guard, char label[16],
    r_client_req_t **out_request)
{
    return r_client_check_rate_limit_async_borrowed(client, resource, 1u,
        guard, 1u, label, 0u, rate_callback, fixture, out_request);
}

static int
build_response(fixture_t *fixture, uint8_t response[1200],
    size_t *response_len)
{
    r_test_responder_state_t responder;
    r_test_event_t event;
    bool send_response = false;

    if (r_test_responder_init(&responder, R_TEST_SCENARIO_ALLOW,
            R_TEST_RESPONDER_AES_KEY, 1u, true, 1u) != RCLIENT_OK)
    {
        return 1;
    }
    if (r_test_responder_process(&responder, fixture->packet,
            fixture->packet_len, response, 1200u, response_len,
            &send_response, &event) != RCLIENT_OK)
    {
        return 1;
    }
    return send_response && event.kind == R_TEST_EVENT_RATE_REQUEST ? 0 : 1;
}

static void
fill_source(r_addr_t *source)
{
    struct sockaddr_in *ipv4;

    memset(source, 0, sizeof(*source));
    ipv4 = (struct sockaddr_in *) &source->sa;
    ipv4->sin_family = AF_INET;
    ipv4->sin_port = htons(39080u);
    (void) inet_pton(AF_INET, "127.0.0.1", &ipv4->sin_addr);
    source->len = sizeof(*ipv4);
}

static int
test_success_callback(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_resource_request_t resource;
    r_latency_guard_t guard;
    char label[16];
    r_client_req_t *request = NULL;
    uint8_t response[1200];
    size_t response_len = 0u;
    r_addr_t source;
    r_client_t *client = create_client(&fixture);
    int start_status;

    fill_request(&resource, &guard, label);
    start_status = client == NULL ? RCLIENT_ERR_CONFIG
        : submit_borrowed(client, &fixture, &resource, &guard, label,
            &request);
    if (start_status != RCLIENT_OK) {
        fprintf(stderr, "C-client start status: %d\n", start_status);
    }
    if (check(client != NULL, "could not create synchronous fixture")
        || check(start_status == RCLIENT_OK,
            "valid borrowed start failed")
        || check(request != NULL, "valid start did not publish a request handle")
        || check(fixture.rate_callback_count == 0u,
            "start invoked the completion callback synchronously")
        || check(build_response(&fixture, response, &response_len) == 0,
            "could not build a valid response"))
    {
        r_client_destroy(client);
        return 1;
    }

    fixture.expected_request = request;
    fill_source(&source);
    if (check(r_client_on_datagram(client, response, response_len, &source)
            == RCLIENT_OK,
            "valid response was rejected")
        || check(fixture.rate_callback_count == 1u,
            "valid response did not complete exactly once")
        || check(fixture.rate_status == RCLIENT_OK
            && fixture.callback_request_matched
            && fixture.callback_had_result,
            "callback status, handle, or result lifetime contract changed")
        || check(fixture.callback_resource_count == 1u
            && fixture.callback_guard_count == 1u,
            "callback result cardinality changed"))
    {
        r_client_destroy(client);
        return 1;
    }

    (void) r_client_on_datagram(client, response, response_len, &source);
    if (check(fixture.rate_callback_count == 1u,
            "late duplicate response invoked a second callback"))
    {
        r_client_destroy(client);
        return 1;
    }
    r_client_destroy(client);
    return 0;
}

static int
test_guard_only_success_callback(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_latency_guard_t guard;
    r_client_req_t *request = NULL;
    uint8_t response[1200];
    size_t response_len = 0u;
    r_addr_t source;
    r_client_t *client = create_client(&fixture);
    int start_status;

    fill_guard(&guard);
    start_status = client == NULL ? RCLIENT_ERR_CONFIG
        : r_client_check_rate_limit_async_borrowed(client, NULL, 0u,
            &guard, 1u, NULL, 0u, rate_callback, &fixture, &request);
    if (check(client != NULL, "could not create guard-only fixture")
        || check(start_status == RCLIENT_OK,
            "valid guard-only borrowed start failed")
        || check(request != NULL,
            "guard-only start did not publish a request handle")
        || check(build_response(&fixture, response, &response_len) == 0,
            "could not build a valid guard-only response"))
    {
        r_client_destroy(client);
        return 1;
    }

    fixture.expected_request = request;
    fill_source(&source);
    if (check(r_client_on_datagram(client, response, response_len, &source)
            == RCLIENT_OK,
            "valid guard-only response was rejected")
        || check(fixture.rate_callback_count == 1u
            && fixture.rate_status == RCLIENT_OK
            && fixture.callback_request_matched
            && fixture.callback_had_result,
            "guard-only callback contract changed")
        || check(fixture.callback_resource_count == 0u
            && fixture.callback_guard_count == 1u,
            "guard-only callback result cardinality changed"))
    {
        r_client_destroy(client);
        return 1;
    }

    r_client_destroy(client);
    return 0;
}

static int
test_start_failure(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_resource_request_t resource;
    r_latency_guard_t guard;
    char label[16];
    r_client_req_t *request = NULL;
    r_client_t *client = create_client(&fixture);

    fill_request(&resource, &guard, label);
    fixture.fail_send = true;
    if (check(client != NULL, "could not create start-failure fixture")
        || check(submit_borrowed(client, &fixture, &resource, &guard, label,
                &request) == RCLIENT_ERR_IO,
            "send failure did not return an immediate error")
        || check(request == NULL, "failed start published a request handle")
        || check(fixture.rate_callback_count == 0u,
            "failed start invoked the completion callback"))
    {
        r_client_destroy(client);
        return 1;
    }
    r_client_destroy(client);
    return 0;
}

static int
test_timeout_completion(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_resource_request_t resource;
    r_latency_guard_t guard;
    char label[16];
    r_client_req_t *request = NULL;
    uint64_t deadline = 0u;
    uint64_t initial_time = fixture.now_ms;
    r_client_t *client = create_client(&fixture);

    fill_request(&resource, &guard, label);
    if (check(client != NULL, "could not create timeout fixture")
        || check(submit_borrowed(client, &fixture, &resource, &guard, label,
                &request) == RCLIENT_OK,
            "timeout fixture request did not start")
        || check(r_client_request_deadline_ms(request, &deadline) == RCLIENT_OK,
            "live request did not expose a deadline")
        || check(deadline == initial_time + 25u,
            "request policy was not copied during client creation"))
    {
        r_client_destroy(client);
        return 1;
    }

    fixture.expected_request = request;
    if (check(r_client_on_timeout(client, request, deadline - 1u) == RCLIENT_OK,
            "early timeout probe failed")
        || check(fixture.rate_callback_count == 0u,
            "early timeout completed the request")
        || check(r_client_on_timeout(client, request, deadline) == RCLIENT_OK,
            "first-round timeout failed")
        || check(fixture.rate_callback_count == 0u
            && fixture.send_count == 2u,
            "first-round timeout did not replay exactly once")
        || check(r_client_request_deadline_ms(request, &deadline) == RCLIENT_OK
            && deadline == initial_time + 50u,
            "replay round did not expose its deadline")
        || check(r_client_on_timeout(client, request, deadline) == RCLIENT_OK,
            "replay-round timeout failed")
        || check(fixture.rate_callback_count == 0u
            && fixture.send_count == 2u,
            "final receive phase sent or completed unexpectedly")
        || check(r_client_request_deadline_ms(request, &deadline) == RCLIENT_OK
            && deadline == initial_time + 75u,
            "final receive phase did not expose its deadline")
        || check(r_client_on_timeout(client, request, deadline) == RCLIENT_OK,
            "final timeout failed")
        || check(fixture.rate_callback_count == 1u
            && fixture.rate_status == RCLIENT_ERR_TIMEOUT
            && fixture.callback_request_matched
            && !fixture.callback_had_result,
            "final deadline did not synchronously complete exactly once"))
    {
        r_client_destroy(client);
        return 1;
    }
    r_client_destroy(client);
    return 0;
}

static int
test_cancel_retires_request(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_resource_request_t resource;
    r_resource_request_t resource_before;
    r_latency_guard_t guard;
    r_latency_guard_t guard_before;
    char label[16];
    char label_before[16];
    r_client_req_t *request = NULL;
    uint8_t response[1200];
    size_t response_len = 0u;
    r_addr_t source;
    r_client_t *client = create_client(&fixture);

    fill_request(&resource, &guard, label);
    resource_before = resource;
    guard_before = guard;
    memcpy(label_before, label, sizeof(label));
    if (check(client != NULL, "could not create cancellation fixture")
        || check(submit_borrowed(client, &fixture, &resource, &guard, label,
                &request) == RCLIENT_OK,
            "cancellation fixture request did not start")
        || check(build_response(&fixture, response, &response_len) == 0,
            "could not build cancellation response"))
    {
        r_client_destroy(client);
        return 1;
    }

    fixture.expected_request = request;
    r_client_cancel_request(client, request);
    fill_source(&source);
    (void) r_client_on_datagram(client, response, response_len, &source);
    if (check(fixture.rate_callback_count == 0u,
            "cancel or a late response invoked the callback")
        || check(memcmp(&resource, &resource_before, sizeof(resource)) == 0
            && memcmp(&guard, &guard_before, sizeof(guard)) == 0
            && memcmp(label, label_before, sizeof(label)) == 0,
            "borrowed request buffers were modified or freed"))
    {
        r_client_destroy(client);
        return 1;
    }
    r_client_destroy(client);
    return check(fixture.rate_callback_count == 0u,
        "destroy invoked a callback for a cancelled request");
}

static int
test_destroy_suppresses_callback(void)
{
    fixture_t fixture = { .now_ms = 1000000u };
    r_resource_request_t resource;
    r_latency_guard_t guard;
    char label[16];
    r_client_req_t *request = NULL;
    r_client_t *client = create_client(&fixture);

    fill_request(&resource, &guard, label);
    if (check(client != NULL, "could not create destroy fixture")
        || check(submit_borrowed(client, &fixture, &resource, &guard, label,
                &request) == RCLIENT_OK,
            "destroy fixture request did not start"))
    {
        r_client_destroy(client);
        return 1;
    }
    fixture.expected_request = request;
    r_client_destroy(client);
    return check(fixture.rate_callback_count == 0u,
        "client destroy completed an inflight rate callback");
}

static int
test_destroy_detaches_resolver(void)
{
    fixture_t fixture = {
        .resolver_mode = RESOLVER_PENDING,
        .now_ms = 1000000u,
    };
    r_resource_request_t resource;
    r_latency_guard_t guard;
    char label[16];
    r_client_req_t *request = NULL;
    r_client_t *client = create_client(&fixture);

    fill_request(&resource, &guard, label);
    if (check(client != NULL, "could not create pending-resolver fixture")
        || check(fixture.pending_srv_callback != NULL,
            "pending resolver did not retain its callback")
        || check(submit_borrowed(client, &fixture, &resource, &guard, label,
                &request) == RCLIENT_ERR_DNS,
            "request without resolved servers did not fail synchronously")
        || check(request == NULL && fixture.rate_callback_count == 0u,
            "DNS start failure published a handle or invoked a callback"))
    {
        r_client_destroy(client);
        return 1;
    }

    r_client_destroy(client);
    return check(fixture.cancel_count == 1u
            && fixture.synchronous_cancel_callback_count == 1u,
        "destroy did not detach before synchronous resolver cancellation");
}

int
main(void)
{
    if (test_success_callback() != 0
        || test_guard_only_success_callback() != 0
        || test_start_failure() != 0
        || test_timeout_completion() != 0
        || test_cancel_retires_request() != 0
        || test_destroy_suppresses_callback() != 0
        || test_destroy_detaches_resolver() != 0)
    {
        return 1;
    }
    puts("PASS locked C-client callback and ownership contract");
    return 0;
}
