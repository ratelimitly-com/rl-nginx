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

- The C client sends a mutating rate request to every currently usable
  discovered endpoint. rl-nginx neither selects one deterministic commit target
  nor deduplicates writes across targets. Supported deployments must supply a
  RateLimitly topology whose server/protocol semantics make that fan-out one
  logical consumption. There is no nginx-module fallback for a topology that
  lacks this external commit-safety property.
- DNS discovery and refresh behavior is owned by the locked C client.
  rl-nginx supplies nginx resolver adapters and `resolver_timeout` but exposes
  no refresh-interval or TTL policy directive. A lock update that changes this
  behavior requires the compatibility review and specification update described
  below.
- Use `r_client_check_rate_limit_async_borrowed` to avoid per-request copies.
- nginx sets the C-client scheduling unit through `ratelimitly_timeout`
  (default 20ms). The locked policy performs one replay plus one final
  receive-only interval and enables best-effort completion delivery.
- Steering feedback is evaluated per response; rebind the UDP socket after all
  current in-flight RateLimitly requests complete if any response requested a
  port change. Latency reports are independent fire-and-forget requests, not
  continuations of those rate requests, so a rebind never waits for a later
  report.

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
4. `r_client_request_deadline_ms` succeeds for a live request. Calling
   `r_client_on_timeout` before a reported deadline leaves the request pending.
   On the no-response path, at the first deadline it performs the configured
   replay; at the second it enters the final receive-only interval; at the
   third it invokes the timeout callback synchronously and exactly once. Any
   valid response may change the next deadline or complete earlier, and the
   request handle is invalid as soon as the callback completes.
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
   socket from either the rate callback or UDP read callback. The scheduled
   event is the earliest safe source-port replacement point. A later latency
   report has no source-port continuity requirement and must not delay it.

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
