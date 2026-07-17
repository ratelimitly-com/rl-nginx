# rl-nginx docs

## Topics

- `build.md` - building nginx with the module.
- `compatibility.md` - first-release scope and supported version matrix.
- `configuration.md` - directives, identity trust, canonical buckets, secrets,
  DNS, and failure-policy guidance.
- `operations.md` - DNS, failure modes, warmup, logging, and rollout checks.
- `c-client.md` - C client integration notes.

## Notes

The root `README.md` is the public entry point. These docs carry the detail
needed once a user has decided to build or operate the module.

Copyable configurations are under `../examples/`. Start with `minimal.conf` and
use `security-conscious.conf` when a policy needs bounded route/method maps,
dynamic rates, labels, or a latency guard.
