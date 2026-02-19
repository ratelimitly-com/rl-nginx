# Mapping to Ratelimitly Wire Protocol (Draft)

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

- Use `PDU_RATE_REQUEST` with 0 guard blocks and 1+ resource blocks.
- If configured, include a `metrics_label` TLV with the rendered label string.
- Set `steering_feedback = 0` in request tenant header (server ignores request value).
- Use tenant/auth headers per configured tenant and auth.
