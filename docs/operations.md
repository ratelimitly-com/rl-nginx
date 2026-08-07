# Operating rl-nginx

This runbook describes the behavior operators must account for when deploying,
warming, observing, recovering, and rolling back the RateLimitly nginx module.
Read [Configuring rl-nginx](configuration.md) first for identity, credential,
resolver, and failure-policy security guidance. The
[documentation ownership map](index.md#documentation-ownership) distinguishes
nginx behavior from the client behavior linked to its locked release.

## Runtime contract

- Each nginx worker creates its own UDP client lazily, on that worker's first
  protected request. Starting nginx, passing `nginx -t`, or reaching an
  unprotected health endpoint does not prove RateLimitly readiness.
- The client discovers RateLimitly servers through tenant-specific DNS SRV
  records. There is no directive for a fixed server address.
- nginx access control and pre-content routing run before RateLimitly. Requests
  rejected or finalized there do not consume RateLimitly resources.
- RateLimitly is the final pre-content admission point. A valid allow consumes
  the requested resources and advances directly to content processing. A valid
  RateLimitly deny, a failed guard, or a nonzero resource deficit returns
  `429 Too Many Requests`, regardless of the failure policy.
- DNS, transport, timeout, and invalid-response paths follow
  `ratelimitly_fail open|close`. Fail-open continues nginx processing;
  fail-close returns `429`.
- Guard latency feedback is emitted only after a valid RateLimitly allow and
  completed request processing. Denials, fail-open/fail-close dependency
  outcomes, missing verdicts, timeouts, and client aborts do not add samples.
- The default `ratelimitly_policy standard unit=20ms` uses one initial round,
  one replay round, and one final receive-only interval, for a maximum
  three-unit admission horizon. A valid response from the oldest server can
  complete earlier. `single_round` and a fully explicit `custom` policy are
  also available.
- Internal nginx failures such as request-pool allocation or event-registration
  failure can return `500`. `ratelimitly_fail` is not a blanket conversion of
  every nginx failure.

The C client's
[Resource-Request HA Policy](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#resource-request-ha-policy)
is authoritative for response selection, replay schedules, completion
delivery, and deduplication semantics.

After admission, the client can disconnect and a content handler or upstream
can still fail. Those outcomes do not reverse resource consumption. Fail-open
also advances to content, but without a valid decision or guaranteed
consumption. Because a real deny and a fail-closed dependency error both return
`429`, HTTP status alone cannot distinguish them. Use the module log markers
described below.

Guard latency reporting follows the same distinction: an admitted request can
report its completed processing latency even when the eventual HTTP response
is an application or upstream error, but a fail-open request cannot report a
sample because no valid RateLimitly allow exists. A client abort suppresses the
sample without refunding an already consumed admission.

## DNS discovery and network path

The module queries:

```text
_ratelimitly._udp.<tenant-domain>
```

Each SRV target must resolve to a reachable A or AAAA address. Its name encodes
the RateLimitly server ID used to validate and route responses. This synthetic
shape uses the reserved, non-working `example.invalid` domain:

```text
10 50 8080 s-396140499959812.tenant.example.invalid.
```

nginx must have a trusted runtime resolver declared directly in `http`:

```nginx
resolver 127.0.0.53 valid=30s ipv6=off;
resolver_timeout 2s;
```

Use the resolver address and IPv4/IPv6 policy that are actually reachable from
nginx workers. Permit DNS traffic to that resolver and UDP traffic to every
address/port returned by the SRV and address lookups. `ratelimitly_bind`, when
set, chooses only the local UDP source address; it is not a server address.
Server or location resolver overrides do not affect RateLimitly discovery.

Target naming, membership validation, and refresh pacing are client-owned. See
the version-matched C-client
[DNS contract](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/IO_ABSTRACTION.md#dns)
and
[DNS Refresh](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#dns-refresh)
instead of inferring client behavior from nginx resolver configuration alone.

The worker socket is unconnected and can receive any datagram addressed to its
ephemeral port. Protocol authentication prevents invalid datagrams from
producing a verdict, while a 64-datagram handler budget prevents one UDP event
from monopolizing the nginx event loop. This is defense in depth, not
volumetric-DDoS protection: restrict ingress to expected RateLimitly networks
where the deployment topology permits it, and use host or network controls for
flood protection.

Check discovery from the same network namespace as nginx:

```sh
TENANT_DOMAIN='replace-with-tenant-domain'
SRV_TARGET='replace-with-target-from-srv-answer'
dig SRV "_ratelimitly._udp.${TENANT_DOMAIN}"
dig A "${SRV_TARGET}"
dig AAAA "${SRV_TARGET}"
```

Do not treat a successful lookup from an administrator laptop or host namespace
as proof that a containerized worker has the same resolver or egress path.

### DNS failure and recovery

No SRV answer, an unresolvable target, and a resolver timeout all follow the
configured failure policy. During initial discovery the first requests can log
`async_start_failed ... rc=-5(dns)` while the worker has no usable cached
target.

After DNS is repaired, nginx and the C client refresh their state and the same
worker can recover without a reload. Wait through the configured positive or
negative cache/timeout interval, retry a protected probe, and require a valid
decision. The public suite proves same-worker recovery for missing SRV,
unresolvable target, and DNS timeout cases under both failure policies. A reload
is required when the nginx configuration itself is wrong, such as a missing or
misaddressed HTTP-scope `resolver`; remember that replacement workers start
cold. Failed worker-client initialization retries after 1, 2, 4, then 5 seconds
(capped); protected requests between attempts immediately follow
`ratelimitly_fail`.

## Startup, reload, and warmup

Use this sequence for a new deployment and every nginx reload:

1. Run `nginx -t` with the exact configuration, module artifact, include files,
   and runtime user intended for deployment.
2. Include the decision provenance and worker PID in the normal production
   access log. This needs neither `ratelimitly_debug` nor an nginx debug build:

   ```nginx
   log_format production
     '$remote_addr $request $status worker=$pid rl_verdict=$ratelimitly_verdict';
   access_log /var/log/nginx/access.log production;
   ```

3. Start or reload nginx and verify an unprotected endpoint. This proves only
   nginx process readiness.
4. Send a low-impact request through a protected canary location. Retry while
   DNS discovery is in progress.
5. Require the expected HTTP outcome and `rl_verdict=allow` or
   `rl_verdict=deny` on the corresponding access-log line. A dash means the
   request had no valid RateLimitly decision: a fail-open `2xx` or fail-closed
   `429` with `rl_verdict=-` is not a successful warmup.
6. Where the test tenant supports it, exercise one known-allow and one
   known-deny request. Confirm the deny is a valid RateLimitly decision rather
   than a fail-closed dependency error.
7. Repeat until every nginx worker PID has logged a valid decision. Client and
   DNS state are worker-local; one warmup request may reach only one worker.
   Use the `worker=$pid` access-log field to distinguish them.
8. Shift traffic gradually while watching dependency errors, `429` rates,
   upstream status, worker restarts, and latency.

Keep a deliberately unprotected liveness/recovery endpoint available when the
service must remain diagnosable during a RateLimitly outage. Do not expose
sensitive state through that endpoint.

## Failure-policy behavior

Set the policy explicitly at `http` scope:

```nginx
ratelimitly_fail open;
# or
ratelimitly_fail close;
```

| Event | Fail-open | Fail-close |
| --- | --- | --- |
| Valid allow | Consume resources and enter content | Consume resources and enter content |
| Valid RateLimitly/guard/resource deny | `429` | `429` |
| No usable DNS target | Enter content without a valid decision | `429` |
| UDP send or response timeout | Enter content without a valid decision | `429` |
| Invalid/authentication-failing/protocol response with no valid decision | Enter content without a valid decision | `429` |
| Invalid dynamic rate/threshold, empty or oversized bucket/service, oversized label, or C-client request-construction error | Enter content without a valid decision | `429` |
| Internal nginx allocation/event failure | May return `500` | May return `500` |

Fail-open preserves availability but bypasses this enforcement layer during a
dependency error. Confirm that the upstream can absorb the resulting traffic.
Fail-close preserves the enforcement boundary but can deny all legitimate
traffic on a protected location. Confirm that the service and incident process
can tolerate that dependency. Test the chosen behavior under a forced outage
before production rollout.

Do not increase the request-policy unit or add replays merely to hide DNS or
network failures. Measure normal and tail decision latency, leave an explicit
operational margin, and budget for the selected policy's complete derived
horizon. nginx rejects an enabled configuration whose resulting deduplication
TTL exceeds the API key's `dedup_ttl_ms_max` quota.

The locked C client requires valid SRV membership. Failed, empty, or malformed
SRV discovery produces no usable endpoint and follows `ratelimitly_fail`; it
does not fall back to the tenant name on a fixed UDP port.

For the exact distinction between synchronous submission errors, asynchronous
timeouts, discarded packet-local errors, and server-side silent rejection, see
the C-client
[Error Codes](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#error-codes).

## Observability and log handling

The module exposes log-based diagnostics, not Prometheus counters or a
module-specific health endpoint. `$ratelimitly_verdict` provides the
low-volume production signal described above. It reports valid decision
provenance only: `allow`, `deny`, or no value (`-`), and does not replace the
HTTP status or upstream timing fields in an access log.

For a bounded integration or incident window, enable both the module flag and
an nginx error-log level that records debug entries. Put `error_log` in the
main context, before `events` and `http`, so worker-client and resolver messages
written through the nginx cycle log reach the same destination:

```nginx
error_log /var/log/nginx/error.log debug;

events {
}

http {
  ratelimitly_debug on;
}
```

The nginx binary must support debug logging; verify `nginx -V` includes
`--with-debug`. A server- or location-level `error_log` can redirect
request-context messages, but it does not replace the main-context destination
used by worker-client, DNS, UDP, and scheduled-event logs. Module warnings can
still appear at higher log levels, but the detailed decision and discovery
markers below use debug-level entries.

Useful markers include:

| Marker | Meaning and action |
| --- | --- |
| `rn: client cfg ...` | Worker-local client initialization. It includes tenant, key ID, auth type, selected policy, unit, replay count, final wait, completion-delivery state, and derived horizon, but not the full credential. |
| `rn: SRV target=...` / `rn: addr=...` | Discovery produced a server target/address. This does not yet prove a valid response. |
| `rn: async_start_failed ... rc=-5(dns)` | The request could not start because the worker had no usable discovered target. Check resolver answers/cache and retry after recovery. |
| `rn: udp_send failed ...` | The local UDP send failed. Check bind address, routing, socket/resource pressure, and egress policy. |
| `rn: result error status=-2` | No valid response completed before the request deadline. A dropped, malformed, wrong-request-ID, or otherwise unusable response can also end as a timeout. |
| `rn: result success=1 server_id=...` | A valid response carried a positive success flag. Correlate it with HTTP/access logs because guard/resource checks and later nginx processing still determine the final status. |
| `rn: result success=0 server_id=...` | A valid response carried a negative success flag and is rejected with `429`. |
| `rn: response_cardinality_mismatch ...` | A validly decoded response had the wrong guard/resource count. Treat it as a protocol/compatibility error; the failure policy decides the request. |
| `rn: worker initialization failed; retrying after ...` | Worker-client setup failed and entered bounded backoff. Check bind availability and resource pressure; intervening requests follow the failure policy. |
| `rn: resolve_srv start ... timeout_ms=...` | SRV discovery started with the HTTP-scope `resolver_timeout`. |
| `rn: steering_feedback=0 (rebind pending)` | The server requested a deferred UDP source-port rebind. This is normal steering behavior, not an outage by itself. |
| `rn: UDP source socket rebound` | The replacement UDP endpoint is installed and subsequent sends use its source port. This debug marker confirms successful steering completion. |
| `rn: UDP socket rebind failed; retaining current endpoint and retrying` | A replacement source-port socket could not be prepared. The existing socket remains active; investigate local socket/connection exhaustion or bind failures if retries continue. |

Numeric C-client statuses are `-1` I/O, `-2` timeout, `-3` protocol, `-4`
authentication, `-5` DNS, `-6` configuration, and `-7` allocation failure.
The exact visible terminal status depends on where a failure occurs. For
example, a malformed datagram can be discarded and ultimately appear as `-2`
when no valid response arrives before the deadline.

Debug logging can be high-volume and includes request URIs through nginx log
context, tenant names, key IDs, resolver targets, target addresses, server IDs,
and hashed bucket/service identifiers. Restrict log access, retention, and
support-bundle collection accordingly. Disable debug mode after the diagnostic
window; the access-log verdict variable, normal error logging, and external
log-derived metrics should carry ongoing production monitoring.

## Credential handling

`ratelimitly_auth_key` is loaded into each worker and must be treated as a
production credential:

- render it from a secret manager into a root- or nginx-master-readable include
  file outside the repository;
- apply least-privilege ownership and mode to the file and its parent
  directory;
- remember that `nginx -T` prints included configuration, including the key;
- do not pass the key on a command line, paste it into tickets, or store it in
  general-purpose deployment logs;
- protect core dumps and process-memory access according to the host threat
  model;
- rotate the key in the RateLimitly control plane after suspected exposure,
  deploy the replacement, warm the new workers, and revoke the old key.

The encoded credential fields and quota enforcement points are defined in the
C-client
[Credentials](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#credentials)
section. This runbook owns the additional nginx process-memory, configuration,
reload, and support-bundle controls below.

nginx also retains the parsed directive value in configuration-cycle memory so
the master can create replacement workers and a worker can retry lazy client
initialization. Temporary worker-initialization copies are explicitly erased,
but the configuration-cycle value and the active C-client credential remain
plaintext process memory for their required lifetimes. There is no safe local
zeroization point without changing that lifecycle. Reevaluate this boundary if
nginx or the C client gains an opaque secret handle, protected allocator, or
initialization model that permits erasure without breaking reload, worker
replacement, or retry. Until then, process-memory and core-dump protection are
required controls rather than optional hardening. The rl-nginx maintainers own
this accepted boundary and its reevaluation.

The optional internal full-stack harness writes a generated tenant key to its
terminal/master log and tenant-registration log, then writes it into the nginx
configuration under `integration-tests/artifacts/`. The harness uses a private
umask and artifact-directory mode, but the directory is git-ignored rather than
a durable secret store. Use only temporary test credentials, do not upload the
directory as a CI artifact, and remove it after the investigation.

## Troubleshooting

### Configuration does not load

Run the real binary and configuration:

```sh
nginx -t -c /path/to/nginx.conf
```

Check directive scope, unresolved example placeholders, credential syntax,
module loading, include-file permissions, and resolver syntax. Static invalid
rates and thresholds are rejected at load time. A dynamically rendered invalid
value is instead handled per request under the failure policy.

### Protected traffic has no valid-decision marker

1. Confirm the request actually enters a location with a `ratelimitly` rule.
   Some content-handler configurations can finalize a request before the
   pre-content phase; the public fixtures deliberately use `try_files`, not a
   direct `return 200`, on their protected locations.
2. Confirm `ratelimitly_debug on` and an effective debug error-log level.
3. Look first for `bypass`, `async_start_failed`, `SRV target`, `addr`,
   `udp_send failed`, and `result error` markers.
4. Verify SRV and A/AAAA resolution from the worker network namespace.
5. Verify UDP routing/firewall policy and the configured local bind address.
6. Check tenant/key/server compatibility. A syntactically valid but wrong key
   may lead to discarded responses and then a timeout.

### Requests time out

`status=-2` proves only that no valid decision completed before the deadline.
Check whether the SRV target was discovered, whether a UDP send was logged,
whether the target is reachable, and whether responses have the expected
server ID, request ID, authentication, and protocol shape. Increase the policy
unit or select a different policy only after confirming the path is healthy
but legitimately slower than the configured budget. In particular, the client
documents why a wrong credential,
wrong key ID, skewed clock, or unusable authenticated response can all end as
[`RCLIENT_ERR_TIMEOUT`](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/docs/api.md#error-codes).

### Unexpected `429`

Correlate the request with module logs:

- `result success=0` indicates a valid negative decision;
- `result success=1` can still be rejected by guard/resource details;
- `result error`, `async_start_failed`, or cardinality mismatch under
  fail-close indicates a dependency/protocol failure rather than a quota deny;
- no module marker may mean another nginx module or the upstream produced the
  response.

### Dependency recovered but traffic did not

Retry after the DNS cache/timeout interval and look for a new valid result from
the same worker. Verify that DNS now returns the current target and address and
that UDP is bidirectionally reachable. Reload only when configuration or worker
state actually requires it; after reload, warm every replacement worker again.

## Rollout and rollback checklist

Before shifting production traffic:

1. Pin and verify the supported nginx and C-client revisions described in
   [Compatibility](compatibility.md).
2. Build the deployment artifact for the target nginx ABI and environment as
   described in [Building and installing rl-nginx](build.md).
3. Validate the exact configuration, credential include, trusted resolver, DNS
   records, target addresses, UDP policy, and optional local bind.
4. Choose and record the request policy, failure policy, monitoring thresholds,
   incident owner, and rollback trigger.
5. Test known allow, known deny, RateLimitly outage, and DNS failure/recovery in
   staging under that policy.
6. Canary the artifact/configuration, warm every worker, and verify valid
   decisions before increasing traffic.
7. Keep the previous module/package and configuration available. Roll back both
   as one reviewed deployment unit, run `nginx -t`, reload, and verify the
   replacement workers and unprotected health path.

During an incident, preserve a bounded redacted log window, record whether the
policy caused bypass or denial, verify worker survival, repair the dependency,
and prove a valid decision after recovery. Do not publish raw configuration,
`nginx -T` output, or internal-test artifacts.

## Public and internal validation boundary

The required static contributor gate is:

```sh
make check
```

It uses the locked public C-client test responder, strict local DNS fixture,
pinned nginx source, and this module. It needs no RateLimitly server, tenant,
credential, or private repository. It verifies lifecycle cleanup, exact
allow/deny enforcement, fail-open/fail-close outages, DNS failure and
same-worker recovery, timeouts, aborted clients, steering rebinds, guards,
malformed responses, response cardinality, reload, and clean shutdown. The
responder's `--listen` option exists only to bind that local UDP test fixture;
it is not a RateLimitly server option or a deployable server-address feature.
The target tests the exact static binary produced from its `BUILD_FLAGS` and
rejects dynamic mode.

Release validation additionally runs relocated dynamic behavior on both
supported architectures and nginx lines, and runs the sanitizer lifecycle gate
against both nginx lines on `x86_64`:

```sh
make build BUILD_FLAGS="--dynamic --compat --clean --debug"
make dynamic-relocation-test
make sanitizers
```

ASan, UBSan, and LeakSanitizer cover runtime shutdown. Only short-lived
`nginx -t` and `nginx -s` subprocesses disable leak detection because upstream
configuration pools are not destroyed on those exit paths. UBSan remains fully
enabled and recoverable until the artifact scan. That scan accepts only the
reviewed upstream-nginx `src/core/ngx_string.c:84` and
`src/core/ngx_string.c:586` diagnostics and rejects every other runtime error.

The optional full-stack gate is:

```sh
make test-internal
```

Its default local mode requires the private sibling `rl` workspace and tenant
management tooling. Its external mode can target an existing test server and
tenant. It is supplemental and is not required for public contributors or the
public release matrix,
and its credential-bearing artifacts require the handling described above.
See the [integration-test guide](../integration-tests/README.md) for exact
commands, prerequisites, environment variables, and artifact locations.
