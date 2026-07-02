# C Client Integration

This module uses the standalone `rl-c-client` repo as the protocol engine.
The preferred development layout keeps `rl-c-client` and `rl-nginx` as sibling
checkouts:

```text
glar/
  rl-c-client/
  rl-nginx/
```

Set `RCLIENT_DIR=/path/to/rl-c-client` when using another layout.

## Key Assumptions

- Multi-target send is allowed only when commit safety is guaranteed; otherwise use a single deterministic commit target for mutating requests.
- DNS refresh interval MUST NOT exceed the minimum SRV TTL.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- Timeouts and retries are set by nginx (default timeout 20ms, retries disabled).
- Steering feedback is evaluated per response; rebind the UDP socket only after
  the current request completes if any response requested a port change.

## Notes

The nginx module MUST provide I/O and DNS adapters via `r_client_io.h`
(see `../rl-c-client/IO_ABSTRACTION.md` in the sibling checkout).
