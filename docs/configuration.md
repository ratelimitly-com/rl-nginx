# Configuring rl-nginx

`rl-nginx` defines RateLimitly credentials, resource buckets, optional latency
guards, and the nginx locations that require decisions. Configuration values
are part of the enforcement boundary: an attacker-controlled identity can
split traffic across unlimited buckets, while an unbounded label can create
excessive telemetry cardinality or an oversized request.

This guide explains how nginx directives construct those operations. For the
underlying meanings of resource requests, latency reports, API-key quotas, and
client policy, follow the versioned `rl-c-client` links in the relevant
sections or start with its
[Operation Model](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#operation-model).

## Minimal configuration

The tenant and API key below are deliberately non-working placeholders. Replace
both before running `nginx -t`.

```nginx
http {
  resolver 127.0.0.53 valid=30s ipv6=off;
  resolver_timeout 2s;

  ratelimitly_tenant   tenant.example.invalid;
  ratelimitly_auth_key rl-aes1REPLACE_WITH_YOUR_KEY;
  ratelimitly_policy   standard unit=50ms;
  ratelimitly_fail     close;

  ratelimitly_zone api_per_ip
    "bucket=v1|scope=api|ip=$remote_addr"
    rate=100r/s;

  server {
    listen 8080;

    location /api/ {
      ratelimitly_label "scope=api";
      ratelimitly zone=api_per_ip;
      proxy_pass http://127.0.0.1:9000;
    }
  }
}
```

The fixed `scope` value gives this policy its own namespace. `$remote_addr` is
the only variable component and is last, so it cannot change the meaning of a
later field. If nginx's real-IP module rewrites `$remote_addr`, trust forwarded
addresses only from explicitly configured proxy networks.

See [`examples/security-conscious.conf`](../examples/security-conscious.conf)
for bounded route/method maps and a dynamic rate that cannot take arbitrary
client-supplied text.

## Admission order and resource consumption

RateLimitly is the final admission point before nginx content processing. nginx
first resolves its access policy, including `allow`/`deny`, `auth_basic`,
`auth_request`, and the configured `satisfy all|any` behavior. Pre-content
routing such as `try_files` also runs before the RateLimitly request.

A request rejected or finalized before that point does not reach RateLimitly
and does not consume a RateLimitly resource. A valid RateLimitly allow means the
requested resource has been consumed; the module then advances directly to the
selected content handler or upstream. A later disconnect, content error, or
upstream failure does not refund that consumption. `ratelimitly_fail open` is
different: it advances without a valid decision and therefore without a
guarantee that RateLimitly recorded consumption.

Internal redirects do not create a second admission. nginx can internally
redirect while selecting an index, rendering an error page, or executing
another content handler, but those steps remain part of the same main HTTP
request. The module preserves and reuses the original completed allow, deny,
or failure policy outcome across that routing. nginx subrequests are not
independently rate limited by this module.

## Decide which variables are identities

nginx complex values make many variables available, but availability does not
make a value trustworthy or suitable for a bucket key.

| Variable source | Security property | Guidance |
| --- | --- | --- |
| Fixed configuration and outputs of finite `map` tables | Operator-controlled and bounded | Prefer these for policy names, routes, methods, rates, services, and labels. |
| `$remote_addr` | Derived from the peer connection | Suitable for per-source limits unless a misconfigured real-IP/proxy-protocol path lets clients spoof it. |
| `$server_name` | Selected from nginx configuration | Prefer it over `$host` when a configured virtual-server identity is required. |
| `$request_method` and `$uri` | Parsed/normalized by nginx but selected by the client | Map them to a small fixed vocabulary before using them in buckets, services, or labels. |
| `$host`, `$arg_*`, `$http_*`, and `$cookie_*` | Directly or effectively client-controlled | Never use them as authenticated identity. Do not place raw values in bucket, service, rate, threshold, or label templates. |
| `$remote_user` or an authentication-derived variable | Trust depends on who populates it and when | Use only if authentication completes before rl-nginx evaluates the request, the value is canonical and bounded, and missing/invalid identity is rejected rather than mapped to a shared privileged bucket. |

Headers inserted by an upstream proxy are still untrusted unless the network
path is restricted and the proxy removes any client-provided copy. An nginx
`map` can bound values, but it cannot turn a client-selected plan or user ID
into authenticated identity.

The v0.5.0 C-client interface hashes the exact rendered bytes and byte length,
so an embedded NUL in `$binary_remote_addr` or another binary value is not
truncated. Binary identity is still easy to compose ambiguously with textual
delimiters; prefer `$remote_addr` for readable policies, or place a bounded
binary component in a structurally unambiguous position.

## Construct canonical, bounded bucket keys

The rendered bucket string, effective window, and effective rate are hashed
locally to a 128-bit resource ID. Hashing does not correct an ambiguous or
attacker-controlled input. Two definitions produce the same bucket only when
all three inputs match; raw user input can still create a practically unlimited
set of distinct buckets.

The module passes the complete rendered value as one opaque byte string; it
does not escape fields inside that value. Template authors therefore own both
cardinality and structural uniqueness. A template-schema, rate, or window
change produces a new resource ID and starts new bucket state, so version and
roll out such a change as an identity migration.

The exact, cross-client identity contract is defined by the C client's
[Content-defined IDs](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#content-defined-ids).
`rl-nginx` owns only the rendered name and effective nginx rate/window values
passed to those helpers.

Avoid patterns such as:

```nginx
# Unsafe: the user can choose the identity and create unlimited buckets.
ratelimitly_zone bad_user "bucket=user:$arg_user" rate=100r/s;

# Unsafe: URI cardinality is unbounded and ':' can occur inside values.
ratelimitly_zone bad_path
  "bucket=host:$host:method:$request_method:path:$uri"
  rate=100r/s;
```

Prefer these rules:

1. Give every policy a version and fixed scope, such as `v1|scope=api`.
2. Map client-selected route and method values to a finite operator-controlled
   vocabulary.
3. Restrict every identity component to a canonical alphabet and maximum
   length before rl-nginx sees it.
4. Use a delimiter that cannot occur in fixed or finite-map components. If one
   other bounded textual value can contain it, place that value last.
5. Reject missing or invalid authenticated identity. Do not silently put it in
   a shared bucket that might grant broader access.
6. Do not include credentials, session tokens, email addresses, or other
   sensitive data. A hash is not a substitute for secret handling.

For example:

```nginx
map $uri $rl_route_class {
  default                    other;
  ~^/api/orders(?:/|$)       orders;
  ~^/api/search(?:/|$)       search;
}

map $request_method $rl_method_class {
  default other;
  GET     read;
  POST    write;
}

ratelimitly_zone api_per_ip
  "bucket=v1|scope=api|route=$rl_route_class|method=$rl_method_class|ip=$remote_addr"
  rate=100r/s;
```

The map outputs have a fixed alphabet and cardinality. `$remote_addr` is last,
so IPv6 colons cannot be confused with another field boundary, and none of the
components can contain `|`.

## Tenant, credential, and DNS trust

```nginx
ratelimitly_tenant <tenant-domain>;
ratelimitly_auth_key <rl-cookie...|rl-aes...>;
```

`ratelimitly_tenant` is the static DNS name used to discover:

```text
_ratelimitly._udp.<tenant-domain>
```

The module has no direct server-address directive. nginx's `resolver` supplies
the SRV and address answers. Declare it directly in the `http` context: the
module captures one resolver and `resolver_timeout` for its worker-local client,
and deliberately ignores server/location overrides for RateLimitly discovery.
A configuration that enables RateLimitly without an HTTP-scope resolver fails
`nginx -t`. Configure a resolver that is trusted and reachable from nginx
workers. A compromised or unreliable resolver can
redirect decision traffic or turn enforcement into an outage. Set an explicit
`resolver_timeout`, restrict resolver and UDP egress according to the
deployment network policy, and monitor DNS failure/recovery as described in
[Operations](operations.md).

`ratelimitly_auth_key` is a tenant credential. It embeds the auth mode and key
ID, and nginx rejects a malformed key during configuration loading. Keep the
real value out of the repository and copyable examples. A deployment secret
manager can render an include file readable only by the nginx master identity,
for example:

```nginx
# Main nginx configuration:
include /etc/nginx/ratelimitly/tenant.conf;
```

Protect the included file according to the nginx master process and deployment
model, rotate an exposed key through the RateLimitly control plane, and redact
it from support bundles. `nginx -T` prints included configuration; never share
its unredacted output.

The encoded fields, client-side checks, and server-enforced quota boundaries
are documented in the C client's
[Credentials](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#credentials)
section. DNS target naming and refresh behavior are client-owned; see
[DNS Refresh](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#dns-refresh).

## Request and failure policy

```nginx
ratelimitly_policy standard unit=20ms;
ratelimitly_fail open;
ratelimitly_fail close;
```

To select the one-transmission alternative, replace the policy line with:

```nginx
ratelimitly_policy single_round unit=20ms;
```

`ratelimitly_policy` controls how the C client transmits a logical resource
request and selects a response. `unit` is its base scheduling unit `U`, not a
total timeout. It must resolve to `1..4294967295ms`; zero is rejected. nginx
duration units `w`, `d`, `h`, `m`, `s`, and `ms` are accepted, and a unitless
value means seconds. Write `unit=1ms` when one millisecond is intended.

`standard` is the default. It has one initial transmission round, one replay
round, and one final receive-only unit, so its maximum admission interval and
wire deduplication TTL are `3 * U`. With the default `unit=20ms`, that horizon
is 60ms. `single_round` performs no replay or completion delivery and has a
one-unit horizon. Either policy can complete earlier when its
response-selection rule is satisfied.

The names describe mechanics, not reliability guarantees. More transmissions
can improve delivery opportunities and server convergence, but they also add
traffic and—if server deduplication is degraded—conditional duplicate-
consumption exposure.

Advanced deployments can define every C-client policy field explicitly:

```nginx
ratelimitly_policy custom
  unit=20ms
  replays=1
  replay_gap=fixed:1
  oldest_preference=fixed:1
  final_wait_units=1
  final_oldest_preference_units=0
  completion_delivery=on;
```

`replays` retransmit the same logical request identity within the derived
deduplication window; they are not new requests. Schedule and final-wait values
are multiples of `unit`. The accepted schedules are:

```text
fixed:<units>
linear:<initial-units>:<step-units>:<maximum-units>
exponential:<initial-units>:<factor>:<maximum-units>
```

For replay rounds `0..N`, the horizon is
`U * (sum(replay_gap(k)) + final_wait_units)`. nginx validates the complete
policy and rejects an enabled configuration when that horizon exceeds the API
key's `dedup_ttl_ms_max`. See the normative
[Configuration DSL](../spec/dsl.md#ratelimitly_policy) for every constraint and
the authoritative C-client
[Resource-Request HA Policy](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#resource-request-ha-policy)
for response selection, replay, final-phase, completion-delivery, and
deduplication semantics.

The default is `ratelimitly_fail open`, but production configurations should
set the policy explicitly:

- `open` continues normal nginx processing when DNS, UDP, timeout, protocol, or
  rendered-value errors prevent a valid decision. It preserves availability
  but can bypass rate-limit enforcement during an outage.
- `close` returns `429 Too Many Requests` for those errors. It preserves the
  enforcement boundary but can deny legitimate traffic when RateLimitly or its
  dependencies are unavailable.

Choose per deployment risk, capacity, and rollback plan. Do not use fail-open
on a critical location merely as a substitute for monitoring. Do not use
fail-close without validating that the application can tolerate an enforcement
dependency outage. Keep health and recovery endpoints deliberately outside the
protected location when they must remain available.

Internal nginx failures such as request-pool allocation or event-registration
failure can still return `500`; the failure policy does not replace every nginx
error path. See [Operations](operations.md) for the executable behavior matrix.

Dynamic rates and thresholds make this decision especially important: if raw
client input can render an invalid value, an attacker may deliberately trigger
either bypass under fail-open or denial under fail-close. Use finite maps whose
outputs are all valid.

## Zones and rates

```nginx
ratelimitly_zone <name> "bucket=<template>" rate=<rate>;
```

A zone defines one RateLimitly resource. `bucket` and `rate` are rendered per
request using nginx complex values.

Rendered buckets must contain `1..1024` bytes. Static oversized values fail
`nginx -t`; empty or oversized dynamic values follow `ratelimitly_fail` without
reaching the C client. If quoting is needed, quote the whole named argument as
`"bucket=value"`. Do not write `bucket="value"`: nginx makes those inner quotes
literal bucket bytes, and the module rejects that form.

Use a finite map for a dynamic rate:

```nginx
map "$rl_route_class:$rl_method_class" $rl_api_rate {
  default       10r/s;
  orders:read   100r/s;
  orders:write  20r/s;
  search:read   30r/s;
}

ratelimitly_zone api_per_ip
  "bucket=v1|scope=api|route=$rl_route_class|method=$rl_method_class|ip=$remote_addr"
  rate=$rl_api_rate;
```

Every mapped rate must be valid. Never let a request argument, cookie, or
header select a privileged service plan unless an authenticated authorization
layer has already converted it to a bounded server-controlled value.

Rendered rates contain no spaces. Valid examples are `10r/s`, `600r/m`,
`100r/2s`, and `500r/1h`.

Both rate and period milliseconds are unsigned 32-bit wire fields. Rate must be
`1..4294967295`. Period conversion must not exceed `4294967295ms`; the largest
accepted whole-unit periods are `4294967s`, `71582m`, and `1193h`. Decimal
overflow and the first larger value in each unit are rejected. A static invalid
value makes `nginx -t` fail. An invalid dynamically rendered value follows the
configured failure policy.

## Groups

```nginx
ratelimitly_group api_all zone=per_ip zone=per_account;
```

A group expands to multiple zones. Use it when one request must satisfy every
listed resource limit:

```nginx
location /api/ {
  ratelimitly group=api_all;
  proxy_pass http://127.0.0.1:9000;
}
```

## Latency guards

```nginx
ratelimitly_guard api_latency
  "service=v1|service=public-api"
  threshold=100ms
  ttl=30s
  max_samples=128
  buffer_size=32
  min_sample_threshold=8;
```

A guard names a latency tracker, supplies its state-defining settings, and asks
RateLimitly to reject the combined request when observed latency crosses the
configured threshold. Prefer a fixed service name per protected application or
a finite route-to-service map. Do not use raw `$host`, `$uri`, request
arguments, headers, cookies, or user IDs; doing so creates attacker-controlled
service cardinality and fragments latency history.

The module reports a post-response latency sample only after RateLimitly has
returned a valid allow and the admitted request reaches nginx log phase without
a client abort. It does not report valid denials, request-start failures,
missing or invalid verdicts, dependency fail-open/fail-close outcomes,
timeouts, cardinality mismatches, or aborted clients. A fail-open request may
reach content, but it did so without a RateLimitly admission and therefore must
not affect guard history.

Attach a guard to a protected location:

```nginx
location /api/ {
  ratelimitly zone=api_per_ip guard=api_latency;
  proxy_pass http://127.0.0.1:9000;
}
```

Guard threshold and TTL milliseconds and the three sample-count fields must fit
an unsigned 32-bit wire field. Threshold and TTL must be positive, and a
unitless duration means seconds. `max_samples` must be nonzero. When
`buffer_size` is omitted, nginx uses the configured API key's
`latency_buffer_size_max` quota. An explicit `buffer_size` must be nonzero and
must not exceed that credential quota. Rendered service keys must contain
`1..1024` bytes; static oversized values fail `nginx -t`, while empty or
oversized dynamic values follow the failure policy. Quote the complete
`"service=value"` argument when needed, never only the value.
The tuning fields are static and validated while loading configuration.

A static invalid `threshold` makes `nginx -t` fail. A dynamic threshold is
validated per request and follows the failure policy when invalid. Use a finite
map for dynamic thresholds; never render them directly from client input.

`min_sample_threshold=0` disables only the insertion-rate sufficiency gate. A
retained, non-expired sample is still required before minimum latency is
available. A positive value requires the estimated insertion rate to reach
that threshold. The default is `8`.

Tracker fields and the independence of reports from resource requests are
defined in the C client's
[Latency Guards and Independent Reports](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.0/docs/api.md#latency-guards-and-independent-reports).
This module adds the HTTP-specific eligibility rule and the measurement from
request start to nginx log phase described above.

## Labels and data exposure

```nginx
ratelimitly_label "route=$rl_route_class|method=$rl_method_class";
```

Labels are transmitted for observability rather than hashed into a resource
ID. A rendered label may contain at most 256 bytes; static oversized values
fail `nginx -t`, dynamic oversized values follow the failure policy, and an
empty label is omitted. Keep values low-cardinality and non-sensitive. Do not include raw
paths, query arguments, headers, cookies, API keys, session tokens, user IDs,
email addresses, or source IPs. Finite map outputs and fixed policy names are
appropriate label values.

## Local bind and debug logging

```nginx
ratelimitly_bind 192.0.2.10;
ratelimitly_debug on;
```

`ratelimitly_bind` selects the local source IP for the module's UDP socket. It
does not configure a RateLimitly server address; servers are discovered through
DNS SRV records. Normally omit it and let the kernel choose. If policy routing
or a multi-homed host requires it, use an address owned by the host and include
that path in network and reload testing. Invalid address syntax fails
`nginx -t`; a syntactically valid address unavailable to a worker follows the
configured failure policy and bounded initialization-retry backoff.

Debug mode writes `rn:` events including DNS targets, decision status, and
hashed identifiers to the nginx error log. It does not make the error log safe
for unrestricted access. Enable it only for a bounded diagnostic window,
protect and rotate the logs, and plan for volume on hot paths.

## Directive scope

Tenant, credential, request-policy, failure, bind, debug, zone, group, and guard
definitions belong at `http` scope. Protected `server` or `location` blocks
reference zones, groups, and guards with `ratelimitly` directives. A location
without a `ratelimitly zone=...` or `ratelimitly group=...` reference is not
protected.

See [the DSL reference](../spec/dsl.md) for complete syntax and
[Operations](operations.md) for rollout, monitoring, outage, and recovery
guidance.
