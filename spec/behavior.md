# Behavior (Draft)

## Request flow

1. Evaluate nginx location directives and build a `ratelimitly` rule.
2. Resolve each configured zone to a `(bucket_id, window_size_ms, rate_limit, tokens_requested)` tuple by rendering zone templates for the request.
3. Resolve each configured guard to a `(service_id, threshold_ms, ttl_ms, max_samples, buffer_size, min_sample_threshold)` tuple by rendering guard templates for the request.
4. Build a Ratelimitly `rate_request` PDU with one ResourceBlock per resolved zone and one GuardBlock per resolved guard.
5. If `ratelimitly_label` is set, add a `metrics_label` TLV with the rendered label.
6. Send via UDP to **all** tenant DNS SRV targets and wait for response(s).
7. For the selected response, evaluate all guard results and all resource results.
8. Allow the request only if all guards pass and all resources have `deficit == 0`.
9. Reject otherwise.
10. If any response has `steering_feedback = 0`, mark the socket for rebinding and perform the rebind only after the current request finishes (all responses received or timed out).
11. On request completion, if guards were used, measure end-to-end request latency in milliseconds, clamp to minimum `1ms`, and send a fire-and-forget `latency_report` PDU.

## Failure handling

- Timeout or network error:
  - `ratelimitly_fail open`: allow
  - `ratelimitly_fail close`: reject

## Response status

- Success: pass through to upstream.
- Rejected: return 429 (Too Many Requests) by default.

## Observability (future)

- Export Prometheus counters (e.g., `rn_requests_allowed_total`, `rn_requests_denied_total`, `rn_requests_timeout_total`).
