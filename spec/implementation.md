# Implementation Spec

This document defines the required implementation behavior for the rl-nginx
module.

## A) Core behavior

- Parse DSL directives: `ratelimitly_tenant`, `ratelimitly_auth_key`,
  `ratelimitly_timeout`, `ratelimitly_fail`, `ratelimitly_zone`, `ratelimitly_guard`,
  `ratelimitly_group`, `ratelimitly`, `ratelimitly_label`.
- For each nginx request, build one Ratelimitly `rate_request` PDU with:
  - one ResourceBlock per resolved zone
  - one GuardBlock per resolved guard
- Parse full response guard/resource arrays and decide only after all entries are evaluated.
- Deny the request if any GuardBlock fails or any ResourceBlock returns `deficit > 0`.
- On timeout/network error: obey `ratelimitly_fail` (`open` or `close`).
- If `ratelimitly_label` is set, emit a `metrics_label` TLV.
- After request completion, if guards were applied, send one fire-and-forget
  `latency_report` PDU with one ServiceLatencyBlock per applied guard.

## B) Request selection

- Only locations/servers that include `ratelimitly ...;` participate.
- Multiple `ratelimitly` directives in a location are combined into a single rate_request.
- `ratelimitly` may reference zones/groups and optional guards.
- Guards referenced by `ratelimitly` are resolved and attached to the same request.

## C) Resource and guard construction

For each `ratelimitly_zone`:

- Render `bucket` template (e.g. `"const:$uri:$cookie"`) via nginx variable expansion.
- Render `rate` expression via nginx variable expansion.
- `bucket_id` = BLAKE2s-128(bucket string).
- Parse `window_size_ms`, `rate_limit` from rendered `rate` (`<N>r/<period_or_duration>`).
- `tokens_requested` = 1.

For each `ratelimitly_guard`:

- Render `service` template via nginx variable expansion.
- Render `threshold` expression and parse as duration in milliseconds.
- `service_id` = BLAKE2s-128(service string).
- Copy `ttl_ms`, `max_samples`, `buffer_size`, `min_sample_threshold`.
- Set request `current_latency` field to `0`.

## D) Latency measurement and reporting

- Measure request end-to-end latency in milliseconds:
  - start: nginx request start timestamp
  - end: request completion timestamp (response finished).
- Clamp measured latency to minimum `1ms` before writing `observed_latency`.
- Reporting trigger: only when at least one guard was applied in the request.
- Build one `latency_report` PDU with one ServiceLatencyBlock per applied guard:
  - `service_id` from the guard mapping
  - `observed_latency` from measured end-to-end latency
  - `ttl_ms`, `max_samples`, `buffer_size`, `min_sample_threshold` copied from guard config
- Send report as fire-and-forget using `r_client_report_latency`.
- Latency report send failures MUST NOT alter the HTTP response outcome.

## E) Networking & discovery

- Use nginx resolver for SRV `_ratelimitly._udp.<tenant>`.
- Resolve A/AAAA only for the SRV target hostnames returned by that lookup.
- Maintain a per-worker cached server list; refresh interval MUST NOT exceed the
  minimum DNS TTL (SRV records).
- Multi-target send is allowed only when HA commit safety is preserved:
  - strongly consistent shared token state, or
  - exactly one effective commit authority for the request.
- If neither condition is guaranteed, route mutating requests to a single deterministic commit target.

## F) Async request flow (non-blocking)

Blocking waits are not allowed. The module MUST use nginx's event loop and timers.

- Allocate per-request context in nginx pool:
  state, deadline, socket, server list, PDU buffer, attempts, timer.
- Steps:
  1) Build and send `rate_request` PDU (non-blocking UDP).
  2) Register read event + timer.
  3) On read: parse full response (all guards/resources), then decide allow/deny; finalize request.
  4) On timeout: fail open/close; finalize request.
  5) On request completion/log phase: emit optional fire-and-forget `latency_report`.

Steering feedback:
- The request always sets `steering_feedback = 0`.
- The server response controls port steering:
  - `steering_feedback = 0` => mark for rebind; perform rebind after the request completes (do not close the socket mid-flight).
  - `steering_feedback = 1` => keep the current socket.

## G) Auth

- Accept one Bech32 auth key via `ratelimitly_auth_key`.
- Supported HRPs: `rl-cookie`, `rl-aes`.
- Derive tenant id from embedded Bech32 `key_id`.
- Validate embedded payload length at config load:
  - `rl-cookie`: 32 bytes
  - `rl-aes`: 32 bytes

## H) Observability

Expose Prometheus counters:

- `rn_requests_allowed_total`
- `rn_requests_denied_total`
- `rn_requests_timeout_total`
- `rn_latency_reports_sent_total`
- `rn_latency_reports_failed_total`

Optional:
- latency histogram for RL round-trip
- histogram for end-to-end observed request latency sent in reports

## I) Error handling

- Invalid config (unknown zone/guard, invalid rate/threshold, bad auth settings) -> nginx config error.
- Runtime errors (DNS failure, network errors) -> use fail-open/fail-close behavior.
- Runtime latency-report send errors are logged/debugged but do not affect request decision.

## J) Performance constraints

- Avoid blocking calls; use non-blocking UDP + nginx timers.
- Minimize allocations; prefer caller-owned buffers (borrowed API) where possible.
- Avoid string building except for bucket/service template rendering and label.
- Keep latency reporting off the critical path (fire-and-forget).

## K) rl-c-client integration assumptions

- Use the standalone `rl-c-client` repo as the protocol engine.
  - Supported builds MUST use the tag and full SHA in
    `dependencies/rl-c-client.env`.
  - The fetch helper installs that revision at `./_deps/rl-c-client`.
  - Development or packaging overrides MUST set
    `RCLIENT_DIR=/path/to/rl-c-client` explicitly.
- Use `r_client_check_rate_limit_async_borrowed` for rate requests to avoid per-request copies.
- Use `r_client_report_latency` for post-response latency telemetry.
- nginx MUST override the r-client default policy:
  - `attempt_timeout_ms` from `ratelimitly_timeout` (default 20ms).
  - `retry_attempts = 0` unless explicitly configured later.
