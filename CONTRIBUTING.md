# Contributing to rl-nginx

Thank you for helping improve the RateLimitly nginx module. Contributions to
code, tests, documentation, examples, and reproducible bug reports are welcome.

Do not open a public issue or pull request for a suspected vulnerability.
Follow the private reporting instructions in [`SECURITY.md`](SECURITY.md).

## Choose a focused change

Keep a pull request limited to one reviewable problem. For a substantial new
feature, configuration directive, compatibility change, or behavioral change,
open an issue before investing in an implementation so the public contract and
test approach can be agreed first. Small fixes and documentation corrections
can go directly to a pull request.

Behavioral changes MUST update the relevant normative file under [`spec/`](spec/index.md),
their public regression coverage, and operator-facing documentation in the
same pull request. Do not present planned behavior as implemented.

## Prepare a public checkout

The supported development path needs only public repositories and synthetic
fixtures. Install the prerequisites listed in the
[build guide](docs/build.md#prerequisites), then clone your fork with the pinned
nginx submodule:

```sh
git clone --recurse-submodules https://github.com/<your-account>/rl-nginx.git
cd rl-nginx
git remote add upstream https://github.com/ratelimitly-com/rl-nginx.git
```

If you already cloned without submodules, initialize the locked nginx source:

```sh
git submodule update --init --recursive
```

Create a topic branch from current upstream `main`:

```sh
git fetch upstream
git switch -c <short-topic> upstream/main
```

Organization maintainers with write access can use a branch in the main
repository instead of a fork. Contributors MUST configure Git with their own
name and email (or their own GitHub-provided no-reply address); this project
does not assign a shared commit identity.

## Use the locked dependencies

Supported builds automatically fetch or verify the public C-client release
recorded in [`dependencies/rl-c-client.env`](dependencies/rl-c-client.env):

```sh
./tools/fetch-rl-c-client.sh
```

It is installed under `./_deps/rl-c-client`. The repository never selects a
sibling checkout implicitly. Use an override only when intentionally testing a
coordinated C-client change:

```sh
RCLIENT_DIR=/path/to/rl-c-client make check BUILD_FLAGS="--clean"
```

An override does not change the supported dependency lock. A pull request that
updates the supported C client must pin a public immutable tag and full commit,
update compatibility documentation, and pass with the new locked checkout.

## Test the change

Run focused checks while developing. The useful entrypoints are:

| Change | Focused validation |
| --- | --- |
| Shell, Python, workflow, or dependency-lock code | `make syntax unit` |
| Directive parsing, defaults, examples, or configuration docs | `make build config-test spec-consistency-test BUILD_FLAGS="--clean --debug"` |
| Request decisions, DNS, protocol, guards, or worker lifecycle | `make build public-test BUILD_FLAGS="--clean --debug"` |
| Dynamic-module build or linkage | `make build dynamic-relocation-test BUILD_FLAGS="--dynamic --compat --clean --debug"` |
| Request ownership, timers, cancellation, steering, reload, or shutdown | `SANITIZER_RUNS=1 make sanitizers` |
| Any change | `make whitespace` |

Before requesting review, run the complete clean public gate from the
repository root:

```sh
make check BUILD_FLAGS="--clean"
```

This gate verifies script syntax, dependency locks, specification consistency,
unit/configuration behavior, a clean nginx/module build, and the deterministic
public integration suite. It requires no RateLimitly server, tenant, API key,
private repository, or organization secret. See the
[integration-test guide](integration-tests/README.md) for individual lifecycle
and protocol cases.

The optional internal full-stack harness is maintainer-only supplementary
evidence. Public contributors are never expected to access the private `rl`
workspace or provide a real tenant credential, and lack of that access MUST NOT
block a contribution.

## Keep documentation and fixtures accurate

Update the public documentation affected by a change, normally including one
or more of:

- [`README.md`](README.md) for the public entrypoint;
- [`docs/build.md`](docs/build.md) for build and artifact behavior;
- [`docs/configuration.md`](docs/configuration.md) and [`spec/dsl.md`](spec/dsl.md)
  for configuration;
- [`docs/operations.md`](docs/operations.md) for rollout, failure, recovery, or
  troubleshooting behavior;
- [`docs/compatibility.md`](docs/compatibility.md) for support promises; and
- [`integration-tests/README.md`](integration-tests/README.md) when a harness
  or public fixture changes.

Copyable examples MUST use reserved names and obvious credential placeholders.
Never commit a real tenant, API key, private path, internal hostname, test
artifact directory, `_deps/` checkout, or nginx build output. Verify every
changed local documentation link and run the real configuration test when an
example changes.

## Commit and open a pull request

Use your own Git identity and write concise commit messages that describe the
change. Before pushing, review the exact scope:

```sh
git status --short
git diff --check
git diff --stat upstream/main...HEAD
git diff upstream/main...HEAD
```

Push the topic branch to your fork and open a pull request against
`ratelimitly-com/rl-nginx:main`. The pull request description should include:

- the problem and user-visible outcome;
- important design, compatibility, security, or failure-policy decisions;
- tests run locally, including the complete gate result;
- documentation and examples changed; and
- the related issue, when one exists.

Keep generated files, credentials, unrelated formatting, and unrelated fixes
out of the branch. If the change depends on another public repository, link the
merged prerequisite and identify its immutable released revision.

## Review and CI

GitHub Actions reruns the supported stable/mainline and static/dynamic build
matrix plus the sanitizer gate. Every required job must pass. A green workflow
does not replace review: respond to feedback with additional commits and keep
the specification, tests, and docs synchronized with the final implementation.

Maintainers may ask for a reproducer, narrower scope, additional failure-path
coverage, compatibility evidence, or a release note before merge. Once the
pull request is approved and green, a maintainer will merge it according to the
repository's current merge policy.
