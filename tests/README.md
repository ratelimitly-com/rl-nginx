# rn test harness

This guide shows how to build nginx with the rn module, run it with a test
config, and validate traffic against a running Ratelimitly server.

This requires local access to the C r-client repo, preferably at
`./rl-c-client` (legacy fallback: `./upstream-rl/clients/c`), so nginx can
link against the compiled r-client library.

## 1) Build the C r-client

```sh
export RCLIENT_DIR=./rl-c-client
# legacy fallback:
# export RCLIENT_DIR=./upstream-rl/clients/c
make -C "$RCLIENT_DIR"
```

## 2) Build nginx with the rn module

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

A helper script is provided (pass the nginx repo root, not `/src`):

```sh
./tests/build-nginx.sh /path/to/nginx-src
# or
./tests/build-nginx.sh /path/to/nginx-src --dynamic
 # clean rebuild
./tests/build-nginx.sh /path/to/nginx-src --clean
```

## 3) Run nginx with the test config

Edit the config first:

- `./tests/nginx.conf`

Then run:

```sh
# If nginx installed to /usr/local/nginx
sudo /usr/local/nginx/sbin/nginx -c ./tests/nginx.conf

# or use the helper
./tests/run-nginx.sh /usr/local/nginx/sbin/nginx ./tests/nginx.conf
```

If you built a dynamic module, remember to uncomment `load_module` in the test
config.

## 4) DNS SRV/A setup

The r-client uses SRV first (`_ratelimitly._udp.<tenant>`), then A/AAAA.
Use your existing dnsmasq setup for local SRV entries.

## 5) Verify

```sh
curl -v http://127.0.0.1:8081/api/test
```

If `ratelimitly_debug on` is set, you will see detailed `rn:` logs in the nginx
error log (SRV targets, A/AAAA addresses, bucket IDs, UDP recv/decisions).

## 6) Smoke test helper

```sh
./tests/smoke-test.sh http://127.0.0.1:8081/api/test /usr/local/nginx/logs/error.log
```

## Notes

- This guide expects a running Ratelimitly server (Rust) and valid DNS entries.
- The example config uses `cookie` auth; update to match your tenant config.

## Scripts in this folder

- `build-nginx.sh` — builds nginx with the rn module (static or dynamic).
  - Run: `./tests/build-nginx.sh /path/to/nginx-src [--dynamic]`
- `run-nginx.sh` — starts nginx with a specified config.
  - Run: `./tests/run-nginx.sh /path/to/nginx-bin [/path/to/nginx.conf]`
- `smoke-test.sh` — issues a request and prints recent `rn:` debug lines.
  - Run: `./tests/smoke-test.sh http://127.0.0.1:8081/api/test /usr/local/nginx/logs/error.log`
