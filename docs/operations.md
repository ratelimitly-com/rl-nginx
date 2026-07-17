# Operating rl-nginx

This guide covers runtime expectations for operating the RateLimitly nginx
module.

## DNS Discovery

The module discovers RateLimitly servers through DNS SRV:

```text
_ratelimitly._udp.<tenant-domain>
```

The SRV target must resolve to an address nginx can reach over UDP. A typical
record looks like:

```text
10 50 8080 s-396140499959812.c-5107024729143590554.p0.ratelimitly.com.
```

The target host encodes the RateLimitly server id. The C client uses that id to
validate and route protocol responses.

Nginx requires a `resolver` directive when runtime DNS resolution is needed:

```nginx
resolver 127.0.0.53 valid=30s ipv6=off;
resolver_timeout 2s;
```

Use `ipv6=off` when your SRV targets are IPv4-only.

## Startup And Warmup

The first protected request may trigger DNS discovery and client warmup. During
that window, fail-closed configurations can return `429` before a real
RateLimitly decision has been received.

For production rollouts:

- configure an unprotected health endpoint for nginx readiness,
- send a protected warmup request before shifting traffic, or
- use deployment health checks that verify `rn: result success=...` appears in
  the nginx error log.

The integration harness follows this pattern: `/health` checks nginx, then
`/allow` warms the RateLimitly client before measured traffic starts.

## Failure Modes

`ratelimitly_fail` controls behavior when no valid RateLimitly decision is
available.

```nginx
ratelimitly_fail open;
ratelimitly_fail close;
```

Common causes:

- missing or invalid DNS SRV records
- SRV target address lookup failure
- UDP egress blocked by host or network policy
- timeout too short for the environment
- invalid API key
- incompatible client/server protocol versions

With `ratelimitly_fail open`, nginx continues processing the request.
With `ratelimitly_fail close`, nginx returns `429`.

## Observability

Enable module debug logs during integration:

```nginx
error_log /var/log/nginx/error.log debug;
ratelimitly_debug on;
```

Useful log markers:

```text
rn: SRV target=...
rn: addr=...
rn: result success=1 server_id=...
rn: result success=0 server_id=...
rn: result error status=...
rn: async_start_failed ...
```

Interpretation:

- `success=1`: RateLimitly allowed the request.
- `success=0`: RateLimitly denied the request.
- `status=-2`: timeout from `rl-c-client`.
- `status=-5` or `async_start_failed ... dns`: DNS/client discovery problem.

## Secret Handling

`ratelimitly_auth_key` is a credential. Treat it like an API key:

- inject it through templating or secret management,
- avoid committing real keys,
- rotate keys if they appear in logs, tickets, or public files.

## Rollout Checklist

Before putting traffic through the module:

1. Build against the nginx version you will run.
2. Confirm nginx can load the module or start the statically built binary.
3. Confirm `librclient.so` can be loaded when using shared linking.
4. Verify `_ratelimitly._udp.<tenant-domain>` returns usable SRV records.
5. Verify SRV targets resolve to reachable IP addresses.
6. Run a low-rate protected test route.
7. Confirm both allow and deny decisions are visible in logs.
8. Choose and document the desired `ratelimitly_fail` behavior.

## Internal Full-Stack Test

The required public integration suite is documented in the root README and
does not need a RateLimitly server. Maintainers with access to the private
`../rl` workspace can additionally start the Rust RateLimitly server, register
a temporary tenant, serve local DNS, start nginx, and check allow/deny traffic:

```sh
./integration-tests/internal-full-stack.sh
```

This internal harness is optional and intentionally does not use the obsolete
Python server.
