# rl-c-client integration boundary

This document records the nginx adapter contract. It does not redefine the
public C-client API or policy: those belong to the version-matched
`rl-c-client` documentation linked below.

## Supported revision

The module uses the standalone `rl-c-client` repository as its protocol and
client-policy engine. The supported tag and full commit SHA are recorded in
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

## Read the client contract at its source

| Client-owned topic | Authoritative v0.5.0 documentation | nginx-specific consequence |
| --- | --- | --- |
| Logical operations | [Operation Model](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#operation-model) | Each protected main request creates one resource request; a post-response latency report is separate. |
| Integration layer | [Choosing an integration layer](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#choosing-an-integration-layer) | nginx uses the core borrowed API because it already owns UDP, DNS, timers, logging, and request pools. |
| Credentials and quotas | [Credentials](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#credentials) | nginx validates the encoded key at configuration load and uses its latency-buffer quota when `buffer_size` is omitted. |
| State identity | [Content-defined IDs](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#content-defined-ids) | nginx renders names and passes the defining settings to the canonical ID helpers. |
| Delivery and selection | [Resource-Request HA Policy](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#resource-request-ha-policy) | `ratelimitly_timeout` sets `unit_ms`; all other policy fields keep the locked defaults. |
| Discovery | [DNS Refresh](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#dns-refresh) and [I/O abstraction](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/IO_ABSTRACTION.md#dns) | nginx supplies the asynchronous resolver and worker-local UDP adapter. |
| Failure surface | [Error Codes](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#error-codes) | Client failures are mapped through `ratelimitly_fail`; valid denials are never fail-opened. |

The HA policy sends a mutating resource request to every currently usable
member. rl-nginx neither selects one deterministic commit target nor
deduplicates writes across targets. Supported deployments therefore require a
RateLimitly topology whose server/protocol semantics make that fan-out one
logical consumption. This external commit-safety property is not replaced by
an nginx-module fallback.

## What the nginx adapter owns

- It calls `r_client_check_rate_limit_async_borrowed`, retaining rendered
  request inputs in an nginx request pool until callback or cancellation.
- It supplies the I/O and DNS adapters required by `r_client_io.h`; the client
  still owns discovery state, authentication, packets, policy, deadlines, and
  response selection.
- It maps `ratelimitly_timeout` to the default policy's `unit_ms`. With the
  v0.5.0 defaults, the request horizon is `3 * unit_ms`.
- It rearms nginx timers from every deadline returned by the client and treats
  a synchronous completion callback as the end of request-handle validity.
- It defers a requested UDP source-port rebind until no resource request is in
  flight. A later independent latency report does not delay the rebind.
- It maps a selected result into the final nginx admission decision and owns
  all later HTTP latency measurement and reporting eligibility.

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
