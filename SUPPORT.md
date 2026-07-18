# Support

`rl-nginx` is a source-only nginx module in public preview. Support is limited
to the combinations and build process documented in
[`docs/compatibility.md`](docs/compatibility.md). The project does not provide
binary packages, hosted RateLimitly service support, tenant provisioning, DNS
operations, or support for the private full-stack test harness.

## Before opening an issue

1. Check the [documentation index](docs/index.md), especially the
   [build guide](docs/build.md), [configuration guide](docs/configuration.md),
   and [operations guide](docs/operations.md).
2. Reproduce the problem from a clean checkout using the pinned nginx source
   and C-client revision.
3. Run the narrowest useful check, then run `make check BUILD_FLAGS="--clean"`
   when reporting a build or runtime defect.
4. Remove API keys, tenant names, private addresses, and other sensitive data
   from configurations, logs, and command output.

## What to include

Open a focused [GitHub issue](https://github.com/ratelimitly-com/rl-nginx/issues)
for support questions and reproducible bugs. Include:

- the commit or release being tested;
- Linux distribution, architecture, compiler, and nginx version/configure
  arguments;
- static or dynamic module mode;
- the exact command and smallest configuration that reproduces the behavior;
- the expected and observed results; and
- relevant redacted logs and the validation commands that passed or failed.

Issues are public by default. Do not put suspected vulnerabilities or
credentials in an issue; follow [`SECURITY.md`](SECURITY.md) for security
reports. For a sensitive non-security conduct concern, contact a repository
maintainer through GitHub rather than publishing private details.

