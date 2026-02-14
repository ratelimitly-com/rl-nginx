# rate-nginx (rn)

This directory tracks the nginx plugin effort for Ratelimitly.

## Purpose

- Spec for the nginx module and config DSL.
- Design notes and decision records.
- Implementation (work-in-progress).

## Structure

- `docs/`: Narrative docs, rationale, ADRs, guides.
- `spec/`: Formal specs (DSL, protocol mapping, behavior).
- `src/`: nginx module source (C).

## Quick links

- Spec index: `spec/index.md`
- Docs index: `docs/index.md`
- Test harness: `tests/README.md`

## Build (dev)

- Requires a local C r-client checkout, preferably at `./rl-c-client`.
  - Legacy layout is still supported at `./upstream-rl/clients/c`.
- Build the C r-client: `make -C ./rl-c-client`
- Configure nginx with the module (example):
  - `./configure --add-module=.` (run from `rn/`)
  - Add include/lib flags for the C r-client as needed
    (see `./rl-c-client/README.md`).

## Minimal config example

```nginx
http {
  ratelimitly_tenant   ratelimitly.example.com;
  ratelimitly_key_id   12345;
  ratelimitly_auth     cookie <hex_cookie_32bytes>;
  ratelimitly_timeout  20ms;
  ratelimitly_fail     open;
  # Optional local bind address for UDP client socket
  ratelimitly_bind     0.0.0.0;
  # Optional debug logging
  ratelimitly_debug    on;

  ratelimitly_zone zone=api_read  bucket=\"low:$uri:$cookie\" rate=600r/m;
  ratelimitly_zone zone=api_write bucket=\"high:$uri:$cookie\" rate=120r/m;

  ratelimitly_group api_all zone=api_read zone=api_write;

  server {
    location /api/ {
      ratelimitly_label \"api:$method:$uri\";
      ratelimitly group=api_all;
    }
  }
}
```

## Test assets

- `tests/nginx.conf` — ready-to-edit test config
- `tests/build-nginx.sh` — nginx build helper with rn module + C r-client
