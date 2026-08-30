# rl-nginx documentation

`rl-nginx` connects nginx's HTTP request lifecycle to RateLimitly through the
public C client. The documentation is layered so readers can learn the model
before dealing with build, configuration, or operational details.

## Start here

1. Read the README's [operation model](../README.md#the-operation-model) and
   [small nginx examples](../README.md#three-small-nginx-examples).
2. Build a supported static or dynamic module with
   [Building and installing rl-nginx](build.md).
3. Turn application policy into nginx directives with
   [Configuring rl-nginx](configuration.md).
4. Before production, read [Operating rl-nginx](operations.md) and the
   [Compatibility and release scope](compatibility.md).

Copyable configurations are in [`examples/`](../examples/). Start with
[`minimal.conf`](../examples/minimal.conf); use
[`security-conscious.conf`](../examples/security-conscious.conf) for bounded
identity maps, dynamic rates, labels, and latency guards.

## Find a topic

| Goal | Document |
| --- | --- |
| Build or package the module | [Build and installation](build.md) |
| Configure resources, groups, guards, credentials, and failure policy | [Configuration guide](configuration.md) |
| Plan DNS, rollout, logging, recovery, and troubleshooting | [Operations guide](operations.md) |
| Check supported nginx/client versions and release gates | [Compatibility guide](compatibility.md) |
| Understand the nginx/C-client ownership and callback boundary | [C-client integration](c-client.md) |
| Look up exact directive or observable behavior | [Normative specification](../spec/index.md) |
| Run or extend the public lifecycle fixtures | [Integration-test guide](../integration-tests/README.md) |

## Documentation ownership

This repository is authoritative for behavior added by the nginx module:

- directive syntax, scope, inheritance, and rendered nginx values;
- final pre-content admission ordering and internal-redirect behavior;
- fail-open/fail-close mapping and `$ratelimitly_verdict`;
- nginx request, timer, resolver, socket, reload, and cleanup lifetimes; and
- the module's admission-aware HTTP latency measurement.

The locked
[`rl-c-client v2.0.0`](https://github.com/ratelimitly-com/rl-c-client/tree/v2.0.0)
documentation is authoritative for behavior owned by the client:

- [resource requests and independent latency reports](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/README.md#core-operations);
- [credentials and API-key quotas](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/docs/api.md#credentials);
- [content-defined bucket and latency-tracker IDs](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/docs/api.md#content-defined-ids);
- [resource-request HA policy and deduplication TTL](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/docs/api.md#resource-request-ha-policy);
- [DNS refresh](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/docs/api.md#dns-refresh); and
- [client error codes](https://github.com/ratelimitly-com/rl-c-client/blob/v2.0.0/docs/api.md#error-codes).

Links deliberately target the supported tag rather than `main`. The exact tag
and commit are locked in
[`dependencies/rl-c-client.env`](../dependencies/rl-c-client.env). Updating the
lock requires reviewing these links, the nginx-specific summaries, and the
executable compatibility contract together.

## Project policies and history

- [`SUPPORT.md`](../SUPPORT.md) — support scope and issue-report checklist.
- [`SECURITY.md`](../SECURITY.md) — private vulnerability reporting.
- [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md) — community standards.
- [`CHANGELOG.md`](../CHANGELOG.md) — release status and notable changes.
- [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) — dependency licenses.
