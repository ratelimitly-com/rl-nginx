# rl-nginx test harness

This optional manual harness shows how to build nginx with the rl-nginx module,
run it with a test config, and validate traffic against a running RateLimitly
service. It is not a public acceptance gate: use `make check` for deterministic
static contributor tests that need no service, tenant, or credential, then use
the separately documented dynamic and sanitizer gates for release evidence.

This requires the locked public `rl-c-client` release so nginx can link against
the compiled C client library. Build and test helpers fetch or verify that
release automatically when `RCLIENT_DIR` is not set.

The default locked checkout must be clean as well as pinned to the exact
commit. Use an explicit `RCLIENT_DIR` for an intentionally modified development
tree.

## 1) Build rl-c-client

```sh
./tools/fetch-rl-c-client.sh
export RCLIENT_DIR=./_deps/rl-c-client
make -C "$RCLIENT_DIR"
```

## 2) Build nginx with the rl-nginx module

**Static module (simplest):**

```sh
/path/to/nginx-src/auto/configure \
  --add-module=.

make -C /path/to/nginx-src -j
sudo make -C /path/to/nginx-src install
```

**Dynamic module:**

```sh
/path/to/nginx-src/auto/configure \
  --add-dynamic-module=.

make -C /path/to/nginx-src modules
```

A public helper script is provided (pass the nginx repo root, not `/src`):

```sh
./tools/build-nginx.sh /path/to/nginx-src
# or
./tools/build-nginx.sh /path/to/nginx-src --dynamic --compat
# clean rebuild
./tools/build-nginx.sh /path/to/nginx-src --clean
```

After a dynamic build, validate that the module can be copied and loaded from
an isolated runtime tree without a C-client shared library or workspace runtime
path:

```sh
make dynamic-relocation-test NGINX_SRC=/path/to/nginx-src
```

After building, run the configuration validation matrix:

```sh
RCLIENT_DIR=./_deps/rl-c-client ./tests/test-config.sh
```

The matrix uses isolated `nginx -t` configurations. It covers representative
valid configuration, required tenant and credentials, static numeric syntax
and bounds, empty names/references, order-independent duplicate flags,
whole-argument named-value quoting, and the intentional acceptance of
`min_sample_threshold=0`. It binds the inclusive 1024-byte bucket/service and
256-byte label limits, positive duration rules, and unitless-seconds grammar.
It also verifies that variable-driven values are deferred to request-time
validation. Cases that enable the module use isolated Unix sockets; no nginx
worker is started.

`test-addr-records.sh` exercises the pure resolver-address compactor. It mixes
IPv4/IPv6 answers with null, empty, and oversized inputs and requires the
reported count and output order to contain only usable addresses.

`test-resolv-conf.sh` exercises the pure `/etc/resolv.conf` nameserver reader.
It requires an IPv6 nameserver to reach nginx bracketed, IPv4 nameservers and
host names to survive unchanged, comments and non-`nameserver` lines to be
ignored, and an entry nginx cannot parse — a zone-scoped address, an
unterminated bracket, or a value larger than the output buffer — to be reported
instead of passed through.

`test-c-client-contract.sh` links to the selected C client and its released
responder protocol fixture. It makes the module's otherwise out-of-tree
assumptions executable: create-time borrowing, non-callback start errors,
asynchronous successful start, guard-only zero-resource request and callback
cardinality, callback identity and lifetime, deadline and
synchronous timeout behavior, callback-free cancel/destroy, late-response
suppression, and resolver-cancel reentrancy. It runs against the lock in
required CI and against `rl-c-client/main` in the scheduled drift workflow.

## Required oracle self-tests

`make unit` includes negative fixtures for the repository's own gates. They
prove an invalid early shell script, failed explicit client resolution, and
committed whitespace all fail; reject a dirty default client while allowing an
explicit dirty override; remove each required CI command, diverge the nginx
gitlink from its matrix, remove native Arm or stable-line sanitizer coverage,
weaken drift permissions, float an action/container, disable runtime leak
detection or broaden a sanitizer exclusion, and disable executable C defaults
to prove the meta-checks reject those mutations. They also require `make check`
to reuse its requested static binary and exercise exact HTTP-status,
forced-shutdown, complete lifecycle-manifest, and DNS-timeout oracles. These
tests require no nginx worker or remote service.

## 3) Run nginx with the test config

Edit the config first:

- `./tests/nginx.conf`

Then run:

```sh
# Recommended: build+run helper from repo root (foreground)
./start-nginx.sh

# Or run an existing nginx binary directly
sudo /usr/local/nginx/sbin/nginx -c ./tests/nginx.conf

# Or use the thin run helper
./tests/run-nginx.sh /usr/local/nginx/sbin/nginx ./tests/nginx.conf
```

If you built a dynamic module, remember to uncomment `load_module` in the test
config.

`start-nginx.sh` notes:
- Builds with debug support by default.
- Use `--no-debug` to skip debug build.
- Emits logs to both `stderr` and `./logs/error.log`.

## 4) DNS SRV/A setup

The r-client requires SRV discovery via `_ratelimitly._udp.<tenant>`.
Use A/AAAA records only for the SRV target hostnames returned by that lookup, and use your existing dnsmasq setup to serve those local SRV entries.

## 5) Verify

```sh
curl -v 'http://127.0.0.1:8088/api/static/test'
curl -v 'http://127.0.0.1:8088/api/dynamic/read'
curl -v -X POST 'http://127.0.0.1:8088/api/dynamic/write'
curl -v 'http://127.0.0.1:8088/api/group/test'
curl -v 'http://127.0.0.1:8088/api/guard/test'
curl -v 'http://127.0.0.1:8088/api/guard-isolated/permissive'
curl -v 'http://127.0.0.1:8088/api/guard-isolated/strict'
```

The fixture deliberately does not put raw URI, host, query-argument, header,
or cookie values into RateLimitly buckets, services, rates, thresholds, or
labels. Its original-request-target and method maps have finite
operator-controlled outputs, so the examples remain bounded even though a
client chooses the request path and method. Using `$request_uri` only as the
map input also keeps the selected class stable after `try_files` rewrites
`$uri`; the raw value itself never reaches RateLimitly. The access log writes
`rl_verdict=allow` or `rl_verdict=deny` only for a valid RateLimitly verdict;
`rl_verdict=-` is not a successful warmup.

If `ratelimitly_debug on` is set, you will see detailed `rn:` logs in the nginx
error log (SRV targets, A/AAAA addresses, bucket IDs, UDP recv/decisions).

Guard test path note:
- `/api/guard/test` and both `/api/guard-isolated/*` locations `proxy_pass` to a local backend on `127.0.0.1:18089` defined in `./tests/nginx.conf`.
- This makes guard tests measure end-to-end proxy latency instead of local static-file serving only.
- The backend endpoint `/backend/ok.txt` returns explicit HTTP `200` for clean burst-test accounting.
- Latency reports sent by the nginx module clamp observed latency to minimum `1ms` (avoids `0ms` artifacts).
- The module sends those reports only after a valid RateLimitly allow; denial,
  fail-open/fail-close errors, missing verdicts, timeouts, and aborted clients
  do not add latency samples.

## 6) Smoke diagnostic helper

This script samples one request and prints recent `rn:` debug lines. It is a
manual diagnostic helper, not a required pass/fail test. Use
`../integration-tests/public.sh` for the public readiness gate.

```sh
./tests/smoke-test.sh http://127.0.0.1:8088/api/static/test ./logs/error.log
```

## 7) Burst diagnostic helper

This script sends traffic bursts and reports observed HTTP and `rn:` counters.
It is a manual diagnostic helper, not a required pass/fail test; it exits
nonzero for invocation/tooling failures but does not enforce traffic
expectations. Use `../integration-tests/public.sh` for deterministic behavioral
coverage.

```sh
# Defaults:
#   BASE_URL=http://127.0.0.1:8088
#   BURST_SIZE=1000
#   PARALLELISM=50
#   NGINX_ERR_LOG=./logs/error.log (auto-fallback: /usr/local/nginx/logs/error.log)
./tests/burst-test.sh

# Explicit values
./tests/burst-test.sh http://127.0.0.1:8088 1000 50 ./logs/error.log
```

Reported counters:
- `200`: successful HTTP responses.
- `429`: rate-limited responses.
- `404`: not found responses.
- `5xx`: upstream/server-side HTTP errors.
- `other`: any other non-200/non-429/non-404/non-5xx/non-000 codes.
- `000`: curl transport failures (no HTTP response code).
- `rn_allow`: count of `rn: result success=1` in log lines captured for the burst window.
- `rn_deny`: count of `rn: result success=0` in log lines captured for the burst window.
- `timeout_status`: count of `rn: result error status=-2` (timeout).
- `error_status`: count of any `rn: result error status=...`.

Interpretation note:
- With `ratelimitly_fail open` and `ratelimitly_debug on`, `timeout_status` approximates fail-open timeout allowances.
- If `429` is high and `000` is zero, requests reached nginx and were denied by policy (not network failures).

Current default scenarios in script:
- `static`
- `dynamic read`
- `dynamic write`
- `group`
- `guard`
- `guard-isolated permissive` (high-rate zone to reduce rate-limit noise)
- `guard-isolated strict` (same high-rate zone with strict guard threshold)

Show script help:

```sh
./tests/burst-test.sh -h
```

## 8) Troubleshooting Logs

If you see logs on console but not in `./logs/error.log`, or `rn_allow/rn_deny` stay `0`:

1. Ensure nginx was started with `./start-nginx.sh` (it configures dual logging).
2. Confirm the running master command includes:
   - `error_log stderr debug;`
   - `error_log logs/error.log debug;`

```sh
ps -ef | rg 'nginx: master process'
```

3. Verify file log is actually moving:

```sh
stat -c '%y %s' ./logs/error.log
curl -s -o /dev/null 'http://127.0.0.1:8088/api/group/test'
stat -c '%y %s' ./logs/error.log
```

4. Verify rn decision lines exist:

```sh
tail -n 200 ./logs/error.log | rg 'rn: result success=|rn: result error status='
```

5. If needed, pass log path explicitly to burst test:

```sh
./tests/burst-test.sh http://127.0.0.1:8088 1000 50 ./logs/error.log
```

6. Confirm debug setting in config:
   - `ratelimitly_debug on;` in `./tests/nginx.conf`

Counter interpretation quick check:
- `429` high + `000=0` means nginx is reachable and actively denying.
- `000` non-zero means transport/connectivity failures (no HTTP code).
- `rn_allow` reflects final pre-content admission, not final upstream/content status.
- `404` high with `rn_allow` high means rate check passed but final location content/proxy handling returned not found.
- `rn_*` counters at `0` with non-zero HTTP counters usually means wrong log file path or missing debug-level rn lines.

## Notes

- This guide expects a running RateLimitly server (Rust), valid DNS entries,
  and a tenant credential that you are authorized to use.
- `tests/nginx.conf` contains the reserved `tenant.example.invalid` domain and
  a fixed synthetic `rl-aes...` value solely to make local configuration
  checks reproducible. Replace both before any live-service test; never use the
  synthetic value as a production credential and never commit a real key.

## Scripts in this folder

- `build-nginx.sh` — lower-level build helper used by `../tools/build-nginx.sh`.
  - Run: `./tests/build-nginx.sh /path/to/nginx-src [--dynamic]`
- `run-nginx.sh` — starts nginx with a specified config.
  - Run: `./tests/run-nginx.sh /path/to/nginx-bin [/path/to/nginx.conf]`
- `smoke-test.sh` — diagnostic helper that issues a request and prints recent `rn:` debug lines; not a required pass/fail test.
  - Run: `./tests/smoke-test.sh http://127.0.0.1:8088/api/static/test ./logs/error.log`
- `burst-test.sh` — diagnostic helper that sends burst traffic and reports HTTP + rn result counters; not a required pass/fail test.
  - Run: `./tests/burst-test.sh [BASE_URL] [BURST_SIZE] [PARALLELISM] [NGINX_ERR_LOG]`
