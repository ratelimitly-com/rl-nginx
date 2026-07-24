# Configuration DSL

This document defines the implemented nginx configuration contract. Security
guidance for selecting variables and constructing identities is normative here
and explained with examples in
[Configuring rl-nginx](../docs/configuration.md).

## Scope and activation

The following directives are valid only in the nginx `http` context:

- `ratelimitly_tenant`
- `ratelimitly_auth_key`
- `ratelimitly_timeout`
- `ratelimitly_fail`
- `ratelimitly_bind`
- `ratelimitly_debug`
- `ratelimitly_zone`
- `ratelimitly_guard`
- `ratelimitly_group`

`ratelimitly` and `ratelimitly_label` are valid in `server` and `location`
contexts. The module is enabled only when at least one effective `ratelimitly`
rule exists. When enabled anywhere in `http`, `ratelimitly_tenant` and
`ratelimitly_auth_key` MUST both be present or nginx configuration loading
fails.

Zones, guards, and groups MUST be defined before a rule references them. Zones
MUST be defined before a group references them. Names are case-sensitive.

## Directives

### `ratelimitly_tenant`

```nginx
ratelimitly_tenant <tenant-dns-name>;
```

The value supplies the tenant DNS name to the locked C client. Supported
deployments MUST publish `_ratelimitly._udp.<tenant-dns-name>` SRV records.
This is not a fixed server-address directive. A second occurrence is a
configuration error.

### `ratelimitly_auth_key`

```nginx
ratelimitly_auth_key <bech32-api-key>;
```

The key MUST decode through the locked C-client parser as either an
`rl-cookie...` credential with a 32-byte cookie secret or an `rl-aes...`
credential with a 32-byte AES key. Its embedded key ID becomes the tenant key
ID used on the wire. A malformed value or second occurrence is a configuration
error.

The credential is sensitive and MUST NOT be committed or placed in copyable
examples. See the configuration and operations guides for include-file,
`nginx -T`, rotation, and log-handling requirements.

### `ratelimitly_timeout`

```nginx
ratelimitly_timeout <duration>;
```

The value MUST be a positive duration accepted by nginx's millisecond-mode time
parser whose total fits `1..4294967295ms`. Accepted units are `w`, `d`, `h`,
`m`, `s`, and `ms`; compound components appear from larger to smaller units.
A final unitless number means seconds, so `1` is `1000ms`, not `1ms`. It becomes
the C-client attempt timeout. The module sets retry attempts to zero, so the
timeout bounds the only attempt. If repeated, the later value is effective;
configurations SHOULD define it once.

### `ratelimitly_fail`

```nginx
ratelimitly_fail open;
ratelimitly_fail close;
```

`open` continues normal nginx processing when no valid RateLimitly decision is
available. `close` returns `429 Too Many Requests`. Valid RateLimitly denies
return `429` under both policies. Internal nginx allocation/event errors can
return `500` under both policies. If repeated, the later value is effective;
configurations SHOULD define it once.

### `ratelimitly_bind`

```nginx
ratelimitly_bind <local-ip>;
```

The value selects the local IPv4 or IPv6 address for the worker UDP socket. The
port is always ephemeral. It does not select a RateLimitly server. The address
is parsed and validated while loading configuration, so invalid syntax fails
`nginx -t`. The socket is bound when a worker handles its first protected
request; an unavailable valid address makes worker-client initialization
follow the failure policy. When omitted, the kernel selects the local address.
A second occurrence is a configuration error.

### `ratelimitly_debug`

```nginx
ratelimitly_debug on;
ratelimitly_debug off;
```

The default is `off`. `on` enables additional module decision, DNS, UDP,
identifier, latency-report, and steering messages. Debug-level messages also
require an nginx binary built with `--with-debug` and an effective debug error
log. Debug output MUST be treated as sensitive operational data and SHOULD be
enabled only for a bounded diagnostic window. A second occurrence is a
configuration error regardless of whether the first value is `on` or `off`.

### `ratelimitly_zone`

```nginx
ratelimitly_zone <name> "bucket=<template>" rate=<rate-expression>;
```

The directive takes exactly one positional name plus one nonempty `bucket=` and
one nonempty `rate=` argument. The two named arguments MAY appear in either
order. A name containing `=` or a duplicate zone name is a configuration error.
When quoting is needed, the quotes MUST enclose the complete named argument as
shown above. `bucket="value"` is invalid because nginx treats quotes that start
in the middle of a token as literal bytes.

`bucket` is an nginx complex value rendered per request. The rendered text is
hashed as specified in [Wire mapping](mapping.md). Components MUST be canonical
and bounded and MUST NOT treat request arguments, headers, cookies, or raw
paths as authenticated identity. `$binary_remote_addr` MUST NOT be used: the
current text hash boundary is NUL-terminated and embedded NUL bytes can truncate
the identity. Use textual `$remote_addr` with correctly configured real-IP or
proxy-protocol trust. This is an operator precondition, not a parser guarantee:
nginx complex-value compilation does not expose enough type information for
rl-nginx to reject that variable name reliably, and the module does not scan
rendered values for embedded NUL bytes before hashing.

The rendered bucket is one flat string, not a framed list of components.
Configuration MUST make field boundaries unambiguous by using fixed values and
finite-map outputs whose allowed alphabet excludes the chosen delimiter. At
most one other bounded textual component MAY contain the delimiter, and then
it MUST be last. A change to the rendered text schema changes the hashed
resource identity and MUST be treated as a bucket-state migration.

The rendered bucket MUST contain `1..1024` bytes. An oversized static template
is a configuration error. An empty or oversized dynamic result follows
`ratelimitly_fail` and MUST NOT be sent to the C client.

`rate` is also an nginx complex value. A static value is validated during
configuration loading; a value containing variables is rendered and validated
for each request. A per-request failure follows `ratelimitly_fail`.

The accepted rate grammar is:

```text
<rate>r/<period><unit>
```

- `<rate>` is decimal `1..4294967295`.
- `<period>` is an optional decimal integer; omitted or zero means one unit.
- `<unit>` is exactly `s`, `m`, or `h`.
- No spaces, signs, suffixes, or fractional values are accepted.
- The period converted to milliseconds MUST fit `1..4294967295`. The largest
  accepted whole-unit values are `4294967s`, `71582m`, and `1193h`.

Canonical configurations SHOULD use an omitted period for one unit (`10r/s`)
and a positive explicit period otherwise (`100r/2s`), rather than the accepted
but redundant `0` form.

### `ratelimitly_guard`

```nginx
ratelimitly_guard <name>
  "service=<template>"
  threshold=<duration-or-template>
  [ttl=<duration>]
  [max_samples=<uint32>]
  [buffer_size=<uint32>]
  [min_sample_threshold=<uint32>];
```

The positional name, nonempty `service=`, and nonempty `threshold=` are
required. A name containing `=` or a duplicate guard name is a configuration
error. Unknown named arguments are rejected.
When quoting is needed, the quotes MUST enclose the complete `service=`
argument. `service="value"` is invalid because those quotes would be literal
identifier bytes.

`service` is rendered per request and hashed as specified in
[Wire mapping](mapping.md). It SHOULD be fixed or selected from a finite,
operator-controlled map. An empty rendered service follows the failure policy.
Raw host, URI, argument, header, cookie, or user values MUST NOT create service
cardinality.

The rendered service MUST contain `1..1024` bytes. An oversized static template
is a configuration error. An empty or oversized dynamic result follows
`ratelimitly_fail` and MUST NOT be sent to the C client.

`threshold` is an nginx complex value parsed as milliseconds. A static value is
validated at configuration load; a value containing variables is validated per
request and follows the failure policy on error. `ttl` and all sample fields
are static and validated at configuration load.

Threshold and TTL use the same duration grammar as `ratelimitly_timeout`; a
unitless value means seconds. Their millisecond values MUST fit
`1..4294967295`, so zero is invalid. All sample fields MUST fit an unsigned
32-bit wire field. `max_samples` and `buffer_size` MUST be nonzero.
`min_sample_threshold=0` is valid and disables only the insertion-rate
sufficiency gate; it does not synthesize a retained latency sample.

### `ratelimitly_group`

```nginx
ratelimitly_group <name> zone=<zone1> [zone=<zone2> ...];
```

The positional name MUST be nonempty and MUST NOT contain `=`. At least one
nonempty `zone=` reference is required. Every argument after the name MUST be
`zone=` and MUST reference a previously defined zone. A duplicate group name
is a configuration error. A group preserves listed order and does not
deduplicate repeated zone references; each occurrence maps to a ResourceBlock.

### `ratelimitly`

```nginx
ratelimitly zone=<name> [guard=<guard1> ...];
ratelimitly group=<name> [guard=<guard1> ...];
```

Each directive MUST contain exactly one `zone=` or `group=` reference and MAY
contain zero or more `guard=` references. Every reference MUST be nonempty and
MUST already exist. Unknown arguments and a rule containing both or neither
resource reference are configuration errors, including when either textual
reference has an empty value.

Multiple rules in one effective context are combined into one RateLimitly
request. Zones, including repeated references, remain separate ResourceBlocks.
Repeated references to the same guard definition are deduplicated; distinct
guards remain in first-seen rule order.

Rules are inherited from `server` to nested `location` contexts, and through
nested locations, only when the child has no rule of its own. Once a child
declares a `ratelimitly` rule, its rule list replaces rather than appends to the
inherited list.

### `ratelimitly_label`

```nginx
ratelimitly_label "<template>";
```

The effective label is rendered once per protected request and supplied with
the combined rule. It MUST contain at most 256 bytes. An oversized static label
is a configuration error; an oversized dynamic label follows
`ratelimitly_fail` and MUST NOT reach the C client. An empty rendered value
omits the metrics-label TLV. A child inherits its parent's label unless it
declares its own; a later label in the same context is effective.

Labels MUST be bounded and non-sensitive. Raw paths, arguments, headers,
cookies, credentials, session tokens, user identifiers, email addresses, and
source addresses MUST NOT be used as label values.

## Executable defaults

| Setting | Default |
| --- | --- |
| `ratelimitly_timeout` | `20ms` |
| `ratelimitly_fail` | `open` |
| `ratelimitly_bind` | kernel-selected local address, ephemeral port |
| `ratelimitly_debug` | `off` |
| `ratelimitly_guard ttl` | `30s` |
| `ratelimitly_guard max_samples` | `128` |
| `ratelimitly_guard buffer_size` | `128` |
| `ratelimitly_guard min_sample_threshold` | `8` |

Production configurations SHOULD set timeout and failure policy explicitly
after assessing enforcement bypass, dependency denial, and request-latency
budgets.
