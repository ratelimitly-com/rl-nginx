# rl-nginx integration test

This directory contains an end-to-end local integration test for the nginx
Ratelimitly module. The test replaces the older manual flow of starting nginx,
running `tests/burst-test.sh`, and inspecting rates by hand.

## Public deterministic regressions

`lifecycle-regressions.sh` uses only public dependencies: the locked
`rl-c-client` test responder, the local DNS fixture, nginx, and this module. It
does not start the private RateLimitly server or register a tenant.

Run all lifecycle cases:

```sh
./integration-tests/lifecycle-regressions.sh
```

Run one case while developing a fix:

```sh
./integration-tests/lifecycle-regressions.sh timeout
./integration-tests/lifecycle-regressions.sh aborted-client
./integration-tests/lifecycle-regressions.sh steering-rebind
```

Run the complete gate repeatedly with ASan and UBSan instrumentation in both
the C client and nginx/module code:

```sh
./tools/sanitized-lifecycle.sh
```

The sanitizer runner defaults to three complete passes, preserves each pass's
artifacts under `integration-tests/artifacts/lifecycle-sanitized/`, and restores
the ordinary C-client build before it exits. Set `SANITIZER_RUNS=1` for a quick
local check. The C client receives the complete ASan/UBSan set. The nginx build
disables only UBSan's `nonnull-attribute` category because nginx's core string
formatter intentionally passes a null source with zero length for an empty
query string; all other undefined-behavior checks remain enabled.

Every case establishes a successful baseline, records the single nginx worker
PID, triggers the selected lifecycle path, asserts that the same worker remains
alive, requires a successful follow-up rate-limited request, and checks that
an nginx reload replaces the worker with a functional one before clean shutdown
reports no leaked connection. The aborted client case uses delayed responder
output so clients close while requests are in flight; the timeout case uses
`drop`; the steering case requests a source port rebind through response
feedback and verifies the port through Linux `/proc` socket metadata.

These are acceptance regressions, not an expected-failure wrapper. Each case
must return zero and protects a specific ownership invariant that previously
failed:

- `timeout`: synchronous C-client completion must be the timeout handler's last
  access to request-owned state;
- `aborted-client`: resetting a connection must cancel the C-client request and
  timer while balancing the nginx and worker request counts;
- `steering-rebind`: source-port replacement must run in a deferred worker
  event after the UDP read callback unwinds.

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

The test builds and runs the real local components:

- `rl-c-client`, used by the nginx module, from the locked `./_deps` checkout
  when present, with a sibling development checkout as a fallback.
- `rlnet`, from `../rl/xdp`, when the static library is not already built.
- `ratelimitly-server`, from `../rl/implementations/rust` by default.
- nginx, from the `upstream-nginx` submodule, with this repo's module added.
- a small local DNS server that serves SRV and localhost A/AAAA records.
- a generated nginx config with one permissive route and one rate-limited route.

## Quick run

Run from the `rl-nginx` repo root:

```sh
./integration-tests/test.sh
```

If the default ports are already in use, override them:

```sh
DNS_PORT=53536 RL_SERVER_PORT=39080 NGINX_PORT=18088 ./integration-tests/test.sh
```

Show script help:

```sh
./integration-tests/test.sh --help
```

## External server run

When a Ratelimitly test server and tenant key already exist, run against the
published tenant SRV record instead of starting a local Rust server:

```sh
EXTERNAL_SERVER=1 \
DOMAIN=c-5107024729143590554.p0.ratelimitly.com \
TENANT_KEY='<rl-aes-or-rl-cookie-key>' \
./integration-tests/test.sh
```

External mode still builds `rl-c-client` and nginx locally, but skips local
Rust server startup, tenant registration, and the local DNS server. The script
uses `DNS_SERVER`/`DNS_PORT` when set; otherwise it uses the first resolver from
`/etc/resolv.conf` on port `53`. The generated nginx config defaults to
`ipv6=off` resolver options because the public test SRV target is IPv4-only.

External mode also uses a more conservative default load profile:

```sh
RATELIMITLY_TIMEOUT=1000ms ALLOW_REQUESTS=20 DENY_REQUESTS=80 PARALLELISM=5
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
RL_ROOT=/path/to/rl ./integration-tests/test.sh
RL_RUST_ROOT=/path/to/rl/implementations/rust ./integration-tests/test.sh
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

Fetch the supported C client with `./tools/fetch-rl-c-client.sh`. The test uses
`./_deps/rl-c-client` when present, falls back to `../rl-c-client` for existing
development workspaces, and accepts `RCLIENT_DIR=/path/to/rl-c-client` as an
explicit override.

The test also expects the tenant-management Elixir CLI source under
`../rl/tenant_management/elixir`.

## What the script does

The script is intentionally self-contained. It does not require an already
running Ratelimitly server, nginx instance, or local DNS setup.

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

6. Starts `ratelimitly-server` on localhost with `RLNET_DISABLE_XDP=1`.
7. Waits until the server prints its `server_id` and readiness marker.
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
- A records for `localhost` and `*.localhost` pointing to `127.0.0.1`.
- AAAA records for `localhost` and `*.localhost` pointing to `::1`.

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
ratelimitly_tenant   rn-itest.local;
ratelimitly_auth_key <temporary tenant key>;
ratelimitly_timeout  100ms;
ratelimitly_fail     close;
ratelimitly_debug    on;

ratelimitly_zone allow_zone bucket="allow:$uri" rate=10000r/s;
ratelimitly_zone deny_zone  bucket="deny:$uri"  rate=1r/s;
```

It exposes three local endpoints:

- `/health`: unprotected nginx readiness endpoint, expected to return `204`.
- `/allow`: high quota, expected to return only successful HTTP responses.
- `/deny`: low quota, expected to return at least some `429` responses.

Both locations serve `tests/ok.txt` through `try_files`. This is intentional:
using a direct `return 200` content handler can bypass the module's access-phase
decision path.

## Success criteria

The test passes when:

- `/allow` has at least one `200`.
- `/allow` has zero `429`, zero `000`, and zero `5xx`.
- `/deny` has at least one `429`.
- `/deny` has zero `000` and zero `5xx`.
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
| `RCLIENT_DIR` | `./_deps/rl-c-client`, then `../rl-c-client` | C client checkout path. |
| `NGINX_SRC` | `./upstream-nginx` | nginx source submodule path. |
| `NGINX_BIN` | `$NGINX_SRC/objs/nginx` | Built nginx binary. |
| `EXTERNAL_SERVER` | `0` | Set to `1` to use an already-running server and existing tenant key. |
| `DOMAIN` | `rn-itest.local` | Tenant DNS name used by nginx and local DNS. |
| `DNS_SERVER` | `127.0.0.1` | Local DNS bind address. |
| `DNS_PORT` | `53535` | Local DNS UDP port. |
| `NGINX_RESOLVER_OPTIONS` | `ipv6=off` | Extra nginx resolver options in the generated test config. |
| `RL_HOST` | `127.0.0.1` | Ratelimitly server bind address. |
| `RL_SERVER_PORT` | `39080` | Ratelimitly server UDP port. |
| `RL_NODE_ID` | `11` | Server node id passed to `ratelimitly-server`. |
| `NGINX_HOST` | `127.0.0.1` | nginx listen address. |
| `NGINX_PORT` | `18088` | nginx HTTP listen port. |
| `TENANT_AUTH` | `aes` | Auth mode used by tenant registration. |
| `TENANT_ID` | timestamp-derived | Temporary tenant id. |
| `TENANT_SEED` | `tenant-seed-$TENANT_ID` | Temporary tenant credential seed. |
| `TENANT_KEY` | empty | Existing tenant key, required when `EXTERNAL_SERVER=1`. |
| `RATELIMITLY_TIMEOUT` | `100ms` local, `1000ms` external | Module timeout written to the generated nginx config. |
| `ALLOW_REQUESTS` | `50` local, `20` external | Requests sent to `/allow`. |
| `DENY_REQUESTS` | `200` local, `80` external | Requests sent to `/deny`. |
| `PARALLELISM` | `20` local, `5` external | `xargs -P` curl concurrency. |
| `CLIENT_TIMEOUT_SEC` | `30` | curl max-time for readiness and burst requests. |

The optional first positional argument overrides the shared Ratelimitly server
secret:

```sh
./integration-tests/test.sh rl-secret...
```

The same value can also be supplied with `SECRET`.

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

Artifacts are cleaned at the start of each run.

## Troubleshooting

### Port already in use

Use different local ports:

```sh
DNS_PORT=53536 RL_SERVER_PORT=39081 NGINX_PORT=18089 ./integration-tests/test.sh
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

The `tests/` directory still contains lower-level manual helpers:

- `tests/build-nginx.sh`
- `tests/burst-test.sh`
- `tests/nginx.conf`
- `tests/smoke-test.sh`

The integration test reuses `tests/build-nginx.sh`, but generates its own
nginx config, tenant key, DNS records, and runtime processes. Use
`integration-tests/test.sh` when you want a reproducible local end-to-end check.
