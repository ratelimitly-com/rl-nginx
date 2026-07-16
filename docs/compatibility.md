# Compatibility and release scope

This document defines the support target for the first public `rl-nginx`
release. A target becomes a supported combination only after all validation
gates below pass for the release candidate.

## First public release

| Area | Commitment |
| --- | --- |
| Release line | `0.1.x` public preview |
| Delivery | Source-only GitHub release; no binary packages or container images |
| Operating system | Linux with glibc |
| Architectures | `x86_64` and `aarch64` |
| nginx module modes | Static and dynamic |
| nginx releases | Stable `1.30.2` and mainline `1.31.1` |
| `rl-c-client` | [`v0.2.0`](https://github.com/ratelimitly-com/rl-c-client/releases/tag/v0.2.0) at `6cafd3f5bea6ba2f8a791966a70b8ab8e56c485f` |

Public preview means the module is suitable for evaluation and controlled
deployments after operators test their exact nginx build and failure policy. It
does not promise configuration or ABI stability across the `0.1.x` line.
Breaking changes must nevertheless be called out in the changelog and release
notes.

The C-client row is intentionally not a floating branch. The authoritative tag
and full SHA live in
[`dependencies/rl-c-client.env`](../dependencies/rl-c-client.env); public CI and
the fetch helper consume that lock and fail if the tag resolves elsewhere.

## Compatibility rules

- Static-module users must build and deploy the resulting nginx binary as one
  unit.
- Dynamic modules must be built against the same nginx release and compatible
  configure options as the nginx binary that loads them. `--with-compat` does
  not create a general cross-version ABI guarantee.
- Only the nginx releases and C-client revision named in the release notes are
  supported. A newer point release or branch tip is not supported until the
  required matrix passes and this document is updated.
- The supported Linux/architecture combinations apply to source builds. They
  do not imply compatibility with every distribution package layout or nginx
  vendor build.
- Operators must reproduce the public behavioral tests with their production
  nginx configure options before rollout.

## Release validation gates

Every supported matrix entry must pass all of the following from an anonymous,
clean checkout:

1. Build the locked C client without credentials or private repositories.
2. Build nginx and the module with warnings treated as errors.
3. Build both static and dynamic module modes.
4. Load the relocated dynamic module without a workspace runtime path or a
   developer-checkout `librclient.so` dependency.
5. Pass configuration validation and the public behavioral test suite.
6. Pass the lifecycle regression suite under ASan and UBSan.

The release notes must list the exact nginx release, C-client tag and SHA,
operating system, architecture, compiler, and static/dynamic result used for
the release decision.

## Explicit non-goals for `0.1.x`

The following work is outside the first public release:

- prebuilt Linux packages, container images, or a package repository;
- Prometheus metrics or another built-in metrics exporter;
- macOS, Windows, BSD, musl, or additional architecture support;
- compatibility claims for nginx releases outside `1.30.2` and `1.31.1`;
- a large split of the nginx module implementation into multiple source files;
- making the private full-stack RateLimitly server test a requirement for
  public contributors.

These items may be proposed as roadmap work after the public release. They are
not current functionality or commitments and must not be described as such in
user-facing documentation.

## Support changes

Changes to the matrix require a pull request that updates this document,
provides clean validation evidence, and states whether the change is additive,
breaking, or a security response. Removing a supported combination requires a
documented deprecation notice unless an unresolved security issue makes
immediate removal necessary.
