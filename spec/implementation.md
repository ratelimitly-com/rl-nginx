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
Unconfigured server and location activation flags MUST merge to `0`, never the
truthy `NGX_CONF_UNSET` sentinel.

The module MUST reject static bucket/service templates over 1024 bytes and
static labels over 256 bytes during configuration loading. The same limits,
plus nonempty bucket and service requirements, MUST be checked after dynamic
rendering and before request-pool copying or C-client invocation. Dynamic
violations follow the configured failure policy.

## Worker lifecycle and non-blocking I/O

Each nginx worker owns at most one module C client and UDP socket. They are
created lazily on that worker's first protected request and destroyed on worker
exit. The UDP socket uses an ephemeral source port and the configured local
address, if any. The local bind address MUST be parsed and validated while
loading configuration, not from each worker-initialization attempt.

The module MUST capture exactly one resolver and `resolver_timeout` from the
`http` context during configuration. A resolver declared only in a server or
location is unsupported and MUST NOT make worker behavior depend on which
location receives the first request. Every SRV and address resolver context
MUST receive the captured timeout before submission.

Worker initialization MUST publish the worker through main configuration only
after the socket, nginx connection, and C client are all usable. Temporary
tenant and credential copies MUST be released after `r_client_create`, which
copies them. Every partial initialization failure MUST use the same idempotent
cleanup path. Worker cleanup MUST destroy the C client while its resolver and
UDP adapter context is still live, then close the nginx UDP connection exactly
once. Failed lazy initialization MUST use bounded exponential backoff; requests
arriving before the next attempt follow the configured failure policy without
allocating another candidate worker.

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
It MUST compact accepted A/AAAA addresses and report only the compacted count;
if every address is unusable, it MUST return resolver failure rather than a
successful array containing zeroed entries.
The C client owns endpoint caching, refresh scheduling, supported SRV
discovery, and its explicitly unsupported compatibility fallback described in
[Request behavior](behavior.md#discovery-dispatch-and-selection).

## C-client dependency boundary

Supported builds MUST use the repository, tag, and full commit recorded in
`dependencies/rl-c-client.env`. Default build and test entrypoints MUST fetch
or verify that revision under `./_deps/rl-c-client`; they MUST NOT select an
adjacent checkout implicitly. An intentional development or packaging override
MUST set `RCLIENT_DIR=/path/to/rl-c-client` explicitly.

The default locked checkout MUST have a clean working tree in addition to the
locked `HEAD`. Ignored build products do not make it dirty. Tracked or untracked
local changes MUST fail dependency resolution. The explicit `RCLIENT_DIR`
override MAY be dirty because selecting it is an intentional opt-out from the
release lock.

The default `upstream-nginx` gitlink MUST equal the mainline commit declared by
every required CI nginx matrix. A meta-test MUST derive the gitlink from the
index and turn red if a matrix copy diverges.

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

The selected C client MUST satisfy every create, borrowed-input, start,
deadline, callback, cancellation, destruction, DNS-cancellation, and steering
guarantee in [`docs/c-client.md`](../docs/c-client.md#required-lifecycle-contract).
The direct compatibility probe MUST run against both the locked release and the
scheduled `rl-c-client/main` checkout before a dependency update is accepted.

## Request ownership

Arrays and strings passed to the borrowed C-client API are owned by the nginx
request pool. A per-request context MUST retain the owning nginx request,
C-client request handle, deadline timer, expected response cardinality, latency
report inputs, and exactly-once accounting flags. It MUST also represent the
admission outcome independently from the completion cause: valid allow, valid
deny, fail-open, fail-close, internal nginx error, and client abort are distinct
outcomes, while a valid verdict, request-start failure, dependency error,
timeout, cardinality mismatch, internal nginx error, and client abort are
distinct causes.

An unsuccessful borrowed start MUST return an error without a callback or live
request handle. A successful start MUST publish the handle before any
completion callback. The module MAY release the borrowed arrays only after the
exactly-once callback, synchronous cancellation, or callback-free client
destruction retires that handle.

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

The log-phase handler MUST call `r_client_report_latency` only for the explicit
valid-allow outcome. It MUST suppress reporting for every other outcome and
for a connection marked timed out, failed, or destroyed, including when an
otherwise valid allow preceded that client abort.

## Response and phase resumption

The callback MUST reject a result whose guard/resource cardinality differs from
the request. It MUST inspect the complete exact-cardinality arrays before
deciding. Callback-owned result arrays MUST NOT be retained after the callback.

After recording the decision, the callback MUST resume nginx phase processing
through `ngx_http_core_run_phases`. It MUST preserve content handlers installed
by directives such as `proxy_pass` and MUST NOT finalize an allow in a way that
clears them. Because the callback runs from the module's UDP event rather than
nginx's HTTP request event handler, it MUST then drain the connection's posted
HTTP requests. It MUST retain only the connection pointer across phase
processing and MUST NOT dereference the request after phases may have finalized
and released it.

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

Normal operational observability is log-based. The
`$ratelimitly_verdict` access-log variable MUST distinguish valid allows and
denies from every outcome without a valid decision. Debug decision/discovery
output requires both `ratelimitly_debug on` and an nginx build/log configuration
that records debug messages. Logs MUST NOT include the full authentication
secret. The module does not implement a metrics exporter or health endpoint.

## Conformance tests

The required static contributor gate (`make check`) MUST cover at least:

- directive parsing, defaults, inheritance, and invalid configuration;
- dependency bootstrap, lock verification, and immutable workflow pins;
- SRV target conversion and strict public DNS fixture behavior;
- allow/deny, outage policy, malformed response, and exact-cardinality cases;
- guard decisions and post-response latency reporting only after a valid allow,
  including suppression after denial, startup failure, timeout fail-open, and
  client abort;
- timeout, aborted client, source-port steering, reload, and shutdown lifecycle;
- missing SRV, invalid SRV target, DNS timeout, and same-worker recovery;
- HTTP-scope resolver selection despite a location-level override; and
- whitespace and script syntax.

That gate MUST reject dynamic `BUILD_FLAGS` and MUST exercise the same static
nginx binary it builds from the caller-supplied flags. Release validation MUST
separately build and load a relocated dynamic module for every supported nginx
line and architecture. The relocated module MUST pass final-admission,
resolver-scope, enforcement-boundary, and guard/latency behavior, not only
`nginx -t` or a load smoke test.

Required gate implementations MUST have a negative fixture that removes or
invalidates the behavior they claim to protect and observes a non-zero result.
Workflow checks MUST validate executable commands and failure propagation, not
comments or substrings. Source-backed specification checks MUST ignore comments
and disabled preprocessor blocks. Whitespace validation MUST inspect committed
revision content as well as working-tree changes.

ASan/UBSan/LSan lifecycle runs MUST cover both supported nginx releases and
MUST additionally exercise repeated timeout,
cancellation, steering, reload, and shutdown behavior. A test-only build MUST
inject every module-owned resolver allocation failure, resolver-start failure,
partial worker-initialization failure, C-client creation failure, and candidate
rebind failure. It MUST also remove the incidental client-read wakeup and prove
that an SSI subrequest posted during asynchronous phase resumption is drained
without another client event. It MUST verify same-worker survival, stable
socket counts, bounded worker-initialization retries, transactional rebind
retention, exact fail-close `429` outcomes for admission-affecting faults, and
clean shutdown without `SIGKILL`. Leak detection MAY be disabled for the
short-lived `nginx -t` and `nginx -s` subprocesses because upstream nginx
retains its configuration-cycle pools there, but it MUST remain enabled for
standalone probes and real master/worker shutdown. A build-wide
sanitizer-category exclusion MUST NOT be used for module sources. Optional
report filtering MUST match a check and upstream-nginx source location exactly;
it MUST NOT accept a report from module or C-client code. Optional internal
full-stack validation is supplemental and is not part of the public conformance
boundary.
