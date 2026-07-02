# Contributing

This repository contains the nginx module for RateLimitly.

## Development Layout

Use sibling checkouts:

```text
workspace/
  rl-c-client/
  rl-nginx/
```

Override the C client path with:

```sh
export RCLIENT_DIR=/path/to/rl-c-client
```

## Build Checks

Run from the `rl-nginx` repo root:

```sh
for script in tools/build-nginx.sh tests/build-nginx.sh start-nginx.sh integration-tests/test.sh; do
  bash -n "$script"
done
RCLIENT_DIR=../rl-c-client ./tools/build-nginx.sh ./upstream-nginx --clean --debug
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
