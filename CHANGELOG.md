# Changelog

All notable changes to `rl-nginx` will be documented here. Until a tagged
release is published, `main` is development code and must not be treated as a
released or ABI-stable version.

## Unreleased — public-readiness work

This repository is preparing the first planned `0.1.x` source-only public
preview. No `rl-nginx` release has been published yet.

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

