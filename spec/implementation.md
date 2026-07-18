# Implementation constraints

This document defines conformance boundaries for the nginx-module and
`rl-c-client` integration. It records implemented constraints, not proposed
architecture.

## nginx phase integration

The module MUST register:

- the final HTTP pre-content-phase handler for protected-request checks; and
- an HTTP log-phase handler for post-response guard latency reports.

nginx executes the handlers within a phase in reverse registration order. The
module MUST therefore place its pre-content handler at index zero of the phase
handler array. All other pre-content routing and preparation handlers then run
before RateLimitly, and a RateLimitly allow is the final transition into content
processing. This ordering MUST work for both static and dynamic module builds.

The pre-content handler MUST return `NGX_DECLINED` for unprotected locations
and subrequests, `NGX_OK` for a valid allow or fail-open runtime failure,
`NGX_AGAIN` while an asynchronous check owns the request, `429` for a valid
deny or fail-close runtime failure, and `500` for the internal nginx failures
identified in [Request behavior](behavior.md). `NGX_OK` deliberately skips any
unexpected later pre-content handler and advances directly to content.

Configuration definitions, credentials, timeout, failure policy, bind address,
and debug flag live in HTTP main configuration. Effective rules and labels
live in location configuration and follow the inheritance contract in
[Configuration DSL](dsl.md).

## Worker lifecycle and non-blocking I/O

Each nginx worker owns at most one module C client and UDP socket. They are
created lazily on that worker's first protected request and destroyed on worker
exit. The UDP socket uses an ephemeral source port and the configured local
address, if any.

Worker initialization MUST publish the worker through main configuration only
after the socket, nginx connection, and C client are all usable. Temporary
tenant and credential copies MUST be released after `r_client_create`, which
copies them. Every partial initialization failure MUST use the same idempotent
cleanup path. Worker cleanup MUST destroy the C client while its resolver and
UDP adapter context is still live, then close the nginx UDP connection exactly
once.

UDP send/receive, timers, source-port rebinds, and DNS resolution MUST use nginx
event-loop facilities. Blocking socket or resolver calls are forbidden on the
request path. DNS SRV and address callbacks MUST release their temporary nginx
resolver contexts and allocation buffers on success, failure, and cancellation.
The adapter MUST allow nginx to invoke a resolver callback synchronously from
`ngx_resolve_name`. It MUST publish a nonzero cancellation ID only for a live
pending lookup. A failure before resolver submission MUST release the live
context; an `NGX_ERROR` result MUST return failure without touching the context
that nginx has already released. Cancellation MUST detach the nginx callback,
cancel the live resolver context, and complete the C-client callback once so
the client can retire its lookup state.

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

nginx clears module-context slots during an internal redirect but preserves the
main request pool and cleanup chain. The module MUST keep its admission context
reachable through that request-lifetime owner and restore the module-context
slot when phases restart. A completed or waiting admission MUST be reused; an
internal redirect MUST NOT construct or send a second rate request.

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
forbidden. Rebinding MUST open and register a candidate endpoint before
publishing it and closing the old endpoint. Candidate failure MUST retain the
working endpoint, leave rebinding pending, and schedule a bounded retry.

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
cancellation, steering, reload, and shutdown behavior. A test-only build MUST
inject every module-owned resolver allocation failure, resolver-start failure,
partial worker-initialization failure, C-client creation failure, and candidate
rebind failure. It MUST verify same-worker survival, stable socket counts,
transactional rebind retention, and clean shutdown. Optional internal full-stack
validation is not part of the public conformance boundary.
