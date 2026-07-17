# Wire mapping

This document defines how effective nginx configuration becomes input to the
locked `rl-c-client` API and RateLimitly wire messages. Numeric grammar and
configuration validation are defined in [Configuration DSL](dsl.md).

## Resource mapping

Each expanded zone occurrence produces one `r_resource_request_t` in rule and
group order:

| C-client field | Value |
| --- | --- |
| `bucket_id` | BLAKE2s-128 hash produced by `r_client_hash_id` from the rendered bucket |
| `window_size_ms` | rendered rate period converted to milliseconds |
| `rate_limit` | rendered decimal rate |
| `tokens_requested` | `1` |

The module copies the rendered bucket to request-pool storage, appends a NUL
terminator, and passes it to the C-client hash helper. An embedded NUL therefore
terminates the hashed identity early. Configuration MUST obey the safe-input
requirements in [`ratelimitly_zone`](dsl.md#ratelimitly_zone).

Repeated zone references are not deduplicated. Each occurrence produces a
separate ResourceBlock on the wire.

## Guard mapping

Each distinct referenced guard definition produces one `r_latency_guard_t` in
first-seen order:

| C-client field | Value |
| --- | --- |
| `service_id` | BLAKE2s-128 hash produced by `r_client_hash_id` from the rendered service |
| `threshold_ms` | rendered threshold converted to milliseconds |
| `ttl_ms` | configured guard TTL in milliseconds |
| `max_samples` | configured value |
| `buffer_size` | configured value |
| `min_sample_threshold` | configured value |

The service hash uses the same NUL-terminated boundary as the bucket hash.
Configuration MUST obey the bounded, operator-controlled input requirements in
[`ratelimitly_guard`](dsl.md#ratelimitly_guard).

The locked C-client encoder writes `current_latency = 0` in every rate-request
GuardBlock. Current latency is learned from server responses; rl-nginx does not
measure or populate this request field.

Repeated references to the same guard definition are deduplicated before both
rate-request and latency-report construction.

## Rate request composition

The module passes the resource array, guard array, and optional metrics label
to `r_client_check_rate_limit_async_borrowed`. The C client builds one rate
request using the configured tenant key ID and authentication material and a
fresh request ID.

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

When the report trigger in [Request behavior](behavior.md#latency-reporting) is
met, the module calls `r_client_report_latency` with one
`r_service_latency_report_t` per distinct applied guard:

| C-client field | Value |
| --- | --- |
| `service_id` | copied from the corresponding request guard |
| `observed_latency` | nginx request-start to log-phase duration, clamped to `1..4294967295` ms |
| `ttl_ms` | copied from guard configuration |
| `max_samples` | copied from guard configuration |
| `buffer_size` | copied from guard configuration |
| `min_sample_threshold` | copied from guard configuration |

The C client creates the report request ID, tenant/authentication framing, and
wire blocks and sends the packet to every currently usable endpoint. The call
is fire-and-forget: no response is awaited and its result cannot change the
HTTP decision.
