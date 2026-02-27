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
  - `rl-none...`
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
- `bucket` is a string template evaluated per request using nginx variables (e.g. `"low-throughput:$uri:$cookie"`).
- `rate` is evaluated per request using nginx complex values.
  - Static example: `rate=600r/m`
  - Dynamic example: `rate=$rl_dynamic_rate`
- Rendered `rate` must match `N r / period` without spaces (e.g. `10r/s`, `100r/2s`, `500r/1h`).
- `<period>` unit supports `s`, `m`, `h` (seconds, minutes, hours).

### ratelimitly_guard

```
ratelimitly_guard <name> service="<service_expr>" threshold=<duration_or_expr> [ttl=<duration>] [max_samples=<uint>] [buffer_size=<uint>] [min_sample_threshold=<uint>];
```

Notes:
- Defines a reusable latency guard for load shedding.
- `<name>` is a positional first argument.
- `service` is rendered per request using nginx variables, then hashed with BLAKE2s-128 to produce `service_id`.
  - Example: `service="svc:api:$host:$uri"`
- `threshold` is rendered per request and parsed as duration in milliseconds.
  - Static example: `threshold=80ms`
  - Dynamic example: `threshold=$rl_guard_threshold`
- Optional parameters map to guard tuning fields in the wire protocol:
  - `ttl` -> `ttl_ms`
  - `max_samples` -> `max_samples`
  - `buffer_size` -> `buffer_size`
  - `min_sample_threshold` -> `min_sample_threshold`
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
- Optional. When set, the template is rendered per request (nginx variables expanded) and sent as the `metrics_label` TLV.

## Defaults

- `ratelimitly_timeout`: 20ms
- `ratelimitly_fail`: open
- `ratelimitly_guard ttl`: 30s
- `ratelimitly_guard max_samples`: 128
- `ratelimitly_guard buffer_size`: 128
- `ratelimitly_guard min_sample_threshold`: 8

## Non-goals (initial MVP)

- Dynamic rule updates beyond per-request rules
