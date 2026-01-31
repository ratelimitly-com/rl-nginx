# Behavior (Draft)

## Request flow

1. Evaluate nginx location directives and build a `ratelimitly` rule.
2. Resolve each configured zone to a `(bucket_id, window_size_ms, rate_limit, tokens_requested)` tuple by rendering the `bucket` template for the request.
3. Build a Ratelimitly rate_request PDU with one ResourceBlock per resolved zone.
4. If `ratelimitly_label` is set, add a `metrics_label` TLV with the rendered label.
5. Send via UDP to **all** tenant DNS SRV targets and wait for response(s).
6. Allow the request only if the response has `deficit == 0`.
7. If any response has `steering_feedback = 0`, mark the socket for rebinding and perform the rebind only after the current request finishes (all responses received or timed out).

## Failure handling

- Timeout or network error:
  - `ratelimitly_fail open`: allow
  - `ratelimitly_fail close`: reject

## Response status

- Success: pass through to upstream.
- Rejected: return 429 (Too Many Requests) by default.

## Observability (future)

- Export Prometheus counters (e.g., `rn_requests_allowed_total`, `rn_requests_denied_total`, `rn_requests_timeout_total`).
