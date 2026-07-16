# Contributing

This repository contains the nginx module for RateLimitly.

## Development Dependency

Fetch the supported public C-client release from the repository lock:

```sh
./tools/fetch-rl-c-client.sh
```

This creates `./_deps/rl-c-client`. Override it only when intentionally testing
another C-client checkout:

```sh
export RCLIENT_DIR=/path/to/rl-c-client
```

## Build Checks

Run from the `rl-nginx` repo root:

```sh
for script in tools/fetch-rl-c-client.sh tools/build-nginx.sh tests/build-nginx.sh start-nginx.sh integration-tests/test.sh; do
  bash -n "$script"
done
sh -n config
./tools/build-nginx.sh ./upstream-nginx --clean --debug
git diff --check
```

## Integration Tests

Local integration tests use the Rust RateLimitly server from the `rl` repo:

```sh
./integration-tests/test.sh
```

Do not use the obsolete Python RateLimitly server for validation.

External-server integration tests can be run when you already have a tenant
domain and API key:

```sh
EXTERNAL_SERVER=1 \
DOMAIN=<tenant-domain> \
TENANT_KEY='<rl-aes-or-rl-cookie-key>' \
./integration-tests/test.sh
```

## Documentation Changes

When behavior, directives, build commands, or helper scripts change, update the
public docs in the same change:

- `README.md`
- `docs/build.md`
- `docs/configuration.md`
- `docs/operations.md`
- `examples/`
- `integration-tests/README.md` when the test harness changes

## Commit Identity

For RateLimitly repos in this workspace, use:

```sh
git config user.email wojciech@ratelimitly.com
```
