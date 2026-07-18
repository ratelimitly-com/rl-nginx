# Request behavior

This document defines the observable request lifecycle and decision contract.
Configuration syntax and wire-field construction are specified separately in
[Configuration DSL](dsl.md) and [Wire mapping](mapping.md).

## Activation and request construction

The module runs in nginx's HTTP access phase. A request without an effective
`ratelimitly` rule MUST continue through normal nginx processing without a
RateLimitly request. A protected request MUST expand all effective rules into
one combined rate-limit check containing:

- one resource for every referenced zone occurrence, including repeated zone
  and group entries; and
- one guard for every distinct referenced guard definition, in first-seen
  order.

The effective label, zone bucket/rate values, and guard service/threshold
values are rendered for the request. Invalid dynamic values, an empty rendered
guard service, or a C-client request-construction error MUST follow the
configured failure policy. Internal nginx allocation or event-registration
failures MAY return `500 Internal Server Error` instead.

The worker-local UDP socket and C client are created lazily by the first
protected request handled by that worker. A running nginx worker therefore
proves process liveness, not that the worker has initialized RateLimitly
enforcement or completed discovery.

## Discovery, dispatch, and selection

Supported deployments MUST publish SRV records as required by
[`ratelimitly_tenant`](dsl.md#ratelimitly_tenant). The locked C client resolves
those records and their A/AAAA targets through the nginx asynchronous resolver.
It sends the request to every currently usable discovered endpoint address.

The module starts from the locked C-client request-policy defaults, overrides
the attempt timeout with `ratelimitly_timeout`, and sets retry attempts to zero.
For the currently locked revision this means one attempt, waiting until all
targets have replied or the attempt deadline expires, with the client's
best-by-reliability response selection. rl-nginx exposes no directives for
wait, quorum, selection, retry, deduplication, or DNS-resynchronization policy.
Changing the dependency lock in a way that changes this observable behavior
MUST update this specification and its tests in the same change.

The locked client contains a compatibility fallback that can resolve the
tenant name directly and use UDP port `8080` when SRV discovery yields no
endpoint. This fallback is not a supported rl-nginx deployment or a fixed
server-address configuration mechanism. Public DNS failure tests MUST ensure a
missing SRV record cannot be accidentally masked by this fallback.

## Decision contract

A valid result MUST contain exactly as many guard and resource results as the
request sent. A mismatch is a protocol/compatibility failure and follows the
configured failure policy; partial response arrays MUST NOT be treated as a
decision.

When status is successful and cardinality is exact, the module MUST continue
normal nginx processing only if all of the following are true:

- the response-level `success` value is true;
- every guard result has `passed` set; and
- every resource result has `tokens_deficit == 0`.

Otherwise the module MUST return `429 Too Many Requests`. A valid RateLimitly
deny returns `429` under both failure policies. Continuing nginx processing
does not guarantee a successful final HTTP status: later nginx phases,
upstreams, or content handlers still determine the response.

## Failure policy

`ratelimitly_fail` applies when the module cannot obtain a valid, complete
decision:

| Condition | `open` | `close` |
| --- | --- | --- |
| Valid allow | Continue nginx processing | Continue nginx processing |
| Valid RateLimitly, guard, or resource deny | Return `429` | Return `429` |
| No usable discovery target | Continue nginx processing | Return `429` |
| UDP send failure or response timeout | Continue nginx processing | Return `429` |
| Authentication/protocol failure with no valid decision | Continue nginx processing | Return `429` |
| Response cardinality mismatch | Continue nginx processing | Return `429` |
| Invalid dynamic request value or request-construction failure | Continue nginx processing | Return `429` |
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

## Latency reporting

For a main request that used at least one distinct guard and was not denied by
the module, the nginx log-phase handler MUST attempt one fire-and-forget
latency report. A module-denied `429` MUST NOT produce a latency report.

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
