# Implementation Spec (MVP)

This document defines the required implementation work for the nginx plugin (rate-nginx / rn).

## A) Core behavior

- Parse DSL directives: `ratelimitly_tenant`, `ratelimitly_key_id`, `ratelimitly_auth`,
  `ratelimitly_timeout`, `ratelimitly_fail`, `ratelimitly_zone`, `ratelimitly_group`,
  `ratelimitly`, `ratelimitly_label`.
- For each nginx request, build one Ratelimitly `rate_request` PDU with **one ResourceBlock
  per resolved zone**.
- Deny the request if **any** ResourceBlock returns `deficit > 0`.
- On timeout/network error: obey `ratelimitly_fail` (`open` or `close`).
- If `ratelimitly_label` is set, emit a `metrics_label` TLV.

## B) Request selection

- Only locations/servers that include `ratelimitly ...;` participate.
- Multiple `ratelimitly` directives in a location are combined into a single rate_request.

## C) Bucket construction

For each `ratelimitly_zone`:

- Render `bucket` template (e.g. `"const:$uri:$cookie"`) via nginx variable expansion.
- Render `rate` expression via nginx variable expansion.
- `bucket_id` = BLAKE2s-128(bucket string).
- Parse `window_size_ms`, `rate_limit` from rendered `rate` (`<N>r/<period_or_duration>`).
- `tokens_requested` = 1.

## D) Networking & discovery

- Use nginx resolver for SRV `_ratelimitly._udp.<tenant>`.
- If SRV is missing, fallback to A/AAAA for `<tenant>` with port `8080`.
- Maintain a per-worker cached server list; refresh interval must not exceed the
  minimum DNS TTL (SRV records).
- **Broadcast** each rate request to all discovered SRV targets (HA requirement).

## E) Async request flow (non-blocking)

Blocking waits are not allowed. The module must use nginx's event loop and timers.

- Allocate per-request context in nginx pool:
  state, deadline, socket, server list, PDU buffer, attempts, timer.
- Steps:
  1) Build PDU.
  2) Send UDP datagram (non-blocking).
  3) Register read event + timer.
  4) On read: parse response; decide allow/deny; finalize request.
  5) On timeout: fail open/close; finalize.

Steering feedback:
- The request always sets `steering_feedback = 0`.
- The server response controls port steering:
  - `steering_feedback = 0` => mark for rebind; perform rebind after the request completes (do not close the socket mid-flight).
  - `steering_feedback = 1` => keep the current socket.

## F) Auth

- Support: `cookie` and `aesgcm`.
- `none` is development-only.
- Precompute derived keys at config load when possible.

## G) Observability

Expose Prometheus counters:

- `rn_requests_allowed_total`
- `rn_requests_denied_total`
- `rn_requests_timeout_total`

Optional: latency histogram for RL round-trip.

## H) Error handling

- Invalid config (unknown zone, invalid rate, bad auth settings) -> nginx config error.
- Runtime errors (DNS failure, network errors) -> use fail-open/fail-close behavior.

## I) Performance constraints

- Avoid blocking calls; use non-blocking UDP + nginx timers.
- Minimize allocations; prefer caller-owned buffers (borrowed API) where possible.
- Avoid string building except for bucket template rendering and label.

## J) C r-client integration assumptions

- Use the standalone C r-client repo as the protocol engine.
  - Preferred local path: `./rl-c-client`.
  - Legacy fallback path: `./upstream-rl/clients/c`.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- nginx must override the r-client default policy:
  - `attempt_timeout_ms` from `ratelimitly_timeout` (default 20ms).
  - `retry_attempts = 0` unless explicitly configured later.
