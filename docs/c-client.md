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
The default checkout must have both the locked `HEAD` and a clean working tree.
Generated files ignored by the C-client repository are permitted; tracked or
untracked local source changes are rejected. An explicit `RCLIENT_DIR` is the
only supported way to opt into a dirty development tree.

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

## Required lifecycle contract

The version lock covers more than source and wire compatibility. `rl-nginx`
depends on the following callback and ownership behavior. A C-client update is
not compatible until every item remains true:

1. `r_client_create` borrows its configuration, tenant/authentication strings,
   request policy, and adapter tables only for the duration of the call. On
   success the caller may release or overwrite those inputs. Resolver callbacks
   invoked during creation may be synchronous, as declared by `r_client_io.h`.
2. `r_client_check_rate_limit_async_borrowed` returning an error does not invoke
   the rate callback and does not publish a live request. Returning
   `RCLIENT_OK` publishes a live request without invoking its completion
   callback before the start call returns.
3. After a successful borrowed start, the resource, guard, and label buffers
   remain caller-owned and must stay live until callback, cancellation, or
   client destruction. The client neither modifies nor frees them.
4. `r_client_request_deadline_ms` succeeds for a live request. With the module's
   `retry_attempts = 0`, `r_client_on_timeout` before that deadline leaves the
   request pending; at or after the deadline it invokes the completion callback
   synchronously and exactly once before returning. The request handle is no
   longer valid when that callback completes.
5. A normal response invokes exactly one completion callback with the same
   request handle. The result and its guard/resource arrays are callback-owned
   and valid only inside that invocation. The client unlinks the request before
   calling back and releases it after the callback returns, so the module must
   copy decisions during the callback and must not retain or cancel the handle
   afterward.
6. `r_client_cancel_request` synchronously retires the request without invoking
   its callback. Late or duplicate datagrams cannot revive it. Once cancel
   returns, the module may release all borrowed request inputs.
7. `r_client_destroy` retires inflight rate requests without invoking their
   callbacks. It detaches internal DNS refresh state before calling the
   resolver's cancellation hook; the hook may synchronously deliver its pending
   DNS callback without re-entering a half-destroyed client.
8. Steering feedback may be delivered from the response-completion stack. The
   adapter therefore only records and schedules a rebind; it never replaces the
   socket from either the rate callback or UDP read callback.

These requirements deliberately state behavior that is not fully expressible
through the C header types. They are compatibility requirements for
`rl-nginx`, not a claim that arbitrary C-client versions provide them.

## Executable compatibility probe

`tests/test-c-client-contract.sh` links directly against the selected client
and its released responder fixture. It covers create-time borrowing,
synchronous DNS callbacks, start success and failure, callback identity and
cardinality, deadline behavior, synchronous timeout completion, cancellation,
late datagrams, inflight destruction, and resolver-cancel reentrancy.

The probe is part of `make unit`, the required CI hygiene job, the sanitizer
setup, and the scheduled `rl-c-client/main` drift job. A future lock bump must
make this probe pass before module compilation or lifecycle tests can be used as
compatibility evidence.
