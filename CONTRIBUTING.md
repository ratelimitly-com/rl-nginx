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

Build and test entrypoints fetch or verify the locked default automatically.
They never select a sibling development checkout unless it is named explicitly
with `RCLIENT_DIR`.

## Build Checks

Run from the `rl-nginx` repo root:

```sh
make syntax
make dependency-bootstrap-test
make workflow-pin-test
./tools/build-nginx.sh ./upstream-nginx --clean --debug
git diff --check
```

## Integration Tests

Run the required integration suite with public dependencies and local fixtures:

```sh
./integration-tests/public.sh
```

This does not require a RateLimitly server, tenant, credential, or private
repository.

Maintainers with access to the private `rl` workspace may optionally run the
internal full-stack harness:

```sh
./integration-tests/internal-full-stack.sh
```

Do not use the obsolete Python RateLimitly server for internal validation.

External-server integration tests can be run when you already have a tenant
domain and API key:

```sh
EXTERNAL_SERVER=1 \
DOMAIN=<tenant-domain> \
TENANT_KEY='<rl-aes-or-rl-cookie-key>' \
./integration-tests/internal-full-stack.sh
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
