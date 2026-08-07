# Configuration DSL

This document defines the implemented nginx configuration contract. Security
guidance for selecting variables and constructing identities is normative here
and explained with examples in
[Configuring rl-nginx](../docs/configuration.md).
The locked C-client remains authoritative for the underlying
[credential quotas](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#credentials)
and
[content-defined identifier inputs](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#content-defined-ids);
this document defines how nginx directives provide and validate those values.

## Scope and activation

The following directives are valid only in the nginx `http` context:

- `ratelimitly_dns_srv`
- `ratelimitly_dns_resolver`
- `ratelimitly_auth_key`
- `ratelimitly_policy`
- `ratelimitly_fail`
- `ratelimitly_bind`
- `ratelimitly_debug`
- `ratelimitly_zone`
- `ratelimitly_guard`
- `ratelimitly_group`

`ratelimitly` and `ratelimitly_label` are valid in `server` and `location`
contexts. The module is enabled only when at least one effective `ratelimitly`
rule exists. When enabled anywhere in `http`, `ratelimitly_auth_key` MUST be
present or nginx configuration loading fails. `ratelimitly_dns_srv` is OPTIONAL.

Zones, guards, and groups MUST be defined before a rule references them. Zones
MUST be defined before a group references them. Names are case-sensitive.

## Directives

### `ratelimitly_dns_srv`

```nginx
ratelimitly_dns_srv <tenant-dns-name>;
```

The value supplies the tenant DNS name to the locked C client. When omitted,
`ratelimitly_dns_srv` defaults to `c-${api-key-id}.p0.ratelimitly.com` derived
from the embedded key ID of `ratelimitly_auth_key`. Supported deployments MUST
publish `_ratelimitly._udp.<tenant-dns-name>` SRV records. This is not a fixed
server-address directive. A second occurrence is a configuration error.

### `ratelimitly_dns_resolver`

```nginx
ratelimitly_dns_resolver <address> ...;
```

`ratelimitly_dns_resolver` (alias `ratelimitly_resolver`) specifies custom DNS
resolver IP addresses used for RateLimitly SRV discovery. `ratelimitly_dns_resolver`
is OPTIONAL. When omitted, RateLimitly uses nginx's HTTP-scope `resolver` if
configured, or defaults to the system DNS (`/etc/resolv.conf`).

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

### `ratelimitly_policy`

```nginx
ratelimitly_policy standard [unit=<duration>];
ratelimitly_policy single_round [unit=<duration>];
ratelimitly_policy custom
  unit=<duration>
  replays=<0..65535>
  replay_gap=<schedule>
  final_wait_units=<uint32>
  completion_delivery=on|off;
```

The directive selects the C-client resource-request policy. It MAY occur only
once. When omitted, `standard unit=20ms` is effective.

`unit` is the base scheduling unit `U`, not the total request timeout. It MUST
be a positive duration accepted by nginx's millisecond-mode time parser whose
total fits `1..4294967295ms`. Accepted units are `w`, `d`, `h`, `m`, `s`, and
`ms`; compound components appear from larger to smaller units. A final
unitless number means seconds, so `unit=1` is `1000ms`, not `1ms`.

The named policies have fixed shapes and accept no parameter other than
`unit`:

| Policy | `N` | `B(k)` | `F` | Completion delivery | Horizon / dedup TTL |
| --- | ---: | --- | ---: | --- | ---: |
| `single_round` | `0` | `B(0)=1` | `0` | off | `U` |
| `standard` | `1` | `B(0)=B(1)=1` | `1` | on | `3 * U` |

Both use fixed one-unit replay-gap schedules. A valid response from the oldest
discovered server during Round 0 or from any server in subsequent rounds can
complete before the horizon. `single_round` disables completion delivery so it
never creates a second best-effort transmission after selecting a response.

`custom` exposes every field of the locked C-client request policy. Every
listed argument is required exactly once; unknown and duplicate arguments are
errors. `replays` counts retransmissions of the same logical request identity,
not new requests. Its nginx-to-C mapping is:

| nginx argument | C-client field |
| --- | --- |
| `unit` | `unit_ms` |
| `replays` | `replay_count` |
| `replay_gap` | `replay_gap` (`B(k)`) |
| `final_wait_units` | `final_receive_units` (`F`) |
| `completion_delivery` | `completion_delivery` |

All schedule and final-wait numbers are multiples of `U`. `replay_gap` defines
the duration of every transmission round, including the initial round `k=0`.
Schedules use one of these forms:

```text
fixed:<units>
linear:<initial-units>:<step-units>:<maximum-units>
exponential:<initial-units>:<factor>:<maximum-units>
```

The linear step MUST be at least one, the exponential factor MUST be at least
two, and the initial value MUST NOT exceed the maximum. The replay gap MUST
start above zero.

For replay rounds `k = 0..replays`, let `B(k)` be the selected
`replay_gap` value and let `F` be `final_wait_units`. The maximum admission
interval and wire deduplication TTL are:

```text
H = U * (sum(B(k), k = 0..replays) + F)
```

Configuration loading fails when the policy is structurally invalid, `H`
does not fit the wire field, or an enabled configuration's `H` exceeds the
API key's `dedup_ttl_ms_max`. The locked C-client documentation remains
authoritative for response selection, replay, final-phase, completion-delivery,
and conditional deduplication semantics.

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

`bucket` is an nginx complex value rendered per request. The exact bytes and
length are hashed as specified in [Wire mapping](mapping.md). Components MUST
be canonical and bounded and MUST NOT treat request arguments, headers,
cookies, or raw paths as authenticated identity. Binary values, including
embedded NUL bytes, are represented exactly, but template authors still own
the trust, cardinality, and unambiguous composition of those bytes.

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

Threshold and TTL use the same duration grammar as `ratelimitly_policy unit`; a
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
| `ratelimitly_dns_srv` | `c-${api-key-id}.p0.ratelimitly.com` |
| `ratelimitly_dns_resolver` | system DNS (`/etc/resolv.conf`) |
| `ratelimitly_policy` | `standard unit=20ms` |
| `ratelimitly_fail` | `open` |
| `ratelimitly_bind` | kernel-selected local address, ephemeral port |
| `ratelimitly_debug` | `off` |
| `ratelimitly_guard ttl` | `30s` |
| `ratelimitly_guard max_samples` | `128` |
| `ratelimitly_guard buffer_size` | credential's `latency_buffer_size_max` |
| `ratelimitly_guard min_sample_threshold` | `8` |

Production configurations SHOULD set request and failure policy explicitly
after assessing enforcement bypass, dependency denial, and request-latency
budgets.
