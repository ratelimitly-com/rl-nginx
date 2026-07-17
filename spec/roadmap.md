# Roadmap candidates and non-features

This file is non-normative. It separates possible future work from the
implemented contract in the other specification files. Nothing here is a
release commitment.

The current module does **not** provide:

- Prometheus counters, histograms, a built-in metrics exporter, or a
  module-specific health endpoint;
- nginx directives for selecting a fixed RateLimitly server address;
- nginx directives for configuring C-client wait, quorum, response-selection,
  retry, deduplication, or DNS-resynchronization policies;
- dynamic zone, group, guard, credential, or policy updates without a normal
  nginx configuration reload;
- a deterministic single-commit routing mode owned by the nginx module;
- prebuilt nginx packages, container images, or a package repository; or
- a RateLimitly server. The public C-client responder is only a deterministic
  UDP test fixture, and its `--listen` option is not a server/product option.

Possible proposals include log-derived or native metrics, additional policy
controls, packaging, and an explicitly designed multi-target commit strategy.
A proposal becomes part of the normative contract only after its configuration
surface, security/availability semantics, public tests, operations guidance,
and compatibility impact are implemented and reviewed together.
