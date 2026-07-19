# rl-nginx normative reference

The files in this directory specify the behavior implemented by the current
`rl-nginx` source and its locked `rl-c-client` dependency. They are a reference
for maintainers, reviewers, and compatible implementations; deployment advice
and copyable examples remain in [`docs/`](../docs/index.md).

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**,
and **MAY** are to be interpreted as normative requirements. A mismatch between
the normative files, source, and required public tests is a defect and must be
resolved in the same change.

## Documents

- [Configuration DSL](dsl.md) defines directive syntax, scope, validation,
  inheritance, ordering, and defaults.
- [Request behavior](behavior.md) defines activation, request decisions,
  failure policy, cleanup, steering, and latency reporting.
- [Wire mapping](mapping.md) defines the values supplied to the locked C client
  and the resulting RateLimitly request/report fields.
- [Implementation constraints](implementation.md) defines the non-blocking
  nginx/C-client integration and conformance boundaries.
- [Roadmap and non-features](roadmap.md) is explicitly non-normative. Its items
  are not implemented behavior or commitments.

## Conformance evidence

The required static contributor gate is `make check`. It combines configuration
parsing with public DNS, lifecycle, enforcement, failure-policy, recovery,
protocol, cardinality, reload, and shutdown tests while preserving the binary
produced from its static `BUILD_FLAGS`. Release conformance additionally
requires relocated dynamic-module behavior on both supported architectures and
ASan/UBSan/LSan coverage on both supported nginx lines. The optional private
full-stack test is supplemental, not public conformance evidence. The
lightweight specification consistency test checks directive coverage and
executable defaults, but it does not replace behavioral tests.
