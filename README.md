# rl-nginx

`rl-nginx` is an nginx HTTP module that makes the final admission decision
before content processing. After nginx access control and pre-content routing
have succeeded, it turns nginx variables into rate-limit resources and sends
them to RateLimitly through `rl-c-client`. A valid allow consumes those
resources and advances directly to content processing; a deny returns
`429 Too Many Requests`.

The planned `0.1.x` public preview is source-only. It supports static and
dynamic module builds on Linux with glibc and nginx `1.30.2` or `1.31.1`; the
exact release scope is in [the compatibility guide](docs/compatibility.md).

## Quick Start

The commands below use the repository's pinned nginx `1.31.1` submodule and
automatically fetch the locked public `rl-c-client` `v0.2.0` release. No private
repository, RateLimitly server, tenant, or API key is needed to build and run
the public test suite.

On Debian or Ubuntu, install the required tools and build dependencies:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential curl dnsutils git libpcre2-dev libssl-dev procps python3 \
  zlib1g-dev
```

Clone the repository with its pinned nginx source and run the required public
gate:

```sh
git clone --recurse-submodules https://github.com/ratelimitly-com/rl-nginx.git
cd rl-nginx
make check BUILD_FLAGS="--clean"
```

`make check` verifies scripts and dependency locks, builds the static module,
checks nginx configuration, runs the deterministic public integration suite,
and checks whitespace. It materializes the C client at
`./_deps/rl-c-client`; that checkout must match the tag and full commit in
[`dependencies/rl-c-client.env`](dependencies/rl-c-client.env).

The resulting static nginx binary is:

```text
upstream-nginx/objs/nginx
```

For a dynamic module instead, run:

```sh
make build BUILD_FLAGS="--dynamic --compat --clean"
make dynamic-relocation-test
```

The dynamic artifact is:

```text
upstream-nginx/objs/ngx_http_rn_module.so
```

Build a deployment artifact against the same nginx release and compatible
configure options as the nginx binary that will run it. See
[Building rl-nginx](docs/build.md) before installing either artifact.

## Minimal Configuration

The tenant domain and API key below are deliberately non-working placeholders.
Replace both before running `nginx -t`. Also replace the resolver address if
`127.0.0.53` is not the DNS resolver available to your nginx workers. The
resolver must be declared directly in the `http` context: the module has one
worker-local client, so server/location resolver overrides do not select its
discovery resolver.

```nginx
events {}

http {
  resolver 127.0.0.53 valid=30s ipv6=off;

  ratelimitly_tenant   tenant.example.invalid;
  ratelimitly_auth_key rl-aes1REPLACE_WITH_YOUR_KEY;
  ratelimitly_timeout  50ms;
  ratelimitly_fail     close;

  ratelimitly_zone api
    bucket="v1|scope=api|ip=$remote_addr"
    rate=100r/s;

  server {
    listen 8080;

    location /api/ {
      ratelimitly_label "scope=api";
      ratelimitly zone=api;
      proxy_pass http://127.0.0.1:9000;
    }
  }
}
```

For a dynamic build, load the installed module before the `events` block:

```nginx
load_module modules/ngx_http_rn_module.so;
```

RateLimitly discovery queries
`_ratelimitly._udp.<your-tenant-domain>`. The control plane must provide the
tenant, API key, and corresponding DNS SRV record; this repository does not
create or run those services. Start from
[`examples/minimal.conf`](examples/minimal.conf), review
[`examples/security-conscious.conf`](examples/security-conscious.conf), and
read the [configuration guide](docs/configuration.md) before deploying. Treat
`ratelimitly_auth_key` as a secret.

## What the Module Does

- Discovers RateLimitly servers through tenant-specific DNS SRV records.
- Defines nginx-native resources with `ratelimitly_zone`.
- Groups resources with `ratelimitly_group`.
- Optionally reports guarded request latency after valid RateLimitly allows
  with `ratelimitly_guard`.
- Enforces allow and deny decisions before proxying or serving content.
- Applies a configured fail-open or fail-closed policy when no valid decision
  is available.

When a protected request arrives, the module expands the configured nginx
variables, hashes bucket and service names into protocol identifiers, and sends
the decision request over UDP through `rl-c-client`. A valid allow continues
normal nginx processing; a valid deny returns `429`; DNS, network, timeout, and
protocol failures follow `ratelimitly_fail open|close`.

The module does not create tenants, issue credentials, manage DNS, or include a
RateLimitly server.

Guard latency feedback is admission-aware: it is reported only after a valid
allow and subsequent request processing. A deny, fail-open/fail-close error,
missing verdict, timeout, or client abort does not contribute a latency sample.

## Core Directives

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

See the [configuration guide](docs/configuration.md) for directive behavior and
the [DSL reference](spec/dsl.md) for complete syntax.

## Supported Dependency Policy

Supported builds use immutable inputs:

| Dependency | Supported revision |
| --- | --- |
| nginx stable | `release-1.30.2` at `a92a537860c7b87d3793d9eb41c9cf3ed833b53c` |
| nginx mainline and default submodule | `release-1.31.1` at `d44205284fa41662da803b796d6056fc1e59b1f3` |
| `rl-c-client` | `v0.2.0` at `6cafd3f5bea6ba2f8a791966a70b8ab8e56c485f` |

Set `NGINX_SRC=/path/to/nginx-src` when testing another supported nginx source
tree. Set `RCLIENT_DIR=/path/to/rl-c-client` only when intentionally developing
or packaging against another client checkout. An override is not a supported
release lock, and no sibling checkout is selected implicitly.

Scheduled compatibility probes test `rl-c-client/main` and nginx `master` for
early warning only. Required builds and support claims remain on the immutable
revisions above.

## Testing

The required contributor and release-readiness entrypoint is:

```sh
make check
```

Useful narrower gates are:

```sh
make syntax
make unit
make build
make config-test
make public-test
make dynamic-relocation-test
make sanitizers
```

The public integration suite uses the locked C-client responder and local DNS
fixture. It covers enforcement boundaries, fail-open/fail-closed outages, DNS
failure and recovery, timeouts, aborted clients, steering rebinds, guards,
malformed responses, response cardinality, reload, worker survival, and clean
shutdown. It requires no real tenant or credential.

`tests/smoke-test.sh` and `tests/burst-test.sh` are manual diagnostics, not
release gates. The private full-stack harness is optional and is not required
for public contributors. See [the integration-test guide](integration-tests/README.md)
for those workflows.

## Documentation and Project Links

- [Documentation index](docs/index.md)
- [Build and installation](docs/build.md)
- [Configuration](docs/configuration.md)
- [Operations and troubleshooting](docs/operations.md)
- [Compatibility and release scope](docs/compatibility.md)
- [C-client integration](docs/c-client.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Support and bug reports](SUPPORT.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Release notes and source archives](https://github.com/ratelimitly-com/rl-nginx/releases)

Do not report suspected vulnerabilities in a public issue. Follow
[`SECURITY.md`](SECURITY.md) instead, and remove tenant credentials from every
configuration snippet and log you share.

## Repository Layout

```text
rl-nginx/
  src/                         nginx module source
  examples/                    copyable nginx configurations
  docs/                        build, configuration, and operations guides
  integration-tests/           deterministic public test harness
  spec/                        detailed configuration and behavior references
  tests/                       lower-level tests and manual diagnostics
  tools/build-nginx.sh         supported build helper
  config                       nginx module build descriptor
```

This repository is licensed under the MIT License; see [LICENSE](LICENSE).
