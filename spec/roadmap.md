# Roadmap candidates and non-features

This file is non-normative. It separates possible future work from the
implemented contract in the other specification files. Nothing here is a
release commitment.

The current module does **not** provide:

- Prometheus counters, histograms, a built-in metrics exporter, or a
  module-specific health endpoint;
- nginx directives for selecting a fixed RateLimitly server address;
- nginx directives for configuring C-client replay count, replay/preference
  schedules, final receive time, completion delivery, or DNS refresh policy;
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

## Latency measurement questions

The current guard sample is the complete nginx request lifetime from request
start to log phase, measured in the existing wall-clock domain. This is
deliberate for the public preview: RateLimitly deployments already require
tightly synchronized client and server clocks, and changing either the
measurement boundary or clock domain would change policy meaning rather than
merely harden an implementation detail.

[Issue #49](https://github.com/ratelimitly-com/rl-nginx/issues/49) tracks
whether a future contract should isolate protected-service work, use a
different clock boundary, or assert exact reported values in the public
fixture. It is not a release blocker. Reevaluate it after evidence of
clock-step failures, a requirement for service-only latency, a protocol change
that defines a different timestamp domain, removal of the synchronized-clock
deployment assumption, or fixture support for a portable numeric-value oracle.
