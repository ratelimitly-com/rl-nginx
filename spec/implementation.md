# Implementation constraints

This document defines conformance boundaries for the nginx-module and
`rl-c-client` integration. It records implemented constraints, not proposed
architecture.

## nginx phase integration

The module MUST register:

- an HTTP access-phase handler for protected-request checks; and
- an HTTP log-phase handler for post-response guard latency reports.

The access handler MUST return `NGX_DECLINED` for unprotected locations and for
a fail-open runtime failure, `NGX_AGAIN` while an asynchronous check owns the
request, `429` for a valid deny or fail-close runtime failure, and `500` for
the internal nginx failures identified in [Request behavior](behavior.md).

Configuration definitions, credentials, timeout, failure policy, bind address,
and debug flag live in HTTP main configuration. Effective rules and labels
live in location configuration and follow the inheritance contract in
[Configuration DSL](dsl.md).

## Worker lifecycle and non-blocking I/O

Each nginx worker owns at most one module C client and UDP socket. They are
created lazily on that worker's first protected request and destroyed on worker
exit. The UDP socket uses an ephemeral source port and the configured local
address, if any.

UDP send/receive, timers, source-port rebinds, and DNS resolution MUST use nginx
event-loop facilities. Blocking socket or resolver calls are forbidden on the
request path. DNS SRV and address callbacks MUST release their temporary nginx
resolver contexts and allocation buffers on success, failure, and cancellation.

The resolver adapter MUST preserve SRV target port, server-ID association, and
TTL information when converting nginx resolver answers into C-client records.
The C client owns endpoint caching, refresh scheduling, supported SRV
discovery, and its explicitly unsupported compatibility fallback described in
[Request behavior](behavior.md#discovery-dispatch-and-selection).

## C-client dependency boundary

Supported builds MUST use the repository, tag, and full commit recorded in
`dependencies/rl-c-client.env`. Default build and test entrypoints MUST fetch
or verify that revision under `./_deps/rl-c-client`; they MUST NOT select an
adjacent checkout implicitly. An intentional development or packaging override
MUST set `RCLIENT_DIR=/path/to/rl-c-client` explicitly.

The module MUST use the C client as the owner of protocol encoding, encryption,
authentication, request IDs, DNS policy, multi-endpoint dispatch, response
selection, and decoding. It MUST NOT duplicate those implementations.

For rate checks, the module MUST use
`r_client_check_rate_limit_async_borrowed`. The module MUST start from
`r_client_default_request_policy`, set `attempt_timeout_ms` from
`ratelimitly_timeout`, and set `retry.retry_attempts = 0`. Any change to other
locked policy behavior is a dependency-lock change requiring corresponding
specification and test review.

For post-response reports, the module MUST use `r_client_report_latency` and
MUST treat its result as observability only.

## Request ownership

Arrays and strings passed to the borrowed C-client API are owned by the nginx
request pool. A per-request context MUST retain the owning nginx request,
C-client request handle, deadline timer, expected response cardinality, latency
report inputs, and exactly-once accounting flags.

Once the asynchronous request starts, the module MUST increment both nginx main
request accounting and worker in-flight accounting. Completion, cancellation,
or cleanup MUST use one teardown path that:

1. verifies callback ownership when completing normally;
2. removes the active timer;
3. cancels the C-client request when required;
4. clears the request handle;
5. decrements each accounting value at most once; and
6. schedules a pending safe source-port rebind.

The timeout path MUST honor a later C-client deadline when reported. With
retries disabled, `r_client_on_timeout` can synchronously invoke the completion
callback and release the nginx request pool, so that call MUST be the last
access through the request context.

An aborted HTTP client MUST execute the cleanup path without a later timeout
callback, double decrement, use-after-free, or worker loss.

## Response and phase resumption

The callback MUST reject a result whose guard/resource cardinality differs from
the request. It MUST inspect the complete exact-cardinality arrays before
deciding. Callback-owned result arrays MUST NOT be retained after the callback.

After recording the decision, the callback MUST resume nginx phase processing
through `ngx_http_core_run_phases`. It MUST preserve content handlers installed
by directives such as `proxy_pass` and MUST NOT finalize an allow in a way that
clears them.

## Steering safety

The C-client steering callback MAY only mark the worker rebind pending and
schedule it. The rebind handler MUST require worker in-flight count zero and
MUST defer again while the UDP read callback is active. Socket replacement
inside the read callback or while another RateLimitly request is active is
forbidden.

## Error and logging boundary

Configuration errors MUST fail `nginx -t`/configuration loading. Runtime
decision failures MUST follow `ratelimitly_fail`, except that internal nginx
allocation and event errors MAY return `500`. Latency-report failure MUST NOT
change the request status.

Normal operational observability is log-based. Debug decision/discovery output
requires both `ratelimitly_debug on` and an nginx build/log configuration that
records debug messages. Logs MUST NOT include the full authentication secret.
The module does not implement a metrics exporter or health endpoint.

## Conformance tests

The required public gate MUST cover at least:

- directive parsing, defaults, inheritance, and invalid configuration;
- dependency bootstrap, lock verification, and immutable workflow pins;
- SRV target conversion and strict public DNS fixture behavior;
- allow/deny, outage policy, malformed response, and exact-cardinality cases;
- guard decisions and post-response latency-report suppression after denial;
- timeout, aborted client, source-port steering, reload, and shutdown lifecycle;
- missing SRV, invalid SRV target, DNS timeout, and same-worker recovery;
- dynamic-module relocation; and
- whitespace and script syntax.

ASan/UBSan lifecycle runs MUST additionally exercise repeated timeout,
cancellation, steering, reload, and shutdown behavior. Optional internal
full-stack validation is not part of the public conformance boundary.
