# Mapping to Ratelimitly Wire Protocol (Draft)

## GuardBlock mapping

Given:

- `guard`: config name
- `service`: rendered service expression (nginx variables expanded)
- `threshold`: rendered duration expression
- `ttl`, `max_samples`, `buffer_size`, `min_sample_threshold`: guard tuning values

Compute:

- `service_id`: BLAKE2s-128 hash of rendered `service`
- `latency_threshold`/`threshold_ms`: parsed threshold in milliseconds
- `ttl_ms`: parsed `ttl` in milliseconds
- `max_samples`: configured integer
- `buffer_size`: configured integer
- `min_sample_threshold`: configured integer
- `current_latency`: `0` in requests

## ResourceBlock mapping

Given:

- `zone`: config name (each zone becomes a ResourceBlock)
- `bucket`: rendered template string (nginx variables expanded)
- `rate`: rendered rate expression in `N r / period` form

Compute:

- `bucket_id`: BLAKE2s-128 hash of `bucket`
- `window_size_ms`: parsed period in milliseconds
- `rate_limit`: parsed `N`
- `tokens_requested`: 1

## PDU

- Use `PDU_RATE_REQUEST` with 0+ guard blocks and 1+ resource blocks.
- If configured, include a `metrics_label` TLV with the rendered label string.
- Set `steering_feedback = 0` in request tenant header (server ignores request value).
- Use tenant/auth headers per configured tenant and auth.

## Latency report mapping

Trigger:

- After nginx request completion, if the applied `ratelimitly` rule included at least one guard.

Compute observed latency:

- `observed_latency_ms` = end-to-end request time in milliseconds:
  - start: nginx request start timestamp
  - end: request completion timestamp (response finished)
- Clamp `observed_latency_ms` to minimum `1` to avoid zero-millisecond artifacts.

Build report:

- Use `PDU_LATENCY_REPORT` with one ServiceLatencyBlock per applied guard.
- Reuse the same guard mapping values:
  - `service_id`, `ttl_ms`, `max_samples`, `buffer_size`, `min_sample_threshold`
- Set `observed_latency` to computed `observed_latency_ms`.
- Send as fire-and-forget (no response awaited).
