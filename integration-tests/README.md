# rl-nginx integration tests

This directory has two deliberately separate test paths: the required public
suite backed by deterministic public fixtures, and an optional internal
full-stack harness for maintainers with access to the private `rl` workspace.

## Public deterministic regressions

Run the complete required public suite from the repository root:

```sh
./integration-tests/public.sh
```

`public.sh` and its lower-level `lifecycle-regressions.sh` runner use only
public dependencies: the locked `rl-c-client` test responder, the local DNS
fixture, nginx, and this module. It does not start a RateLimitly server,
register a tenant, read a credential, or access `../rl`. If the locked C-client
checkout is absent, the public entrypoint fetches its released source through
`tools/fetch-rl-c-client.sh`.

Before nginx lifecycle cases, `make unit` also links a direct compatibility
probe against the selected C client. It binds the callback, borrowed-input,
deadline, timeout, cancel, destroy, and resolver-cancellation behavior on which
the nginx lifecycle adapter depends. The same probe runs against
`rl-c-client/main` in the scheduled drift workflow, so a dependency change can
fail before an nginx worker is involved.

Before running the socket-level cases, test the portable DNS, numeric, and
SRV-record helpers directly:

```sh
python3 integration-tests/test_local_dns_server.py
./tests/test-numeric.sh
RCLIENT_DIR=./_deps/rl-c-client ./tests/test-srv-records.sh
```

The DNS unit builds real query packets without opening a socket and requires
advertised SRV targets to resolve while unadvertised `*.localhost` names return
NXDOMAIN. The numeric unit covers the largest accepted 32-bit protocol values,
the first rejected values, decimal and period-multiplication overflow, and
conversion of an absolute resolver deadline to a remaining DNS TTL.

The SRV unit injects failure at each allocation point. A failed build must free
all partial state and return an empty result, so the C client can never receive
a successful DNS callback containing a null SRV target.

Run all lifecycle cases:

```sh
./integration-tests/lifecycle-regressions.sh
```

`all` means the complete required public lifecycle matrix: the four direct
lifecycle cases plus admission, enforcement boundary, rendered-value, outage,
DNS, guard, protocol, and cardinality groups. Print that manifest without
resolving or building dependencies with `lifecycle-regressions.sh list-all`.
Test-only fault injection remains a separate group because ordinary public
binaries do not contain its configuration directive.

Run one case while developing a fix:

```sh
./integration-tests/lifecycle-regressions.sh timeout
./integration-tests/lifecycle-regressions.sh aborted-client
./integration-tests/lifecycle-regressions.sh steering-rebind
```

Run the final admission contract alone:

```sh
./integration-tests/lifecycle-regressions.sh admission-contract
```

This case proves that an unauthenticated request under `satisfy any` is rejected
without reaching RateLimitly, while an authenticated request consumes exactly
one admission. It also requires `try_files` to select `/ok.txt` before the
RateLimitly request is rendered, then proves that a valid RateLimitly deny is
the final decision before content processing. The case runs under fail-close
and fail-open and also proves that an index-generated internal redirect reuses
one admission, a denial stops content before that redirect, a dependency-error
outcome is not retried after internal routing, and a mirrored subrequest does
not create an independent RateLimitly request.

Run the exact enforcement boundary alone:

```sh
./integration-tests/lifecycle-regressions.sh enforcement-boundary
```

That case configures one stable bucket at `3r/h`, starts a fresh deterministic
quota responder with allowance 3, and requires the sequential result
`200, 200, 200, 429, 429`. It also requires exactly five ordered authenticated
requests containing one resource, worker survival, a successful follow-up,
reload, and clean shutdown. The responder process owns the test counter, so no
wall-clock refill or burst scheduling can change the boundary.

Run rendered-value policy and identifier boundaries alone:

```sh
./integration-tests/lifecycle-regressions.sh rendered-values
```

The matrix runs under fail-close and fail-open. Empty buckets/services,
1025-byte buckets/services, 257-byte labels, and zero dynamic guard thresholds
must take the configured policy without reaching the responder. An empty label
must be omitted, while boundary values of 1024 bytes for buckets/services and
256 bytes for labels must reach it. A unitless threshold of `1` must become
`1000ms`, and the known bucket text
`boundary:known-bucket` at `10000r/s` must produce the pinned canonical
C-client identifier `98300f8a73dd010d75b92ce8d2298cc7` in a one-resource
responder request.

Run the outage-policy matrix separately while working on fail-policy behavior:

```sh
./integration-tests/lifecycle-regressions.sh outage-policy
```

The matrix runs the `outage` case under both `ratelimitly_fail close` and
`ratelimitly_fail open`. Each case establishes a successful baseline, switches
to the responder's `drop` scenario so the module must complete through its
timeout path, requires fail-close to return `429` and fail-open to return
`200`, rejects transport errors, and still verifies worker survival, recovery
through a healthy responder, reload, and clean shutdown.

Run the DNS-policy matrix separately while working on DNS refresh and recovery:

```sh
./integration-tests/lifecycle-regressions.sh dns-policy
```

The matrix runs missing SRV, unresolvable SRV target, and DNS timeout scenarios
under both `ratelimitly_fail close` and `ratelimitly_fail open`. The local DNS
fixture changes mode through a state file while nginx keeps running. Each case
starts nginx with DNS in the selected failure mode, requires the configured
fail-policy result without a transport error, restores normal DNS, waits past
the test resolver refresh interval, and verifies recovery through the same nginx
worker before reload and clean shutdown. DNS timeout recovery waits longer than
NXDOMAIN-style failures because nginx may keep the timed-out resolver state
briefly before issuing a fresh query.

Run the guard/latency matrix separately while working on guard decisions or
post-response latency reporting:

```sh
./integration-tests/lifecycle-regressions.sh guard-latency
```

The matrix covers a passing guard, a denying guard, two guards attached to one
protected location, guard-only allow and deny requests with zero resources,
request-start fail-open, timeout fail-open, and client abort before a verdict.
It verifies the public responder sees the expected guard/resource request
shape, including exact zero-resource cardinality and duplicate-guard
deduplication. Guard denial returns `429`, valid allowed guarded
requests send a post-response `latency_report` with the expected report count,
and every invalid or absent admission suppresses both attempted and delivered
latency reports. Each case still requires worker survival, a valid follow-up,
reload, and clean shutdown.

Run the invalid-UDP ingress fairness case separately while changing the worker
socket handler:

```sh
./integration-tests/lifecycle-regressions.sh udp-ingress-fairness
```

The fixture continuously sends non-RateLimitly datagrams to the worker's
ephemeral UDP port while an HTTP health request completes before the flood ends.
It then requires the original worker to serve a normal rate-limited follow-up,
reload, and shut down cleanly. The executable/specification gates require the
64-datagram budget and next-event repost; this runtime case proves the resulting
event-loop liveness without depending on a scheduler-sensitive debug-log
marker. It does not claim that application-level batching replaces network
flood controls.

Run the malformed-protocol matrix separately while working on response parsing
and fail-policy behavior:

```sh
./integration-tests/lifecycle-regressions.sh protocol-policy
```

The matrix runs invalid response authentication, truncated response packets, and
wrong response request IDs under both `ratelimitly_fail close` and
`ratelimitly_fail open`. Each case requires the configured fail-policy result
without a transport error, verifies the C-client completed through an error
callback instead of accepting the malformed response as valid, then verifies
worker survival, recovery through a healthy responder, reload, and clean
shutdown. Malformed guard/resource counts and empty success arrays are covered
by the response-cardinality matrix below.

Run the complete gate repeatedly with ASan, UBSan, and LeakSanitizer
instrumentation in both the C client and nginx/module code:

```sh
./tools/sanitized-lifecycle.sh
```

The sanitizer runner defaults to three complete passes, preserves each pass's
artifacts under `integration-tests/artifacts/lifecycle-sanitized/`, and restores
the ordinary C-client build before it exits. Set `SANITIZER_RUNS=1` for a quick
local check. One shared flag definition instruments the C client, standalone C
probes, nginx, and all module sources; no sanitizer category is disabled
build-wide. Leak detection remains active for standalone probes and actual
nginx master/worker shutdown. It is disabled only for short-lived `nginx -t`
and `nginx -s` processes, whose upstream exits retain the entire
configuration-cycle pool and would otherwise report the same non-runtime
allocations for every case. UBSan's `nonnull-attribute` category remains
enabled and reports remain recoverable until the final scan. That scan accepts
only the exact, reviewed upstream-nginx diagnostics at
`src/core/ngx_string.c:84` and `src/core/ngx_string.c:586`; every other UBSan
report remains fatal.

The sanitizer build alone enables the non-public
`ratelimitly_test_fault` directive. Each pass runs the `fault-injection` group,
which covers every module-owned SRV/address request allocation, resolver-start
errors, temporary worker-configuration allocation, C-client creation after the
UDP endpoint opens, cleanup after successful C-client creation, and
replacement-socket setup. It also removes the incidental client-read wakeup and
requires an SSI subrequest posted by resumed content processing to complete in
the same event cycle as the RateLimitly verdict. Repeated partial worker-init
failures must be suppressed during bounded backoff and leave zero module UDP
sockets; resolver failures must retain one initialized endpoint; and a failed
rebind must keep the original source port usable. Every admission-affecting
fault must return the exact fail-close status `429`; accepting merely any
non-transport status is not sufficient. The public lifecycle group
also proves that the HTTP-scope resolver and timeout win even when the first
protected location declares a conflicting resolver. Ordinary and deployment
builds do not contain the test-only directive.

Every case establishes a successful baseline, records the single nginx worker
PID, triggers the selected lifecycle path, asserts that the same worker remains
alive, requires a successful follow-up rate-limited request, and checks that
an nginx reload replaces the worker with a functional one before clean shutdown
reports no leaked connection. Requiring `SIGKILL` is a failed clean-shutdown
oracle even when cleanup can subsequently remove the process. The aborted
client case uses delayed responder output so clients close while requests are
in flight; the timeout case uses `drop`; the steering case requests a source
port rebind through response feedback and verifies the port through Linux
`/proc` socket metadata. Its guarded delayed-content probe observes the new
port before log phase, then requires the independent latency report to arrive;
the rebind never waits for source-port continuity with the rate request.

These are acceptance regressions, not an expected-failure wrapper. Each case
must return zero and protects a specific ownership invariant that previously
failed:

- `timeout`: the first deadline must cause exactly one replay, the second must
  enter the receive-only phase, and synchronous completion at the third must be
  the timeout handler's last access to request-owned state; exactly one timeout
  completion is allowed;
- `aborted-client`: resetting a connection must cancel the C-client request and
  timer while balancing the nginx and worker request counts, with no later
  timeout completion;
- `udp-ingress-fairness`: one read callback must not drain unbounded candidate
  datagrams before returning control to nginx;
- `steering-rebind`: source-port replacement must run in a deferred worker
  event after the UDP read callback unwinds, and an independent latency report
  remains valid after that replacement.

Run the response-cardinality matrix separately while working on result
validation:

```sh
./integration-tests/lifecycle-regressions.sh cardinality
```

The matrix sends authenticated successful responses with empty, short, and
extra result arrays. Each scenario runs under both configured failure policies:
fail-close must return 429 and fail-open must return 200. Every mismatch must be
logged before any returned guard or resource entry is evaluated, and every case
still requires worker survival, a valid follow-up, reload, and clean shutdown.

Diagnostic artifacts are preserved under
`integration-tests/artifacts/lifecycle/<case>/`; the commands above are the
passing acceptance gate for lifecycle changes.

## Live production protocol smoke

`production-smoke.sh` is the only test in this repository that reaches the
RateLimitly production fleet. It is a protocol proof, not a load test, and it
is deliberately outside `make check` and `make test` so both stay runnable
without a credential:

```sh
RATELIMITLY_AUTH_KEY='rl-aes1...' \
RATELIMITLY_P0_TEST_NAMESPACE="local-$(date +%s)" \
make production-smoke
```

It builds nginx with this module, starts nginx against production, and drives
real HTTP requests through the ordinary pre-content admission path. Two
authenticated server-side facts must hold:

1. **Latency read-back.** One deliberately slow admitted request reports its
   measured latency to a per-run tracker through `ratelimitly_report`. Polling
   then alternates between an identically configured control tracker that was
   never given a report and the reported one, so both stay on the same number
   of guard evaluations. The reported guard must deny at a `1000ms` threshold
   on an evaluation where the control guard still admits. The reported sample
   is the only difference between the two, so that denial can only come from
   production storing the sample and returning it.

   The comparison holds only at equal evaluation counts. A tracker configured
   this narrowly (`max_samples=1 min_sample_threshold=1`) warms
   up from admissions alone, so the control guard does start denying an
   evaluation or two later; that says nothing about the report. Do not add a
   trailing control check.
2. **Rate denial.** A one-token bucket must admit once and reject the next
   request.

Every decision is asserted as an HTTP status *and* a `$ratelimitly_verdict`.
Fail-close also returns `429`, and both failure policies leave the verdict
unset, so a transport or discovery failure can never be mistaken for an
authenticated allow or deny.

Discovery comes from the credential alone. The generated configuration declares
no `ratelimitly_dns_srv` and no `ratelimitly_dns_resolver`, so nginx resolves
`c-<api-key-id>.p0.ratelimitly.com` through the system resolver, and the script
refuses to run when `RATELIMITLY_TENANT`,
`RATELIMITLY_EXAMPLE_SERVER_HOST`, or `RATELIMITLY_EXAMPLE_SERVER_PORT` is set.

Buckets and trackers are scoped by `RATELIMITLY_P0_TEST_NAMESPACE`, so
concurrent runs cannot collide. A missing or malformed credential, a missing
namespace, and an unreachable fleet all fail loudly; the script never reports
success without an authenticated allow and an authenticated deny.

The generated configuration embeds the API key, so the run directory is a
private `mkdtemp` with mode `0700`, is removed on exit unless
`KEEP_ARTIFACTS=1`, and is never published as a CI artifact. Diagnostics
printed on failure are limited to module and nginx log lines, which contain the
API key id and request ids but never the credential.

In CI this runs as the `production-smoke` job in `ci.yml`. That job is pinned to
`main`, runs for pushes or a maintainer's manual dispatch only, owns a
`rl-nginx-production-smoke` concurrency group with `cancel-in-progress: false`,
and reads the credential as step-level environment beside a
`ci-<run_id>-<run_attempt>` namespace. `tests/test-ci-gates.py` keeps every one
of those properties red-case tested and keeps all required jobs secret-free.

## Internal full-stack harness (optional)

`internal-full-stack.sh` is not part of the public contributor or release
gate. Its local mode requires access to the private `rl` repository and tenant
management tooling. The harness builds and runs these local components:

- `rl-c-client`, used by the nginx module, from the locked `./_deps` checkout
  or an explicit `RCLIENT_DIR` development override.
- `rlnet`, from `../rl/xdp`, when the static library is not already built.
- `ratelimitly-server`, from `../rl/implementations/rust` by default.
- nginx, from the `upstream-nginx` submodule, with this repo's module added.
- a small local DNS server that serves SRV and localhost A/AAAA records.
- a generated nginx config with one permissive route and one rate-limited route.

The burst oracle permits only `200` on the allow route and the expected
`200`/`429` quota split on the deny route. Transport failures, `5xx`, an allow
route denial, and any status in the computed `other` bucket fail instead of
being printed and ignored.

## Quick run

Run from the `rl-nginx` repo root:

```sh
./integration-tests/internal-full-stack.sh
```

If the default ports are already in use, override them:

```sh
DNS_PORT=53536 \
RL_SERVER_PORT=39080 \
NGINX_PORT=18088 \
./integration-tests/internal-full-stack.sh
```

Show script help:

```sh
./integration-tests/internal-full-stack.sh --help
```

## External server run

When a Ratelimitly test server and tenant key already exist, run against the
published tenant SRV record instead of starting a local Rust server:

```sh
EXTERNAL_SERVER=1 \
DOMAIN='<tenant-domain>' \
TENANT_KEY='<rl-aes-or-rl-cookie-key>' \
./integration-tests/internal-full-stack.sh
```

External mode still builds `rl-c-client` and nginx locally, but skips local
Rust server startup, tenant registration, and the local DNS server. The script
uses `DNS_SERVER`/`DNS_PORT` when set; otherwise it uses the first resolver from
`/etc/resolv.conf` on port `53`. The generated nginx config defaults to
`ipv6=off` resolver options because the public test SRV target is IPv4-only.

External mode also uses a more conservative default load profile:

```sh
RATELIMITLY_POLICY_UNIT=1000ms ALLOW_REQUESTS=20 DENY_REQUESTS=80 PARALLELISM=5
```

Override those values when testing a dedicated server or a lower-latency
network path.

## Expected repository layout

The default layout assumes `rl-nginx` and `rl` are siblings in the umbrella
workspace:

```text
glar/
  rl-nginx/
  rl/
    implementations/rust/
    tenant_management/elixir/
    xdp/
```

Relative to `rl-nginx`, the Rust server source is expected at:

```text
../rl/implementations/rust
```

Override paths with environment variables when needed:

```sh
RL_ROOT=/path/to/rl ./integration-tests/internal-full-stack.sh
RL_RUST_ROOT=/path/to/rl/implementations/rust ./integration-tests/internal-full-stack.sh
```

## Prerequisites

The script checks for these commands before running:

- `cargo`
- `cmake`
- `curl`
- `dig`
- `elixir`
- `make`
- `python3`

The nginx source submodule must be present and up to date:

- `./upstream-nginx`

The test fetches or verifies the supported C client under
`./_deps/rl-c-client`. It never selects an adjacent checkout implicitly; use
`RCLIENT_DIR=/path/to/rl-c-client` for an intentional development override.

The test also expects the tenant-management Elixir CLI source under
`../rl/tenant_management/elixir`.

## What the script does

The internal script orchestrates its required processes. It does not require
an already running Ratelimitly server, nginx instance, or local DNS setup, but
it does require the private source and tenant-management paths described above.

1. Cleans previous integration-test artifact files.
2. Builds `rl-c-client` with `make clean` and `make`.
3. Ensures the local static `rlnet` library exists:
   `../rl/xdp/build-static/src/librlnet.a`.
4. Builds the Rust server:

   ```sh
   cargo build --release --features full --bin ratelimitly-server \
     --manifest-path ../rl/implementations/rust/Cargo.toml
   ```

5. Builds nginx with the `rl-nginx` module by calling:

   ```sh
   ./tests/build-nginx.sh ./upstream-nginx --clean --debug
   ```

6. Starts `ratelimitly-server` on the configured port with
   `RLNET_DISABLE_XDP=1`. The server has no host-address CLI option.
7. Waits until the server reports its `server_id`, the expected port, and its
   XDP-ready marker.
8. Registers a temporary tenant through the Elixir tenant-management CLI.
9. Starts `local_dns_server.py` on localhost.
10. Verifies DNS with a SRV lookup for `_ratelimitly._udp.<domain>`.
11. Writes a generated nginx config under `integration-tests/artifacts/`.
12. Runs `nginx -t` against the generated config.
13. Starts nginx in the foreground, managed by the script.
14. Waits for nginx to answer on the unprotected `/health` endpoint.
15. Warms the Ratelimitly client by probing `/allow` until a real module
    decision is logged.
16. Sends burst traffic to `/allow` and `/deny`.
17. Asserts HTTP status counts and nginx `rn:` decision logs.
18. Stops nginx, the DNS server, and the Ratelimitly server on exit.

With `EXTERNAL_SERVER=1`, steps 3, 6, 8, and 9 are skipped. The DNS check uses
the real `_ratelimitly._udp.<domain>` SRV record.

## Generated DNS

The test domain defaults to:

```text
rn-itest.local
```

The script starts a local UDP DNS server and serves:

- SRV records for `_ratelimitly._udp.rn-itest.local`.
- A records for the exact advertised SRV targets, pointing to `127.0.0.1`.
- AAAA records for the exact advertised SRV targets, pointing to `::1`.

Every other name, including plain `localhost` and unadvertised `*.localhost`
names, returns NXDOMAIN so malformed target construction cannot be hidden by
the fixture.

The SRV target format is:

```text
s-<server_id>.localhost
```

The generated nginx config points nginx's resolver at this DNS server:

```nginx
resolver 127.0.0.1:<DNS_PORT> valid=1s ipv6=off;
```

## Generated nginx test config

The generated config defines:

```nginx
ratelimitly_dns_srv  rn-itest.local;
ratelimitly_auth_key <temporary tenant key>;
ratelimitly_policy standard unit=100ms;
ratelimitly_fail     close;
ratelimitly_debug    on;

ratelimitly_zone allow_zone "bucket=v1|fixture=allow" rate=10000r/s;
ratelimitly_zone deny_zone  "bucket=v1|fixture=deny"  rate=1r/s;
```

It exposes three local endpoints:

- `/health`: unprotected nginx readiness endpoint, expected to return `204`.
- `/allow`: high quota, expected to return only successful HTTP responses.
- `/deny`: low quota, expected to return at least some `429` responses.

Both locations serve `tests/ok.txt` through `try_files`. This is intentional:
using a direct `return 200` handler can finalize the request before the
module's pre-content admission point.

## Success criteria

The test passes when:

- `/allow` has at least one `200`.
- `/allow` has zero `429`, zero `000`, zero `5xx`, and zero `other`.
- `/deny` has at least one `429`.
- `/deny` has zero `000`, zero `5xx`, and zero `other`.
- nginx debug log contains at least one `rn: result success=1`.
- nginx debug log contains at least one `rn: result success=0`.

With defaults, a successful run commonly looks like:

```text
allow  requests=50   200=50  429=0    5xx=0  000=0  other=0
deny   requests=200  200=1   429=199  5xx=0  000=0  other=0
```

The exact split for `/deny` may vary slightly. The important assertion is that
the route is actively rate-limited and no transport or server errors occurred.

## Environment overrides

Common overrides:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RL_ROOT` | `../rl` | Root of the `rl` repo. |
| `RL_RUST_ROOT` | `$RL_ROOT/implementations/rust` | Rust server crate root. |
| `RL_SERVER_BIN` | `$RL_RUST_ROOT/target/release/ratelimitly-server` | Server binary to run after build. |
| `RCLIENT_DIR` | locked `./_deps/rl-c-client` | Explicit C client override; the default is fetched or verified against the repository lock. |
| `NGINX_SRC` | `./upstream-nginx` | nginx source submodule path. |
| `NGINX_BIN` | `$NGINX_SRC/objs/nginx` | Built nginx binary. |
| `EXTERNAL_SERVER` | `0` | Set to `1` to use an already-running server and existing tenant key. |
| `DOMAIN` | `rn-itest.local` | Tenant DNS name used by nginx and local DNS. |
| `DNS_SERVER` | `127.0.0.1` | Local DNS bind address. |
| `DNS_PORT` | `53535` | Local DNS UDP port. |
| `NGINX_RESOLVER_OPTIONS` | `ipv6=off` | Extra nginx resolver options in the generated test config. |
| `RL_HOST` | `127.0.0.1` | Address used by tenant registration to reach the local server; this is not passed to the server as a bind option. |
| `RL_SERVER_PORT` | `39080` | Ratelimitly server UDP port. |
| `RL_NODE_ID` | `11` | Server node id passed to `ratelimitly-server`. |
| `NGINX_HOST` | `127.0.0.1` | nginx listen address. |
| `NGINX_PORT` | `18088` | nginx HTTP listen port. |
| `TENANT_AUTH` | `aes` | Auth mode used by tenant registration. |
| `TENANT_ID` | timestamp-derived | Temporary tenant id. |
| `TENANT_SEED` | `tenant-seed-$TENANT_ID` | Temporary tenant credential seed. |
| `TENANT_KEY` | empty | Existing tenant key, required when `EXTERNAL_SERVER=1`. |
| `RATELIMITLY_POLICY_UNIT` | `100ms` local, `1000ms` external | Base unit of the generated `standard` request policy. |
| `ALLOW_REQUESTS` | `50` local, `20` external | Requests sent to `/allow`. |
| `DENY_REQUESTS` | `200` local, `80` external | Requests sent to `/deny`. |
| `PARALLELISM` | `20` local, `5` external | `xargs -P` curl concurrency. |
| `CLIENT_TIMEOUT_SEC` | `30` | curl max-time for readiness and burst requests. |

The optional first positional argument overrides only the synthetic local
Ratelimitly server's shared secret:

```sh
./integration-tests/internal-full-stack.sh rl-secret...
```

The same value can also be supplied with `SECRET`.
Use the built-in test value for an isolated local run; never put a production
secret in this argument because command arguments can be exposed through shell
history and process inspection.

## Artifacts

Runtime files are written under:

```text
integration-tests/artifacts/
```

This directory is ignored by git. Important files:

| File | Purpose |
| --- | --- |
| `test.log` | Combined script output. |
| `rl-server.log` | Ratelimitly server output. |
| `tenant-register.log` | Tenant CLI output and generated API key. |
| `dns.log` | Local DNS server output. |
| `dns-check.log` | SRV lookup output from `dig`. |
| `nginx.conf` | Generated nginx config. |
| `nginx-error.log` | nginx debug/error log, including `rn:` decision lines. |
| `allow.codes` | HTTP status codes from the `/allow` burst. |
| `deny.codes` | HTTP status codes from the `/deny` burst. |
| `results.tsv` | Per-scenario status summary. |

The harness applies `umask 077` and mode `0700` to the artifact directory
because `test.log`, `tenant-register.log`, and `nginx.conf` contain the
generated tenant key. Artifacts are cleaned at the start of each run, but the
ignored directory is not a durable secret store: use only temporary test
credentials, do not publish it as a CI artifact, and remove it when the
investigation is complete.

## Troubleshooting

### Port already in use

Use different local ports:

```sh
DNS_PORT=53536 \
RL_SERVER_PORT=39081 \
NGINX_PORT=18089 \
./integration-tests/internal-full-stack.sh
```

### Missing `dig`

Install the package that provides `dig` for your OS. On many Linux
distributions this is part of `bind-utils` or `dnsutils`.

### nginx config test fails

Inspect:

```sh
less integration-tests/artifacts/nginx.conf
less integration-tests/artifacts/nginx-error.log
```

The generated config should use `ratelimitly_fail close`; valid module values
are `open` and `close`.

### No `429` responses

Check whether nginx actually reached the module decision path:

```sh
rg 'rn: result success=' integration-tests/artifacts/nginx-error.log
```

If there are no `rn:` result lines, inspect the generated location config. The
test should use `try_files`, not `return 200`, for the test endpoints.

### DNS discovery problems

Check the DNS artifact files:

```sh
cat integration-tests/artifacts/dns-check.log
cat integration-tests/artifacts/dns.log
```

The SRV response should include the current server port and a target like
`s-<server_id>.localhost`.

### Server registration problems

Inspect:

```sh
less integration-tests/artifacts/rl-server.log
less integration-tests/artifacts/tenant-register.log
```

The script verifies that the tenant registration ACK `server_id` matches the
server id printed by the local `ratelimitly-server`.

## Relationship to `tests/`

The `tests/` directory still contains lower-level manual helpers and
diagnostics:

- `tests/build-nginx.sh`
- `tests/burst-test.sh` (manual diagnostic; not a required pass/fail test)
- `tests/nginx.conf`
- `tests/smoke-test.sh` (manual diagnostic; not a required pass/fail test)

The internal full-stack test reuses `tests/build-nginx.sh`, but generates its own
nginx config, tenant key, DNS records, and runtime processes. Use
`integration-tests/public.sh` for the required contributor gate and
`integration-tests/internal-full-stack.sh` only for optional private full-stack
validation.
