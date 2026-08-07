# Changelog

All notable changes to `rl-nginx` will be documented here. Release candidates
remain preview software and must not be treated as ABI-stable versions.

## Unreleased

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
- made guard latency feedback require an explicit valid allow and suppress it
  after denial, request-start failure, dependency fail-open/fail-close,
  timeout, cardinality mismatch, or client abort;
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
