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

### ratelimitly_key_id

```
ratelimitly_key_id <uint64>;
```

### ratelimitly_auth

```
ratelimitly_auth none;            # development-only (not supported in production)
ratelimitly_auth cookie <hex_cookie_32bytes>;
ratelimitly_auth aesgcm <secret>;
```

### ratelimitly_timeout

```
ratelimitly_timeout <duration>;
```

### ratelimitly_fail

```
ratelimitly_fail open;
ratelimitly_fail close;
```

### ratelimitly_zone

```
ratelimitly_zone zone=<name> bucket="<template>" rate=<N>r/<period>;
```

Notes:
- `bucket` is a string template evaluated per request using nginx variables (e.g. `"low-throughput:$uri:$cookie"`).
- `<period>` supports `s`, `m`, `h` (seconds, minutes, hours).

### ratelimitly_group

```
ratelimitly_group <name> zone=<zone1> zone=<zone2> ...;
```

Notes:
- Groups are expanded at config load time.
- Group zones are appended in the order listed.

### ratelimitly

```
ratelimitly zone=<name>;
ratelimitly group=<name>;
```

Notes:
- Multiple `ratelimitly` directives are allowed in a single `location`/`server`.
- All resolved zones are combined into one Ratelimitly request with multiple ResourceBlocks.

### ratelimitly_label

```
ratelimitly_label "<template>";
```

Notes:
- Optional. When set, the template is rendered per request (nginx variables expanded) and sent as the `metrics_label` TLV.

## Defaults

- `ratelimitly_timeout`: 20ms
- `ratelimitly_fail`: open

## Non-goals (initial MVP)

- Guards / latency thresholds
- Dynamic rule updates beyond per-request rules
