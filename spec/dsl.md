# Configuration DSL (Draft)

## Goals

- Minimal nginx-native directives.
- Deterministic mapping to Ratelimitly resource blocks.
- Safe defaults for timeouts and failure mode.

## Directives

### ratelimitly_tenant

```
ratelimitly_tenant <tenant_dns_name>;
```

### ratelimitly_auth_key

```
ratelimitly_auth_key <bech32_api_key>;
```

Notes:
- Required.
- Must be one of:
  - `rl-cookie...` (payload is 32-byte cookie hash)
  - `rl-aes...` (payload is 32-byte AES key)
- The embedded `key_id` is used as tenant id automatically.

### ratelimitly_timeout

```
ratelimitly_timeout <duration>;
```

### ratelimitly_fail

```
ratelimitly_fail open;
ratelimitly_fail close;
```

### ratelimitly_bind

```
ratelimitly_bind <ip>;
```

Notes:
- Optional. Bind the UDP client socket to a specific local IP (IPv4 or IPv6).
- If omitted, the module binds to an ephemeral local address/port.

### ratelimitly_debug

```
ratelimitly_debug on|off;
```

Notes:
- Optional. Enables extra debug logging for UDP send/recv and callback decisions.
- When enabled, logs SRV resolution targets and response unique_ids.

### ratelimitly_zone

```
ratelimitly_zone <name> bucket="<template>" rate=<rate_expr>;
```

Notes:
- `<name>` is a positional first argument.
- `bucket` is a string template evaluated per request using nginx variables
  (for example, `"v1|scope=low-throughput|ip=$remote_addr"`). Direct request
  arguments, headers, cookies, and raw paths MUST NOT be treated as trusted
  identity. Variable components MUST be canonical and bounded so clients cannot
  create arbitrary buckets or ambiguous field boundaries.
- `$binary_remote_addr` MUST NOT be used with the current text hash interface;
  embedded NUL bytes can truncate it. Use textual `$remote_addr` and configure
  real-IP/proxy-protocol trust before relying on it.
- `rate` is evaluated per request using nginx complex values.
  - Static example: `rate=600r/m`
  - Dynamic example: `rate=$rl_dynamic_rate`
- A static `rate` MUST be validated at configuration load time. A `rate`
  containing nginx variables MUST be validated after rendering it for a
  request.
- Rendered `rate` must match `N r / period` without spaces (e.g. `10r/s`, `100r/2s`, `500r/1h`).
- `<period>` unit supports `s`, `m`, `h` (seconds, minutes, hours).
- `N` MUST be in `1..4294967295`.
- The period converted to milliseconds MUST be in `1..4294967295`. With the
  supported whole-unit syntax, the largest accepted period values are
  `4294967s`, `71582m`, and `1193h`.
- An implementation MUST reject decimal accumulation or unit multiplication
  that would overflow the corresponding 32-bit wire field.

### ratelimitly_guard

```
ratelimitly_guard <name> service="<service_expr>" threshold=<duration_or_expr> [ttl=<duration>] [max_samples=<uint>] [buffer_size=<uint>] [min_sample_threshold=<uint>];
```

Notes:
- Defines a reusable latency guard for load shedding.
- `<name>` is a positional first argument.
- `service` is rendered per request using nginx variables, then hashed with BLAKE2s-128 to produce `service_id`.
  - Example: `service="v1|service=public-api"`
  - Service values SHOULD be fixed or selected from a finite operator-controlled
    map. Raw host, URI, argument, header, cookie, or user values MUST NOT create
    attacker-controlled service cardinality.
- `threshold` is rendered per request and parsed as duration in milliseconds.
  - Static example: `threshold=80ms`
  - Dynamic example: `threshold=$rl_guard_threshold`
- A static `threshold` MUST be validated at configuration load time. A
  `threshold` containing nginx variables MUST be validated after rendering it
  for a request.
- Optional parameters map to guard tuning fields in the wire protocol:
  - `ttl` -> `ttl_ms`
  - `max_samples` -> `max_samples`
  - `buffer_size` -> `buffer_size`
  - `min_sample_threshold` -> `min_sample_threshold`
- Parsed threshold and TTL milliseconds and all three tuning integers MUST fit
  an unsigned 32-bit wire field. `max_samples` and `buffer_size` MUST be
  nonzero.
- `min_sample_threshold=0` MUST be accepted and MUST disable only the
  insertion-rate sufficiency gate. A retained, non-expired sample is still
  required for a minimum latency to be available. A positive value requires
  the estimated insertion rate to reach that value before retained samples are
  used by the guard.
- Guards referenced by `ratelimitly ... guard=<name>` must be defined before use.

### ratelimitly_group

```
ratelimitly_group <name> zone=<zone1> zone=<zone2> ...;
```

Notes:
- Groups are expanded at config load time.
- Group zones are appended in the order listed.
- Zones referenced by a group must be defined before the group.

### ratelimitly

```
ratelimitly zone=<name> [guard=<guard1>] [guard=<guard2>] ...;
ratelimitly group=<name> [guard=<guard1>] [guard=<guard2>] ...;
```

Notes:
- Multiple `ratelimitly` directives are allowed in a single `location`/`server`.
- All resolved zones are combined into one Ratelimitly request with multiple ResourceBlocks.
- All referenced guards are combined into the same request as GuardBlocks.
- All guards must pass (`current_latency < threshold`) for the request to be granted.
- Zones and groups must be defined before they are referenced.
- Guards must be defined before they are referenced.

### ratelimitly_label

```
ratelimitly_label "<template>";
```

Notes:
- Optional. When set, the template is rendered per request (nginx variables
  expanded) and sent as the `metrics_label` TLV.
- Labels MUST be bounded and non-sensitive. Raw paths, arguments, headers,
  cookies, credentials, session tokens, user identifiers, email addresses, and
  source addresses MUST NOT be used as label values.

## Defaults

- `ratelimitly_timeout`: 20ms
- `ratelimitly_fail`: open. Production configurations SHOULD set this
  explicitly after assessing enforcement bypass under fail-open and legitimate
  traffic denial under fail-close.
- `ratelimitly_guard ttl`: 30s
- `ratelimitly_guard max_samples`: 128
- `ratelimitly_guard buffer_size`: 128
- `ratelimitly_guard min_sample_threshold`: 8

## Non-goals (initial MVP)

- Dynamic rule updates beyond per-request rules
