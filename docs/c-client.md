# C r-client integration

This module uses the C r-client from the rl repo
(`git@conflictbits.org:glar/rl.git`) as the protocol engine. The rl repo is a
submodule at `./upstream-rl`, and the client lives at
`./upstream-rl/clients/c`.

## Key assumptions

- Broadcast each rate request to all SRV targets (HA behavior).
- DNS refresh interval must not exceed the minimum SRV TTL.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- Timeouts and retries are set by nginx (default timeout 20ms, retries disabled).
- Steering feedback is evaluated per response; rebind the UDP socket only after
  the current request completes if any response requested a port change.

## Notes

The nginx module must provide I/O and DNS adapters via `r_client_io.h`
(see `./upstream-rl/clients/c/IO_ABSTRACTION.md`).
