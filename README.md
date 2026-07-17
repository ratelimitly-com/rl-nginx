# rl-nginx

`rl-nginx` is an nginx HTTP module for enforcing RateLimitly decisions at the
nginx access phase.

The module evaluates one or more configured rate-limit resources for each
request, sends those resources to RateLimitly through `rl-c-client`, and either
lets nginx continue request processing or returns `429 Too Many Requests`.

This repository contains the nginx module source, build helpers, configuration
examples, and integration tests. It does not contain the RateLimitly server or
tenant-management service.

## What The Module Does

- Discovers RateLimitly servers with DNS SRV records:
  `_ratelimitly._udp.<tenant-domain>`.
- Authenticates requests with a RateLimitly tenant API key:
  `rl-cookie...` or `rl-aes...`.
- Defines nginx-native rate-limit resources with `ratelimitly_zone`.
- Groups multiple resources with `ratelimitly_group`.
- Optionally sends latency guard blocks with `ratelimitly_guard`.
- Enforces RateLimitly allow/deny decisions before proxying or serving content.
- Supports fail-open or fail-closed behavior when RateLimitly cannot be reached.

It does not create tenants, issue API keys, manage DNS, or run a local
RateLimitly server. Those are provided by the RateLimitly control plane and
server deployment.

## Repository Layout

```text
rl-nginx/
  src/                         nginx module source
  examples/                    copyable nginx configuration examples
  docs/                        build, configuration, and operations guides
  integration-tests/           end-to-end test harness
  spec/                        detailed configuration and behavior specs
  tests/                       development smoke/burst helpers
  tools/build-nginx.sh         public build helper
  config                       nginx module build descriptor
```

`rl-c-client` is an external dependency. Supported builds use the public tag
and full commit SHA recorded in
[`dependencies/rl-c-client.env`](dependencies/rl-c-client.env). Fetch that exact
release into the default ignored dependency directory:

```sh
./tools/fetch-rl-c-client.sh
```

This creates `./_deps/rl-c-client`. Set
`RCLIENT_DIR=/path/to/rl-c-client` only when intentionally building another
checkout, such as while developing or packaging the C client.

## Requirements

- nginx source tree for the nginx version you will run.
- The locked public `rl-c-client` source release, fetched with the repository
  helper, or an intentional `RCLIENT_DIR` override.
- C compiler and standard nginx build dependencies.
- OpenSSL development headers and libraries (`libcrypto`; the helper also links
  `libssl` for compatibility with existing build environments).
- PCRE2 and zlib development packages, as required by nginx.
- A RateLimitly tenant domain with a working SRV record.
- A valid RateLimitly API key for that tenant.

For production dynamic modules, build the module against the same nginx version
and compatible configure options as the nginx binary that will load it.

The first public release scope and validation matrix are documented in
[docs/compatibility.md](docs/compatibility.md).

## Build

Fetch the locked `rl-c-client` release:

```sh
./tools/fetch-rl-c-client.sh
```

Then build nginx with this module. The helper builds the C client first. The
simplest source build is a static module:

```sh
./tools/build-nginx.sh /path/to/nginx-src --clean
```

For a dynamic module:

```sh
./tools/build-nginx.sh /path/to/nginx-src --dynamic --compat --clean
```

The dynamic module is written under the nginx build directory, usually:

```text
/path/to/nginx-src/objs/ngx_http_rn_module.so
```

Raw nginx configure commands are documented in [docs/build.md](docs/build.md).

## Minimal Configuration

For a static module build:

```nginx
events {}

http {
  resolver 127.0.0.53 valid=30s ipv6=off;

  ratelimitly_tenant   c-5107024729143590554.p0.ratelimitly.com;
  ratelimitly_auth_key rl-aes1...;
  ratelimitly_timeout  50ms;
  ratelimitly_fail     close;

  ratelimitly_zone api bucket="api:$binary_remote_addr:$request_method:$uri" rate=100r/s;

  server {
    listen 8080;

    location /api/ {
      ratelimitly_label "api:$request_method:$uri";
      ratelimitly zone=api;
      proxy_pass http://127.0.0.1:9000;
    }
  }
}
```

For a dynamic module build, add a top-level `load_module` directive before the
`events` block:

```nginx
load_module modules/ngx_http_rn_module.so;
```

A complete example is available in [examples/minimal.conf](examples/minimal.conf).

## Configuration Directives

Core directives:

- `ratelimitly_tenant <tenant-domain>;`
- `ratelimitly_auth_key <rl-cookie...|rl-aes...>;`
- `ratelimitly_timeout <duration>;`
- `ratelimitly_fail open|close;`
- `ratelimitly_bind <ip>;`
- `ratelimitly_debug on|off;`
- `ratelimitly_zone <name> bucket="<template>" rate=<rate>;`
- `ratelimitly_group <name> zone=<zone> ...;`
- `ratelimitly_guard <name> service="<template>" threshold=<duration> ...;`
- `ratelimitly zone=<name>|group=<name> [guard=<name>] ...;`
- `ratelimitly_label "<template>";`

See [docs/configuration.md](docs/configuration.md) for directive details and
[spec/dsl.md](spec/dsl.md) for the full DSL reference.

## Runtime Behavior

When a protected request arrives, the module:

1. Expands nginx variables in bucket, rate, label, and guard templates.
2. Hashes resource bucket names and guard service names into protocol IDs.
3. Sends a UDP request to the discovered RateLimitly server through
   `rl-c-client`.
4. Continues nginx processing when RateLimitly allows the request.
5. Returns `429 Too Many Requests` when RateLimitly denies the request.
6. Applies `ratelimitly_fail open|close` when DNS, UDP, timeout, or protocol
   errors prevent a valid decision.

Operational guidance is in [docs/operations.md](docs/operations.md).

## Test

Syntax and development build checks:

```sh
for script in tools/fetch-rl-c-client.sh tools/build-nginx.sh tools/sanitized-lifecycle.sh tests/build-nginx.sh tests/test-numeric.sh tests/test-srv-records.sh start-nginx.sh integration-tests/test.sh integration-tests/lifecycle-regressions.sh; do
  bash -n "$script"
done
python3 -c 'import ast, pathlib; paths = [pathlib.Path("integration-tests/abort_http_clients.py"), pathlib.Path("integration-tests/worker_udp_port.py")]; [ast.parse(path.read_text(), filename=str(path)) for path in paths]'
sh -n config
./tests/test-numeric.sh
RCLIENT_DIR=./_deps/rl-c-client ./tests/test-srv-records.sh
./tools/build-nginx.sh ./upstream-nginx --clean --debug
```

The numeric unit checks every 32-bit wire boundary before a value can be
narrowed; the SRV-record unit injects a failure at every allocation point and
requires the adapter to return no partial records and retain no allocations.

Public timeout, aborted-client, and steering-rebind lifecycle regressions:

```sh
./integration-tests/lifecycle-regressions.sh
```

Each case requires the original nginx worker to survive and serve a successful
follow-up request, validates a reload, and requires a clean worker shutdown.
Artifacts are written under `integration-tests/artifacts/lifecycle/`.

Run the lifecycle and response-cardinality gates three times with ASan and
UBSan instrumentation in nginx, this module, and the C client:

```sh
./tools/sanitized-lifecycle.sh
```

Full integration test with the local Rust RateLimitly server:

```sh
./integration-tests/test.sh
```

Full integration test against an existing RateLimitly server and tenant:

```sh
EXTERNAL_SERVER=1 \
DOMAIN=c-5107024729143590554.p0.ratelimitly.com \
TENANT_KEY='<rl-aes-or-rl-cookie-key>' \
./integration-tests/test.sh
```

The integration harness uses the Rust server implementation for local tests.
Do not use the obsolete Python server for validation.

## Status

The planned `0.1.x` public-preview release is source-only. Distribution packages
and container images are explicit non-goals for that release. See
[docs/compatibility.md](docs/compatibility.md) for the target nginx, C-client,
platform, and module-mode matrix.

This repository is licensed under the MIT License; see [LICENSE](LICENSE).
