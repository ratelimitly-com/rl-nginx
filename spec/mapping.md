# Wire mapping

This document defines how effective nginx configuration becomes input to the
locked `rl-c-client` API and RateLimitly wire messages. Numeric grammar and
configuration validation are defined in [Configuration DSL](dsl.md).

The client structures and canonical derivation algorithms are defined by the
locked C-client's
[Resource Requests](https://github.com/ratelimitly-com/rl-c-client/blob/v0.6.0/docs/api.md#resource-requests),
[Latency Guards and Independent Reports](https://github.com/ratelimitly-com/rl-c-client/blob/v0.6.0/docs/api.md#latency-guards-and-independent-reports),
and
[Content-defined IDs](https://github.com/ratelimitly-com/rl-c-client/blob/v0.6.0/docs/api.md#content-defined-ids).
This document specifies which nginx values rl-nginx supplies to that API.

## Resource mapping

Each expanded zone occurrence produces one `r_resource_request_t` in rule and
group order:

| C-client field | Value |
| --- | --- |
| `bucket_id` | canonical ID produced by `r_client_derive_bucket_id` from the exact rendered bucket bytes, `window_size_ms`, and `rate_limit` |
| `window_size_ms` | rendered rate period converted to milliseconds |
| `rate_limit` | rendered decimal rate |
| `tokens_requested` | `1` |

The module passes the exact rendered bytes and explicit byte length to the
C-client helper. Embedded NUL bytes are part of the identity rather than a
terminator. The helper frames the name and defining numeric fields and returns
the first 16 bytes of its domain-separated BLAKE2s-256 digest.

The complete rendered bucket is one opaque flat string. The module does not
escape components, add length prefixes, or otherwise make an ambiguous
template structurally unique. Operators MUST construct a canonical,
unambiguous string from fixed values and bounded finite-map outputs. Changing
the rendered text, window, or rate changes the resource ID and starts new
logical bucket state.

The executable boundary oracle pins the rendered text
`boundary:known-bucket` with a `10000r/s` rate to identifier
`98300f8a73dd010d75b92ce8d2298cc7` and requires the responder to observe the
same one-resource request. This locks the complete name/window/rate boundary.

Repeated zone references are not deduplicated. Each occurrence produces a
separate ResourceBlock on the wire.

## Guard mapping

Each distinct referenced guard definition produces one `r_latency_guard_t` in
first-seen order:

| C-client field | Value |
| --- | --- |
| `latency_tracker_id` | canonical ID produced by `r_client_derive_latency_tracker_id` from the referenced tracker's exact rendered service bytes and state settings |
| `threshold_ms` | rendered threshold converted to milliseconds |
| `ttl_ms` | configured tracker TTL in milliseconds |
| `max_samples` | tracker value |
| `buffer_size` | explicit tracker value, or the API-key `latency_buffer_size_max` when omitted |
| `min_sample_threshold` | tracker value |

The ID includes the rendered service, `ttl_ms`, `max_samples`, final effective
`buffer_size`, and `min_sample_threshold`. `threshold_ms` is excluded because
it evaluates tracker state but does not define that stored state. Changing an
included value creates a new tracker and separates subsequent latency history
from the old identity. The exact rendered service length is honored, including
embedded NUL bytes.

The locked C-client encoder writes `current_latency = 0` in every rate-request
GuardBlock. Current latency is learned from server responses; rl-nginx does not
measure or populate this request field.

Repeated references to the same guard definition are deduplicated before rate
request construction. Guards never construct or enable latency reports.

## Rate request composition

The module passes the resource array, guard array, and optional metrics label
to `r_client_check_rate_limit_async_borrowed`. For a guard-only rule the
resource pointer is null and the resource count is zero. The C client builds
one rate request using the configured tenant key ID and authentication
material and a fresh request ID.

The effective label is passed with its explicit byte length. An unset or empty
rendered label is represented by a null pointer/zero length and MUST omit the
metrics-label TLV. Label content MUST meet the bounded, non-sensitive
requirements in [`ratelimitly_label`](dsl.md#ratelimitly_label).

The client sets request-header `steering_feedback = 0`. Authentication wrapping
and all other protocol framing are owned by the locked C client rather than
reimplemented by the nginx module.

## Response mapping

The C-client callback result is valid only during the callback. Before reading
individual entries, rl-nginx compares:

- callback `guard_count` with the number of distinct guards sent; and
- callback `resource_count` with the number of expanded zone occurrences sent.

Only exact cardinality is accepted. With exact cardinality, response-level
`success`, every guard `passed` value, and every resource `tokens_deficit` value
map to the decision contract in [Request behavior](behavior.md#decision-contract).
The response's `actual_rate`, server ID, and steering flag do not independently
permit a request.

## Latency report mapping

When the explicit report trigger in
[Request behavior](behavior.md#latency-reporting) is met, the module calls
`r_client_report_latency` with exactly one `r_service_latency_report_t` built
from the effective `ratelimitly_report` tracker:

| C-client field | Value |
| --- | --- |
| `latency_tracker_id` | canonical ID derived from the report tracker's rendered service and state settings |
| `observed_latency` | nginx request-start to log-phase duration, clamped to `1..4294967295` ms |
| `ttl_ms` | report tracker configuration |
| `max_samples` | report tracker configuration |
| `buffer_size` | report tracker's explicit value or the credential quota when omitted |
| `min_sample_threshold` | report tracker configuration |

The C client creates the report request ID, tenant/authentication framing, and
wire blocks and sends the packet to every currently usable endpoint. The call
is fire-and-forget: no response is awaited and its result cannot change the
HTTP decision. A report has no request-level relationship to the rate request
that admitted the HTTP operation, and the server does not correlate the two by
UDP source port. A steering-driven source-port replacement therefore neither
invalidates a report nor waits for one. On a cold worker, discovery may still
be in progress when the first report-only request completes; that best-effort
report can be dropped rather than delayed.
