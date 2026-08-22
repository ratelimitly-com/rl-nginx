# Changelog

All notable changes to `rl-nginx` will be documented here. Release candidates
remain preview software and must not be treated as ABI-stable versions.

## Unreleased

### Added

- **Live production protocol smoke.** `make production-smoke` builds nginx with
  this module, starts it against the RateLimitly production fleet using only a
  `RATELIMITLY_AUTH_KEY`, and drives real HTTP requests through the ordinary
  pre-content admission path. It proves that a reported latency sample is
  stored and read back by a guard on the same tracker, and that a one-token
  bucket admits once and then rejects, checking each decision as an HTTP status
  and a `$ratelimitly_verdict` so fail-open and fail-close can never look like
  an authenticated decision. Discovery is derived from the credential alone.
  See [`integration-tests/README.md`](integration-tests/README.md).

  The new `production-smoke` CI job is pinned to `main`, runs only for pushes
  or a maintainer's manual dispatch, and is the only job permitted to read a
  secret; `tests/test-ci-gates.py` now keeps every required job secret-free and
  red-case tests the live job's actor pin, concurrency isolation, per-run
  namespace, and step-level credential scope.

### Fixed

- **The module builds with clang again.** `ngx_http_rn_tracker()` declared
  `buffer_size` uninitialized and assigned `tracker->buffer_size` only when
  `buffer_size=` was given. Clang cannot correlate that write with the separate
  `buffer_size_set` flag, so `auto/cc/clang`'s `-Wconditional-uninitialized`
  fired and nginx's `-Werror` turned it into a hard build failure on every
  clang host. The runtime fallback was never affected — `tracker` is
  zeroed before the assignment and `rn_build_tracker_values()` resolves the
  effective value from the API key's `latency_buffer_size_max` — so the local
  now carries that same zero default and the assignment is unconditional.

  A `clang-build` CI job compiles both supported nginx lines with `CC=clang`,
  because the existing jobs are GCC-only and GCC does not implement this
  warning. `tests/test-ci-gates.py` red-case tests the job so it cannot quietly
  stop using clang.

## 0.1.0 — 2026-08-22

### Breaking

- **API keys must use credential format 1.** The locked C-client dependency is
  now `v1.0.0`, which intentionally rejects legacy unversioned credentials and
  unknown format versions. Reissue every API key before deploying this
  rl-nginx revision; a legacy value fails `nginx -t` instead of reaching a
  worker.

- **Latency tracker identity, guards, and reporting are now separate.** Define
  tracker state with `ratelimitly_tracker`, reference it from
  `ratelimitly_guard tracker=... threshold=...`, and opt into exactly one
  post-response sample with `ratelimitly_report <tracker>`. Guards no longer
  report implicitly. A report can be used without a guard or admission rule,
  and `ratelimitly_report off` suppresses inheritance.

- **`ratelimitly_timeout` is removed.** There is no alias: a configuration that
  still uses it fails `nginx -t` with `unknown directive`.

  `ratelimitly_timeout <T>` made `T` the *entire* admission budget (it set the
  client's attempt timeout with zero retries). `ratelimitly_policy` replaces it
  with a multi-round policy, so the migration is **not** a one-for-one textual
  substitution:

  | Old | Equivalent | Worst-case admission wait |
  |---|---|---|
  | `ratelimitly_timeout T;` | `ratelimitly_policy single_round unit=T;` | `T` — unchanged |
  | `ratelimitly_timeout T;` | `ratelimitly_policy standard unit=T;` | **`3 * T`** — three units |
  | `ratelimitly_timeout T;` | `ratelimitly_policy standard unit=T/3;` | `T` — unchanged, using the new default shape |

  Choose `single_round` to preserve the previous behaviour exactly, or
  `standard` with a third of the old value to keep the same worst case while
  adopting the replay/final-receive shape. Writing `standard unit=T` with the
  old value triples the budget.

- **The derived policy horizon is now validated against the API key.** A
  `unit=` that was previously accepted can now be rejected at configuration
  load when `unit * (sum(replay_gap) + final_wait_units)` exceeds the
  credential's `dedup_ttl_ms_max`. See
  [configuration](docs/configuration.md#ratelimitly_policy).

- **`ratelimitly_policy` rejects duplicate occurrences.** `ratelimitly_timeout`
  was last-wins, so a base configuration plus an environment-specific override
  `include` is no longer valid for this directive and fails `nginx -t`. This
  matches `ratelimitly_tenant`, `ratelimitly_auth_key`, `ratelimitly_bind` and
  `ratelimitly_debug`, which already rejected duplicates.

- **Latency-tracker identity now depends on the credential when `buffer_size`
  is omitted.** The effective `buffer_size` falls back to the API key's
  `latency_buffer_size_max`, and that value is part of the tracker ID. Rotating
  to a credential whose quota differs re-identifies every guard that relies on
  the fallback, discarding accumulated latency history. Set `buffer_size`
  explicitly on each `ratelimitly_tracker` in any configuration expected to
  survive a key rotation.

### Changed

- updated the supported public `rl-c-client` dependency to `v1.0.0`; resource
  requests now inherit the client's local enforcement of the API key's
  `rate_window_size_ms_max` before DNS, serialization, or UDP transmission;
- updated the supported public `rl-c-client` dependency to `v0.6.0` and
  allowed a `ratelimitly` rule to contain one or more latency guards without a
  resource zone or group;
- updated the supported public `rl-c-client` dependency to `v0.5.0` and
  replaced `ratelimitly_timeout` with `ratelimitly_policy`: `standard` exposes
  the locked three-unit default, `single_round` provides a literal one-round
  policy, and `custom` exposes the complete request-policy parameter set;
- derive resource-bucket IDs from the rendered bucket, window, and rate, and
  derive latency-tracker IDs from the rendered service plus all tracker-state
  settings, using the canonical length-aware C-client helpers; and
- removed the obsolete direct-DNS fallback description because `v0.5.0`
  requires valid SRV membership; and
- restructured the public documentation around the RateLimitly operation
  model, concrete nginx examples, an explicit nginx/client ownership boundary,
  and version-locked links to the authoritative C-client documentation.

  This dependency update changes the wire IDs of existing buckets and latency
  trackers. During a rolling upgrade, old and new workers therefore address
  separate server state until old resource windows and tracker TTLs expire.

## 0.1.0-rc.3 — 2026-07-26

- updated the supported public `rl-c-client` dependency to `v0.4.0`, including
  the oldest-trusted-server response strategy and retry behavior;
- refreshed dependency, compatibility, security, and third-party release
  documentation to record the immutable client tag and commit; and
- reran the complete unit, integration, dynamic-relocation, architecture, and
  sanitizer release gates against the new client release.

## 0.1.0-rc.2 — 2026-07-24

Changes since `v0.1.0-rc.1`:

- added native `aarch64` static and relocated-dynamic coverage for both
  supported nginx releases and extended sanitizers to both nginx lines;
- made `make check` preserve and exercise its caller-selected static build,
  separated contributor, release-only, and optional-private gate contracts,
  and made dynamic relocation exercise six representative behavior groups;
- enabled LeakSanitizer for probes and nginx runtime shutdown with a narrow
  one-shot nginx config/control exception, removed the build-wide UBSan
  category exclusion, replaced it with exact reviewed upstream-nginx report
  signatures, and centralized sanitizer flags across dependency, module, and
  nginx builds;
- made the public suite materialize its locked responder fixture explicitly so
  clean checkouts exercise the same retained nginx binary as existing trees;
- moved RateLimitly enforcement to the final pre-content admission point so
  nginx access rejection and routing happen before resource consumption;
- defined a valid allow as consumed admission directly into content processing
  and added static, dynamic, and sanitizer regression coverage for the
  ordering contract;
- preserved one admission across nginx internal redirects and kept subrequests
  outside independent RateLimitly accounting;
- drained nginx posted requests after asynchronous verdict callbacks so
  resumed content cannot remain pinned awaiting an unrelated client event;
- replaced guard-derived latency feedback with the explicit single-tracker
  `ratelimitly_report` contract, including report-only and completed fail-open
  work and suppression after denial, fail-close, or client abort;
- made the HTTP-scope resolver and timeout deterministic for each worker,
  validated bind addresses at configuration time, and bounded failed worker
  initialization retries;
- made public test and CI oracles fail closed: fetch/syntax loops preserve early
  failures, committed whitespace is checked, required workflow commands are
  executable and non-optional, lifecycle faults require exact outcomes, and
  every gate class has a deliberate red-case fixture;
- bounded rendered bucket and service keys to 1024 bytes and wire labels to
  256 bytes, made empty/oversized dynamic values follow the failure policy,
  and rejected zero or oversized request/guard durations;
- corrected named-value quoting so examples quote the complete `bucket=` or
  `service=` argument; value-only quotes are now rejected because nginx treats
  them as literal identifier bytes;
- rejected empty resource, group, guard, and positional references, made debug
  duplicate detection order-independent, and normalized unconfigured location
  activation to a real disabled value;
- compacted resolver addresses before reporting their successful count to the
  C client and added a unit oracle for skipped oversized addresses;
- made the C-client callback, cancellation, ownership, timeout, and destruction
  assumptions explicit and executable against both the lock and scheduled
  `rl-c-client/main` probes;
- rejected modified default C-client checkouts while preserving dirty explicit
  development overrides, tied the nginx gitlink to every mainline CI matrix,
  and added red-case guards for drift-workflow permissions, local actions, and
  container image pins;
- fixed nginx resolver-context ownership across allocation failures,
  synchronous completion, start failure, cancellation, and worker shutdown;
- made partial worker initialization transactional, including destruction of a
  successfully created C client when a later initialization step fails;
- made steering rebinds transactional: the current UDP endpoint stays active
  until its replacement is registered, and failed replacements retry later;
- added test-only resolver, worker-initialization, and rebind fault injection to
  the ASan/UBSan lifecycle gate;
- removed request-controlled cookies, hosts, raw URIs, and query values from
  default RateLimitly identities and policy examples, and added a bounded
  `$ratelimitly_verdict` production warmup oracle;
- bounded each UDP read-handler turn to 64 candidate datagrams and added
  public, relocated-dynamic, and sanitizer fairness coverage under sustained
  invalid ingress;
- made the steering contract explicit that `keep_port=false` replaces the
  source port as soon as safely possible and does not wait for an independent
  fire-and-forget latency report, and made its ordering oracle compare
  module-completion events instead of racing an external process observer; and
- documented accepted credential-memory, hosted-toolchain,
  development-override, dependency-drift, private-test, and latency-measurement
  boundaries with owners or named trackers and concrete reevaluation triggers.

## 0.1.0-rc.1 — 2026-07-17

The first source-only public preview:

- pinned the public `rl-c-client` `v0.2.0` release by tag and full commit;
- added deterministic public dependency bootstrap and a local responder
  fixture;
- expanded static, dynamic, configuration, integration, lifecycle, sanitizer,
  and nginx-version validation;
- documented build, configuration, operations, compatibility, specification,
  contribution, and security expectations; and
- clarified that the module does not include or operate a RateLimitly server,
  tenant, DNS service, credentials, binary package, or container image.

The planned preview scope and supported matrix are maintained in
[`docs/compatibility.md`](docs/compatibility.md). Release notes will record the
exact source revisions, platform, compiler, and validation evidence when a
tagged release is made.
