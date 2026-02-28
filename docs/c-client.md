# C r-client integration

This module uses the standalone C r-client repo as the protocol engine.
Preferred local path is `./rl-c-client` (legacy fallback:
`./upstream-rl/clients/c`).

## Key assumptions

- Multi-target send is allowed only when commit safety is guaranteed; otherwise use a single deterministic commit target for mutating requests.
- DNS refresh interval MUST NOT exceed the minimum SRV TTL.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- Timeouts and retries are set by nginx (default timeout 20ms, retries disabled).
- Steering feedback is evaluated per response; rebind the UDP socket only after
  the current request completes if any response requested a port change.

## Notes

The nginx module MUST provide I/O and DNS adapters via `r_client_io.h`
(see `./rl-c-client/IO_ABSTRACTION.md`).
