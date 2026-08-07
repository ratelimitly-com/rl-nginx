# Request behavior

This document defines the observable request lifecycle and decision contract.
Configuration syntax and wire-field construction are specified separately in
[Configuration DSL](dsl.md) and [Wire mapping](mapping.md).
The meanings of a resource request and an independent latency report come from
the locked C-client
[Operation Model](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#operation-model).

## Activation and request construction

The module runs as nginx's final HTTP pre-content handler. nginx access control
and earlier pre-content routing or preparation handlers MUST complete before
the module sends a RateLimitly request. A request rejected or finalized before
that point MUST NOT consume a RateLimitly resource. Subrequests and requests
without an effective `ratelimitly` rule MUST continue without a RateLimitly
request.

A protected main request that reaches the final admission point MUST expand all
effective rules into one combined rate-limit check containing:

- one resource for every referenced zone occurrence, including repeated zone
  and group entries; and
- one guard for every distinct referenced guard definition, in first-seen
  order.

An nginx internal redirect remains part of the same main HTTP request. Once
that request has obtained an admission result, later internal routing MUST
reuse it and MUST NOT send another RateLimitly request. An admitted request
therefore consumes once even when an index, error page, or another content
handler internally redirects before producing the response. Subrequests remain
unprotected by this module and MUST NOT create an independent admission.

The effective label, zone bucket/rate values, and guard service/threshold
values are rendered for the request. An empty bucket or service, a bucket or
service over 1024 bytes, a label over 256 bytes, another invalid dynamic value,
or a C-client request-construction error MUST follow the configured failure
policy. An empty label omits the label from the request. Internal nginx
allocation or event-registration failures MAY return `500 Internal Server
Error` instead.

The worker-local UDP socket and C client are created lazily by the first
protected request handled by that worker. A running nginx worker therefore
proves process liveness, not that the worker has initialized RateLimitly
enforcement or completed discovery. Failed initialization retries use bounded
backoff; protected requests during that interval immediately follow
`ratelimitly_fail`.

## Discovery, dispatch, and selection

Supported deployments MUST publish SRV records as required by
[`ratelimitly_dns_srv`](dsl.md#ratelimitly_dns_srv). The locked C client resolves
those records and their A/AAAA targets through `ratelimitly_dns_resolver`,
the HTTP-scope `resolver`, or system DNS (`/etc/resolv.conf`).
It sends the request to every currently usable discovered endpoint address.
The resolver is captured from the `http` context and applies process-wide to the
worker client. Server and location resolver overrides do not change RateLimitly discovery.

rl-nginx does not choose a single commit target and does not deduplicate
resource consumption across those endpoints. A supported deployment MUST
therefore provide a RateLimitly server topology and protocol contract in which
that fan-out represents one logical admission/consumption. This commit-safety
property is external to the nginx module. Operators MUST NOT assume there is a
hidden single-target fallback when a discovered topology lacks that property.

The module passes the policy selected by `ratelimitly_policy` to the locked C
client. The default `standard unit=20ms` policy sends to all discovered
servers, prefers the oldest server's valid response, performs one replay to
servers still missing a valid response, then waits through one final
receive-only unit. A selected allow or deny also triggers best-effort
completion delivery to servers still missing a response. Its maximum admission
wait and wire deduplication TTL are `3 * U`, or 60ms by default.

`single_round` sends once, waits for at most one unit, and disables both replay
and completion delivery. `custom` exposes the replay-gap schedule, replay count,
final receive interval, and completion delivery. The exact syntax, horizon
formula, and validation rules are in [Configuration DSL](dsl.md#ratelimitly_policy).
DNS refresh policy remains client-owned and is not configurable through rl-nginx.

Fan-out, response preference, replay scheduling, completion delivery, and TTL
derivation are client-owned and are defined in the locked
[Resource-Request HA Policy](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#resource-request-ha-policy).
The paragraphs above specify the supported nginx selections and their
externally visible effect.

The locked client requires SRV discovery. A failed, empty, or non-conforming
membership fails with `RCLIENT_ERR_DNS`; there is no direct tenant-name/UDP
port fallback. The client owns the corresponding
[DNS Refresh](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#dns-refresh)
behavior.

## Decision contract

A valid result MUST contain exactly as many guard and resource results as the
request sent. A mismatch is a protocol/compatibility failure and follows the
configured failure policy; partial response arrays MUST NOT be treated as a
decision.

When status is successful and cardinality is exact, the module MUST admit the
request to content processing only if all of the following are true:

- the response-level `success` value is true;
- every guard result has `passed` set; and
- every resource result has `tokens_deficit == 0`.

Otherwise the module MUST return `429 Too Many Requests`. A valid RateLimitly
deny returns `429` under both failure policies. A valid allow represents
consumption of the requested resources and MUST advance directly to nginx
content processing without another pre-content handler. The admitted client,
content handler, or upstream can still fail afterward; such failures do not
reverse the consumption.

## Verdict variable

The module registers the nginx variable `$ratelimitly_verdict`. It MUST evaluate
to `allow` only after a valid result satisfies the complete allow contract
above, and to `deny` only after a valid result fails that contract. It MUST be
not found (rendered as `-` by normal nginx log formats) for an unprotected or
bypassed request, a request still awaiting a result, and every fail-open,
fail-close, internal-error, or aborted outcome.

This variable is a decision provenance signal, not the final HTTP status. An
`allow` can be followed by a content/upstream error, while a `deny` produces
`429`. Operations MAY include it in an access-log format to prove warmup
without enabling debug logging.

## Failure policy

`ratelimitly_fail` applies when the module cannot obtain a valid, complete
decision:

| Condition | `open` | `close` |
| --- | --- | --- |
| Valid allow | Admit to content processing | Admit to content processing |
| Valid RateLimitly, guard, or resource deny | Return `429` | Return `429` |
| No usable discovery target | Admit without a valid decision | Return `429` |
| UDP send failure or response timeout | Admit without a valid decision | Return `429` |
| Authentication/protocol failure with no valid decision | Admit without a valid decision | Return `429` |
| Response cardinality mismatch | Admit without a valid decision | Return `429` |
| Invalid dynamic request value or request-construction failure | Admit without a valid decision | Return `429` |
| Internal nginx allocation/event failure | MAY return `500` | MAY return `500` |

Invalid or irrelevant datagrams can be discarded by the C client. If no valid
response then arrives, the visible terminal result can be a timeout rather
than the error associated with the discarded packet.

## Asynchronous ownership and cleanup

Rate checks MUST NOT block an nginx worker. The module starts an asynchronous
borrowed-input C-client request, arms an nginx timer to the client deadline,
and resumes HTTP phase processing from the completion callback.

The request-pool resources, guards, label, and callback context MUST remain
valid until completion or cancellation. Client disconnect and nginx request
cleanup MUST cancel the C-client request, remove the timer, and release the
nginx and worker in-flight accounting exactly once. A synchronous callback
from timeout handling can release the request pool; timeout code MUST NOT
access the request context afterwards.

Worker shutdown MUST destroy the worker C client while its resolver adapter is
still live, allowing outstanding resolver activity to be cancelled, and then
close the worker socket. Reload and shutdown MUST leave no active request
timer, resolver context, or UDP connection owned by an exited worker.

## Steering feedback

Rate and latency-report request headers set `steering_feedback` to zero. If a
valid response carries `steering_feedback = 0`, the locked client asks the
module to replace the worker's UDP source port. The module MUST mark the rebind
pending and defer it until the worker has no in-flight RateLimitly requests.
It MUST NOT close or replace the socket from inside its active UDP read
callback. A zero-delay nginx event performs the rebind once both conditions
are safe. The event MUST register the replacement socket before retiring the
current socket. If replacement setup fails, the current socket remains active
and the module retries later; a failed steering rebind by itself MUST NOT turn
a usable worker into an outage.

A latency report is an independent fire-and-forget request. It is not related
to the rate request that admitted the HTTP operation and does not require that
request's source port. The module MUST NOT hold a requested rebind for a future
latency report. After the C-client callback reports `keep_port = false` (wire
`steering_feedback = 0`), it SHOULD use the replacement source port for
subsequent sends as soon as nginx can safely replace the socket. A send
completed reentrantly while the feedback datagram's UDP read callback is still
active MAY use the old port; otherwise later sends use the replacement
endpoint.

## Latency reporting

For a main request that used at least one distinct guard, the nginx log-phase
handler MUST attempt one fire-and-forget latency report only when RateLimitly
returned a valid, exact-cardinality allow and the admitted request reached log
phase without a client connection error, timeout, or destruction. Reaching log
phase represents the request processing that follows consumed admission; the
resulting HTTP status does not refund or invalidate that admission.

A valid deny, request-start failure, absent or invalid verdict, dependency
fail-open or fail-close result, response timeout, cardinality mismatch, and
client abort MUST NOT produce or attempt a latency report. In particular,
fail-open continuation preserves availability but is not evidence that
RateLimitly admitted or consumed the request, so it MUST NOT add a guard
latency sample.

The observed duration starts at the nginx request timestamp and ends when the
log-phase handler runs. It is clamped to the inclusive unsigned 32-bit range
`1..4294967295` milliseconds. The report contains one entry per distinct
applied guard, using the same service identifier and sampling settings as the
rate request. Report construction or send failure MUST NOT change the HTTP
result.

## Observability

The implemented observability surface is nginx access/error logging plus the
documented module log markers. The module does not expose Prometheus counters,
histograms, or a health endpoint. Exact marker interpretation and sensitive-log
handling are defined in the [operations guide](../docs/operations.md).
