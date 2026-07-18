# Changelog

All notable changes to `rl-nginx` will be documented here. Release candidates
remain preview software and must not be treated as ABI-stable versions.

## Unreleased — next release candidate

Changes since `v0.1.0-rc.1`:

- moved RateLimitly enforcement to the final pre-content admission point so
  nginx access rejection and routing happen before resource consumption;
- defined a valid allow as consumed admission directly into content processing
  and added static, dynamic, and sanitizer regression coverage for the
  ordering contract;
- preserved one admission across nginx internal redirects and kept subrequests
  outside independent RateLimitly accounting;
- drained nginx posted requests after asynchronous verdict callbacks so
  resumed content cannot remain pinned awaiting an unrelated client event;
- fixed nginx resolver-context ownership across allocation failures,
  synchronous completion, start failure, cancellation, and worker shutdown;
- made partial worker initialization transactional, including destruction of a
  successfully created C client when a later initialization step fails;
- made steering rebinds transactional: the current UDP endpoint stays active
  until its replacement is registered, and failed replacements retry later;
- added test-only resolver, worker-initialization, and rebind fault injection to
  the ASan/UBSan lifecycle gate.

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
