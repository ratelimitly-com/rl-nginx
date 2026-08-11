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
| `rl-c-client` | [`v0.6.0`](https://github.com/ratelimitly-com/rl-c-client/releases/tag/v0.6.0) at `a9cfc87e7eb90a99d77028b18d1079b301cf619c` |

Public preview means the module is suitable for evaluation and controlled
deployments after operators test their exact nginx build and failure policy. It
does not promise configuration or ABI stability across the `0.1.x` line.
Breaking changes must nevertheless be called out in the changelog and release
notes.

The C-client row is intentionally not a floating branch. The authoritative tag
and full SHA live in
[`dependencies/rl-c-client.env`](../dependencies/rl-c-client.env); public CI and
the fetch helper consume that lock and fail if the tag resolves elsewhere or
the default checkout contains local changes. The direct
[C-client lifecycle probe](c-client.md#executable-compatibility-probe) binds the
callback and ownership behavior required by the nginx adapter.

### v0.5.0 state-ID migration

The v0.5.0 dependency changes the identifier boundary deliberately. Resource
IDs now include the rendered bucket, window, and rate; latency-tracker IDs
include the rendered service, TTL, maximum samples, final effective buffer
size, and minimum sample threshold. These canonical IDs prevent two different
server-state definitions from accidentally sharing one counter or tracker.
The derivation contract itself is owned by the C client and documented in
[Content-defined IDs](https://github.com/ratelimitly-com/rl-c-client/blob/v0.6.0/docs/api.md#content-defined-ids);
this section documents only the deployment impact of adopting it in rl-nginx.

Consequently, the first v0.5.0 request for an existing configuration does not
address the name-only state created by older rl-nginx revisions. A rolling
deployment temporarily has old and new workers using separate state. Operators
must either coordinate the worker transition or explicitly accept that reset
and overlap. The old resource state becomes irrelevant after its rate window;
old latency samples become irrelevant after their tracker TTL. Changing any
ID-defining setting after migration has the same effect and must be treated as
a state-identity change.

## Initial nginx matrix validation

A37 validation on 2026-07-17 established the initial source-build matrix:

| nginx line | Official tag | Commit | Result |
| --- | --- | --- | --- |
| Stable | `release-1.30.2` | `a92a53786` | `make check NGINX_SRC=/tmp/rl-nginx-a37-nginx-1.30.2` passed |
| Mainline | `release-1.31.1` | `d44205284` | `make check NGINX_SRC=/tmp/rl-nginx-a37-nginx-1.31.1` passed |

This confirms source-build and static public behavioral compatibility for the
two nginx releases named above. Current required CI repeats that static gate
and relocated dynamic behavior on native `x86_64` and `aarch64`, and runs the
sanitizer lifecycle gate against both nginx releases on `x86_64`.
The CI meta-test reads the `upstream-nginx` gitlink directly and requires every
mainline matrix copy to declare that same commit, so changing either side alone
turns required CI red.

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
  nginx configure options before rollout. The required public entrypoint is
  `./integration-tests/public.sh`; it needs no RateLimitly server, tenant,
  credential, or private repository.

## Release validation gates

Support evidence is layered rather than claiming that every gate runs for every
Cartesian combination. A release candidate must pass all of the following from
anonymous, clean checkouts:

1. On native `x86_64` and native `aarch64`, for both supported nginx releases,
   build the locked C client and run `make check` with warnings treated as
   errors. This is the complete static configuration and public-behavior gate.
2. On both architectures and nginx releases, build the dynamic module, relocate
   it with its matching nginx binary, reject RPATH/RUNPATH and a shared
   `librclient.so`, and run final-admission, resolver-scope,
   enforcement-boundary, bounded-UDP-ingress, steering/latency ordering, and
   guard/latency behavior through that relocated module.
3. On `x86_64`, run the complete lifecycle and fault-injection suite under
   ASan, UBSan, and LeakSanitizer against both supported nginx releases. The
   category set applies to nginx and module code without a build-wide
   exclusion. Leak detection is disabled only in short-lived `nginx -t` and
   `nginx -s` subprocesses, where upstream nginx intentionally exits without
   destroying configuration pools; real runtime shutdown and standalone C
   probes retain leak detection. UBSan remains recoverable until the artifact
   scan so acceptance does not depend on process-exit timing. The scanner
   accepts only the reviewed upstream `src/core/ngx_string.c:84` and
   `src/core/ngx_string.c:586` `nonnull-attribute` diagnostics present across
   the two locked nginx releases; the check remains enabled and every other
   UBSan report fails the gate.
4. Keep `make test-internal` optional. It requires private service credentials
   and may supplement a release decision, but neither contributors nor public
   CI need it and its absence cannot fail the public release.

`make check` is therefore the required static contributor gate, not shorthand
for the whole release matrix. It reuses the binary produced from the caller's
static `BUILD_FLAGS`; dynamic flags are rejected and must use the separate
dynamic build and relocation sequence.

The release notes must list the exact nginx release, C-client tag and SHA,
operating system, architecture, compiler, module mode, and sanitizer result
used for the release decision.

## Deliberate validation boundaries

The public-preview gates make source and protocol inputs immutable where they
define the supported artifact, but they do not claim bit-reproducible hosted
toolchains or make private infrastructure a public prerequisite. The
rl-nginx maintainers own each accepted boundary below and its reevaluation
condition.

| Boundary | Current control and rationale | Reevaluate when |
| --- | --- | --- |
| Hosted CI toolchain | Required workflows use mutable GitHub-hosted runner images (`ubuntu-latest` and `ubuntu-24.04-arm`) and distribution packages without snapshot pinning. Every release records the exact OS, architecture, and compiler evidence; immutable nginx and C-client revisions define the supported source inputs. Maintaining a package snapshot or build image is not justified for a source-only public preview. | Binary artifacts are published, reproducible-build policy becomes a support requirement, or runner/package drift prevents a result from being reproduced. |
| Explicit C-client checkout | `RCLIENT_DIR` and `RN_RCLIENT_DIR` intentionally opt out of the default clean locked checkout for development and packaging. Such a build is unsupported until its exact client revision and the complete compatibility matrix are independently recorded. Silently falling back to an adjacent checkout remains forbidden. | Packaging needs a verified external-source manifest, or accidental use of the override appears in release evidence. |
| Floating dependency probes | The scheduled workflow deliberately tests `rl-c-client/main` and nginx `master`. It is isolated from release gates, has read-only repository permissions, persists no checkout credential, receives no secrets, and records the exact tested revisions. Pinning it would defeat drift detection. | The job needs any secret or write permission, consumes untrusted artifacts outside its isolated build, or its result is promoted into the supported release matrix. |
| Private full-stack validation | `make test-internal` is optional supplemental evidence because it requires private service credentials and infrastructure. The locked public responder and DNS fixture are the reproducible acceptance authority for module behavior. | A public end-to-end server fixture becomes available, or a release requirement cannot be exercised faithfully by the public protocol fixture. |

## Scheduled dependency drift detection

The `dependency drift` GitHub Actions workflow runs weekly and can also be
started manually. It probes the public `rl-c-client/main` branch against both
supported nginx releases in static and dynamic modes, and probes nginx
`master` against the locked C client in both modes. Each run records the exact
floating revision it tested in the workflow summary.

These probes are intentionally separate from required push and pull-request
CI. A failure is an early incompatibility signal that maintainers must
investigate; it does not change the supported matrix, the repository locks, or
the result of an ordinary reproducible build. Support changes still require a
reviewed lock and compatibility-document update with complete release evidence.
The workflow has top-level read-only repository permissions, disables persisted
checkout credentials, and receives no secrets because it executes floating
upstream code; executable meta-tests preserve those restrictions.

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
