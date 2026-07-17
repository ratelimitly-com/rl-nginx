# C Client Integration

This module uses the standalone `rl-c-client` repository as the protocol
engine. The supported tag and full commit SHA are recorded in
[`../dependencies/rl-c-client.env`](../dependencies/rl-c-client.env). Fetch the
locked public release with:

```sh
./tools/fetch-rl-c-client.sh
```

The default checkout is `./_deps/rl-c-client`. Set
`RCLIENT_DIR=/path/to/rl-c-client` to test an intentional development or
packaging checkout; doing so does not change the supported release revision.
Without an override, build and test entrypoints fetch or verify the locked
checkout before use and never fall back to an adjacent development checkout.

## Key Assumptions

- Multi-target send is allowed only when commit safety is guaranteed; otherwise use a single deterministic commit target for mutating requests.
- DNS refresh interval MUST NOT exceed the minimum SRV TTL.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- Timeouts and retries are set by nginx (default timeout 20ms, retries disabled).
- Steering feedback is evaluated per response; rebind the UDP socket only after
  the current request completes if any response requested a port change.

## Notes

The nginx module MUST provide I/O and DNS adapters via `r_client_io.h` (see
`IO_ABSTRACTION.md` in the selected C-client checkout).
