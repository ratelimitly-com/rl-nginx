# C r-client integration

This module uses the standalone C r-client repo as the protocol engine.
Preferred local path is `./rl-c-client` (legacy fallback:
`./upstream-rl/clients/c`).

## Key assumptions

- Broadcast each rate request to all SRV targets (HA behavior).
- DNS refresh interval must not exceed the minimum SRV TTL.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- Timeouts and retries are set by nginx (default timeout 20ms, retries disabled).
- Steering feedback is evaluated per response; rebind the UDP socket only after
  the current request completes if any response requested a port change.

## Notes

The nginx module must provide I/O and DNS adapters via `r_client_io.h`
(see `./rl-c-client/IO_ABSTRACTION.md`).
