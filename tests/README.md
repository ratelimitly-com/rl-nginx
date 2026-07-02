# rl-nginx test harness

This guide shows how to build nginx with the rl-nginx module, run it with a test
config, and validate traffic against a running Ratelimitly server.

This requires local access to the `rl-c-client` repo so nginx can link against
the compiled C client library. The default development layout keeps `rl-c-client`
and `rl-nginx` as sibling checkouts.

## 1) Build rl-c-client

```sh
export RCLIENT_DIR=../rl-c-client
make -C "$RCLIENT_DIR"
```

## 2) Build nginx with the rl-nginx module

**Static module (simplest):**

```sh
/path/to/nginx-src/auto/configure \
  --add-module=. \
  --with-cc-opt="-I${RCLIENT_DIR}/include" \
  --with-ld-opt="-L${RCLIENT_DIR} -lrclient -lcrypto -lssl -Wl,-rpath,${RCLIENT_DIR}"

make -C /path/to/nginx-src -j
sudo make -C /path/to/nginx-src install
```

**Dynamic module:**

```sh
/path/to/nginx-src/auto/configure \
  --add-dynamic-module=. \
  --with-cc-opt="-I${RCLIENT_DIR}/include" \
  --with-ld-opt="-L${RCLIENT_DIR} -lrclient -lcrypto -lssl -Wl,-rpath,${RCLIENT_DIR}"

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
curl -v 'http://127.0.0.1:8088/api/dynamic/test?user=alice'
curl -v 'http://127.0.0.1:8088/api/dynamic/test?user=wojtek'
curl -v --cookie 'session=s1' 'http://127.0.0.1:8088/api/dynamic/test?user=wojtek'
curl -v 'http://127.0.0.1:8088/api/guard/test?user=wojtek'
curl -v 'http://127.0.0.1:8088/api/guard-isolated/test?user=wojtek'
curl -v 'http://127.0.0.1:8088/api/guard-isolated/test?user=wojtek&guard_mode=strict'
```

If `ratelimitly_debug on` is set, you will see detailed `rn:` logs in the nginx
error log (SRV targets, A/AAAA addresses, bucket IDs, UDP recv/decisions).

Guard test path note:
- `/api/guard/test` and `/api/guard-isolated/test` now `proxy_pass` to a local backend on `127.0.0.1:18089` defined in `./tests/nginx.conf`.
- This makes guard tests measure end-to-end proxy latency instead of local static-file serving only.
- The backend endpoint `/backend/ok.txt` returns explicit HTTP `200` for clean burst-test accounting.
- Latency reports sent by the nginx module clamp observed latency to minimum `1ms` (avoids `0ms` artifacts).

## 6) Smoke test helper

```sh
./tests/smoke-test.sh http://127.0.0.1:8088/api/static/test ./logs/error.log
```

## 7) Burst test helper

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
- `dynamic user=alice`
- `dynamic user=wojtek`
- `dynamic wojtek sess=s1`
- `dynamic wojtek sess=s2`
- `group wojtek sess=s1`
- `guard user=wojtek`
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
curl -s -o /dev/null 'http://127.0.0.1:8088/api/group/test?user=wojtek'
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
- `rn_allow` reflects ratelimitly decision only (access phase), not final upstream/content status.
- `404` high with `rn_allow` high means rate check passed but final location content/proxy handling returned not found.
- `rn_*` counters at `0` with non-zero HTTP counters usually means wrong log file path or missing debug-level rn lines.

## Notes

- This guide expects a running Ratelimitly server (Rust) and valid DNS entries.
- `tests/nginx.conf` currently uses `ratelimitly_auth_key` with an `rl-aes...` key.
  Use a current `rl-cookie...` or `rl-aes...` key for local dev and real setups.

## Scripts in this folder

- `build-nginx.sh` — lower-level build helper used by `../tools/build-nginx.sh`.
  - Run: `./tests/build-nginx.sh /path/to/nginx-src [--dynamic]`
- `run-nginx.sh` — starts nginx with a specified config.
  - Run: `./tests/run-nginx.sh /path/to/nginx-bin [/path/to/nginx.conf]`
- `smoke-test.sh` — issues a request and prints recent `rn:` debug lines.
  - Run: `./tests/smoke-test.sh http://127.0.0.1:8088/api/static/test ./logs/error.log`
- `burst-test.sh` — sends burst traffic and reports HTTP + rn result counters.
  - Run: `./tests/burst-test.sh [BASE_URL] [BURST_SIZE] [PARALLELISM] [NGINX_ERR_LOG]`
