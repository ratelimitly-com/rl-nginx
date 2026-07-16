# Building rl-nginx

This guide covers building nginx with the RateLimitly module.

The module is built from source as either:

- a static nginx module with `--add-module`, or
- a dynamic nginx module with `--add-dynamic-module`.

## Prerequisites

Install the normal nginx build dependencies for your operating system:

- C compiler and make
- PCRE2 development package
- zlib development package
- OpenSSL development package

You also need:

- an nginx source tree for the nginx version you will run
- public HTTPS access to the locked `rl-c-client` release

The supported dependency revision is recorded once in
[`../dependencies/rl-c-client.env`](../dependencies/rl-c-client.env). Fetching it
creates this default ignored layout:

```text
rl-nginx/
  _deps/
    rl-c-client/
```

Set `RCLIENT_DIR=/path/to/rl-c-client` only when intentionally building a
different source checkout.

## Build The C Client

```sh
./tools/fetch-rl-c-client.sh
make -C ./_deps/rl-c-client
```

The fetch fails if the public tag does not resolve to the locked full commit
SHA. The build produces `librclient.a` and `librclient.so`.

## Build With The Helper

Static module:

```sh
./tools/build-nginx.sh /path/to/nginx-src --clean
```

Dynamic module:

```sh
./tools/build-nginx.sh /path/to/nginx-src --dynamic --compat --clean
```

Useful flags:

| Flag | Meaning |
| --- | --- |
| `--dynamic` | Build `ngx_http_rn_module.so` instead of a full nginx binary. |
| `--compat` | Add nginx `--with-compat`; recommended for dynamic modules. |
| `--debug` | Add nginx `--with-debug`. |
| `--clean` | Remove the nginx `objs/` build directory before configuring. |
| `--skip-rclient-build` | Do not run `make -C "$RCLIENT_DIR"` first. |

## Raw Static Build

From the nginx source tree:

```sh
./configure \
  --add-module=/path/to/rl-nginx \
  --with-cc-opt="-I/path/to/rl-c-client/include" \
  --with-ld-opt="-L/path/to/rl-c-client -lrclient -lcrypto -lssl -Wl,-rpath,/path/to/rl-c-client"

make -j
```

The resulting nginx binary includes `ngx_http_rn_module`.

## Raw Dynamic Build

From the nginx source tree:

```sh
./configure \
  --with-compat \
  --add-dynamic-module=/path/to/rl-nginx \
  --with-cc-opt="-I/path/to/rl-c-client/include" \
  --with-ld-opt="-L/path/to/rl-c-client -lrclient -lcrypto -lssl -Wl,-rpath,/path/to/rl-c-client"

make modules
```

The module is written to:

```text
objs/ngx_http_rn_module.so
```

Load it in nginx before the `events` block:

```nginx
load_module modules/ngx_http_rn_module.so;
```

## Runtime Library Loading

If you link against `librclient.so`, nginx must be able to load it at runtime.
Use one of:

- `-Wl,-rpath,/path/to/rl-c-client` at build time
- `LD_LIBRARY_PATH=/path/to/rl-c-client` when starting nginx
- system installation of `librclient.so` through your package manager or
  deployment image

The helper uses `-Wl,-rpath,...` and `start-nginx.sh` also exports
`LD_LIBRARY_PATH` for local development.

## Version Compatibility

Supported builds use the C-client tag and SHA in
[`dependencies/rl-c-client.env`](../dependencies/rl-c-client.env). A
`RCLIENT_DIR` override is useful for development, but it does not change the
supported release combination.

For static modules, build and run the resulting nginx binary together.

For dynamic modules, build against the same nginx version and compatible build
options as the nginx binary that will load the module. Use `--compat` when your
nginx distribution supports compatible dynamic modules.
