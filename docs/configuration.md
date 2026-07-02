# Configuring rl-nginx

`rl-nginx` uses nginx directives to define RateLimitly tenant credentials,
resource buckets, optional latency guards, and the locations that should be
protected.

## Minimal Example

```nginx
http {
  resolver 127.0.0.53 valid=30s ipv6=off;

  ratelimitly_tenant   c-5107024729143590554.p0.ratelimitly.com;
  ratelimitly_auth_key rl-aes1...;
  ratelimitly_timeout  50ms;
  ratelimitly_fail     close;

  ratelimitly_zone api bucket="api:$binary_remote_addr:$request_method:$uri" rate=100r/s;

  server {
    listen 8080;

    location /api/ {
      ratelimitly_label "api:$request_method:$uri";
      ratelimitly zone=api;
      proxy_pass http://127.0.0.1:9000;
    }
  }
}
```

## Tenant Settings

```nginx
ratelimitly_tenant <tenant-domain>;
ratelimitly_auth_key <rl-cookie...|rl-aes...>;
```

`ratelimitly_tenant` is the DNS name used for RateLimitly discovery. The module
resolves:

```text
_ratelimitly._udp.<tenant-domain>
```

`ratelimitly_auth_key` is the tenant API key. It embeds the auth mode and tenant
key id, so the nginx config does not need a separate tenant id field.

Do not commit real API keys to public repositories.

## Request Timeout And Failure Mode

```nginx
ratelimitly_timeout 50ms;
ratelimitly_fail open;
ratelimitly_fail close;
```

`ratelimitly_timeout` controls how long a request waits for a RateLimitly
decision.

`ratelimitly_fail open` allows traffic when the module cannot obtain a valid
decision. `ratelimitly_fail close` denies traffic with `429` in that case.

For public edge traffic, fail-closed is safer when RateLimitly availability is
part of the production dependency chain. Fail-open can be useful for low-risk
traffic where availability is more important than strict enforcement.

## Debug Logging

```nginx
ratelimitly_debug on;
```

When enabled, the module writes `rn:` lines to the nginx error log, including
DNS targets, UDP receive events, and RateLimitly decisions:

```text
rn: result success=1 server_id=...
rn: result success=0 server_id=...
rn: result error status=...
```

Use nginx debug logging during integration. Avoid verbose debug logs on hot
production paths unless you have planned for the volume.

## Zones

```nginx
ratelimitly_zone <name> bucket="<template>" rate=<rate>;
```

A zone defines one RateLimitly resource block.

`bucket` is rendered per request using nginx variables and then hashed into the
wire-protocol resource id. Include enough stable identity in the bucket to match
the traffic shape you want to limit.

Examples:

```nginx
ratelimitly_zone per_ip bucket="ip:$binary_remote_addr:$uri" rate=50r/s;
ratelimitly_zone per_user bucket="user:$arg_user:$request_method:$uri" rate=600r/m;
```

`rate` can be static or rendered from an nginx variable:

```nginx
map $arg_plan $rl_plan_rate {
  default 10r/s;
  pro     100r/s;
}

ratelimitly_zone plan bucket="plan:$arg_plan:user:$arg_user" rate=$rl_plan_rate;
```

Rendered rate values must not contain spaces. Valid examples:

- `10r/s`
- `600r/m`
- `100r/2s`
- `500r/1h`

## Groups

```nginx
ratelimitly_group api_all zone=per_ip zone=per_user;
```

A group expands to multiple zones. Protect a location with a group when one
request must satisfy multiple resource limits.

```nginx
location /api/ {
  ratelimitly group=api_all;
  proxy_pass http://127.0.0.1:9000;
}
```

## Latency Guards

```nginx
ratelimitly_guard api_latency service="svc:$host:$uri" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=8;
```

A guard sends RateLimitly latency metadata for a service key and asks
RateLimitly to shed requests when observed latency crosses the configured
threshold.

Attach guards to protected locations:

```nginx
location /api/ {
  ratelimitly zone=per_user guard=api_latency;
  proxy_pass http://127.0.0.1:9000;
}
```

## Labels

```nginx
ratelimitly_label "api:$request_method:$uri:user=$arg_user";
```

Labels are optional. They are sent as metrics labels and are useful for
observability. Keep labels bounded and avoid sensitive data.

## Directive Scope

Tenant-level directives are normally configured at `http` scope.

Zones, groups, and guards are defined once and referenced from `server` or
`location` blocks. A protected location must include at least one
`ratelimitly zone=...` or `ratelimitly group=...` directive.

See [../spec/dsl.md](../spec/dsl.md) for the complete directive reference.
