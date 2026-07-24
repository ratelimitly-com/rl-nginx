# Building and installing rl-nginx

`rl-nginx` is distributed as source. The planned `0.1.x` public preview does
not provide nginx binaries, `.so` packages, container images, or an automated
system installation. You build either a complete nginx binary with the module
linked statically or a dynamic module for a specific nginx binary.

This guide separates two workflows:

- the repository helper, which reproduces the public build and test gates with
  a minimal nginx configuration; and
- a deployment build, which must reproduce the version, toolchain, and
  compatible configure options of the nginx binary you will run.

See [Compatibility and release scope](compatibility.md) before choosing an
nginx source revision.

## Supported source inputs

Supported builds use immutable inputs:

| Input | Revision |
| --- | --- |
| Default nginx submodule | `release-1.31.1` at `d44205284fa41662da803b796d6056fc1e59b1f3` |
| Supported stable nginx | `release-1.30.2` at `a92a537860c7b87d3793d9eb41c9cf3ed833b53c` |
| `rl-c-client` | `v0.2.0` at `6cafd3f5bea6ba2f8a791966a70b8ab8e56c485f` |

The authoritative C-client lock is
[`dependencies/rl-c-client.env`](../dependencies/rl-c-client.env). Without an
override, every supported entrypoint fetches or verifies that exact public tag
and commit under `./_deps/rl-c-client`. The locked checkout must also be clean;
ignored compiler outputs are allowed, but local tracked or untracked source
changes fail resolution. It never selects a sibling checkout.

`RCLIENT_DIR=/path/to/rl-c-client` is an intentional development or packaging
override. It does not change the supported release combination, and the caller
is responsible for the revision, local modifications, build flags, and
compatibility of that checkout.

## Prerequisites

The build requires:

- a C compiler, `make`, and the usual nginx build toolchain;
- PCRE2 and zlib development files;
- OpenSSL development files for `libcrypto`;
- Git and public HTTPS access for the locked C-client checkout; and
- an nginx source tree for the exact version you will run.

The public tests additionally use `curl`, `dig`, `ps`, and Python 3. The dynamic
relocation gate uses `install`, `ldd`, and `readelf`.

On Debian or Ubuntu, install the complete public-gate dependency set with:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential curl dnsutils git libpcre2-dev libssl-dev procps python3 \
  zlib1g-dev
```

Package names differ on other Linux distributions. The first public release is
limited to Linux with glibc; other operating systems and C libraries are not
currently supported.

## Clean-clone build and test

Clone with the pinned nginx source:

```sh
git clone --recurse-submodules https://github.com/ratelimitly-com/rl-nginx.git
cd rl-nginx
```

Run the required static contributor gate:

```sh
make check
```

This command verifies the dependency lock, builds the C client and nginx,
checks nginx configuration, runs the deterministic public integration suite,
checks both committed and working-tree whitespace, and runs negative fixtures
that prove the required Make, CI, specification, and lifecycle oracles turn red
when their protected behavior is removed. It needs no RateLimitly server,
tenant, API key, or private repository. It is a static-only target and rejects
`--dynamic`; its integration phase reuses the exact nginx binary produced from
the caller's `BUILD_FLAGS` instead of silently rebuilding a debug binary.

The resulting evaluation binary is:

```text
upstream-nginx/objs/nginx
```

The helper uses nginx's default configure options plus this module. Treat that
binary as a clean build/test result, not as a drop-in replacement for an nginx
binary supplied by your distribution or existing deployment.

## Repository build helper

The root Make target wraps the supported helper:

```sh
make build NGINX_SRC=/path/to/nginx-src BUILD_FLAGS="--clean"
```

The equivalent direct command is:

```sh
./tools/build-nginx.sh /path/to/nginx-src --clean
```

Both commands build the locked C client first unless an explicit override or
skip flag is supplied. Static output is `/path/to/nginx-src/objs/nginx`.

Build a dynamic evaluation module with:

```sh
make build \
  NGINX_SRC=/path/to/nginx-src \
  BUILD_FLAGS="--dynamic --compat --clean"
```

Dynamic output is `/path/to/nginx-src/objs/ngx_http_rn_module.so`. Validate the
artifact outside its build tree with:

```sh
make dynamic-relocation-test NGINX_SRC=/path/to/nginx-src
```

That gate copies the nginx binary and module into an isolated runtime, rejects
RPATH/RUNPATH and a shared `librclient.so` dependency, runs `nginx -t`, and
exercises final-admission ordering, worker resolver selection, the exact
allow/deny boundary, and guard/latency behavior without `LD_LIBRARY_PATH`.

### Helper flags

| Flag | Effect |
| --- | --- |
| `--dynamic` | Build `ngx_http_rn_module.so` instead of a statically linked nginx binary. |
| `--compat` | Pass `--with-compat` to nginx; normally required for a compatible dynamic-module build. |
| `--debug` | Pass `--with-debug` to nginx. |
| `--clean` | Remove the nginx `objs/` build directory before configuring. |
| `--sanitize` | Instrument nginx and this module with ASan and UBSan. |
| `--skip-rclient-build` | Reuse an already-built `librclient.a`; intended only for controlled packaging workflows. |

Use `make sanitizers` instead of the raw `--sanitize` flag for the release
gate. It instruments the C client as well, runs the complete lifecycle and
response-cardinality suite, and builds test-only fault hooks to exercise
resolver, partial worker-initialization, and transactional rebind failures.
ASan, UBSan, and LeakSanitizer remain enabled for standalone probes and nginx
runtime shutdown. Leak detection is disabled only for short-lived `nginx -t`
and `nginx -s` subprocesses, which exit without tearing down upstream nginx's
configuration-cycle pools; no allocator-stack suppression hides runtime
module allocations. The `nonnull-attribute` check also remains enabled. The
artifact scan accepts only the exact reviewed upstream-nginx diagnostics at
`src/core/ngx_string.c:84` and `src/core/ngx_string.c:586`; any other UBSan
diagnostic, including one in module or C-client code, fails the gate. UBSan
reports remain recoverable until that scan so known upstream diagnostics do not
prevent the lifecycle suite from running.

These targets have distinct acceptance roles:

- `make check` is the required static contributor gate and retains its tested
  binary;
- a dynamic build followed by `make dynamic-relocation-test` is a required
  release gate for each supported nginx line and architecture;
- `make sanitizers` is a required release gate for both supported nginx lines
  on `x86_64`; and
- `make test-internal` is optional supplemental validation because it requires
  private service credentials and is not reproducible by public contributors.

## Building a deployment artifact

### Static module

A static build produces a complete nginx binary. There is no separate module
file to copy into an existing nginx installation.

1. Obtain the exact nginx source used by the deployment.
2. Start from the deployment's nginx build recipe and configure options.
3. Add `--add-module=/absolute/path/to/rl-nginx`.
4. Build and deploy the resulting nginx binary and its matching configuration
   as one reviewed unit.

For example, after fetching the locked C client, add this project's
`--add-module` argument to the reviewed nginx configure command. The abbreviated
command below intentionally omits your deployment's existing options:

```sh
cd /absolute/path/to/rl-nginx
./tools/fetch-rl-c-client.sh
make -C ./_deps/rl-c-client clean
make -C ./_deps/rl-c-client librclient.a

cd /absolute/path/to/nginx-src
RCLIENT_DIR=/absolute/path/to/rl-nginx/_deps/rl-c-client \
  ./configure \
    --add-module=/absolute/path/to/rl-nginx
make -j
```

Do not replace a distribution nginx binary with the helper's minimal build.
Reproduce the distribution or deployment build recipe, then validate the new
binary with its real configuration and the public behavioral suite.

### Dynamic module

An nginx dynamic module is not a version-independent plugin. Build it for the
same nginx release, architecture, C library, and compatible compile-time
feature set as the nginx binary that will load it.

Inspect the target binary before building:

```sh
nginx -V 2>&1
```

Use the reported nginx version and the vendor's reproducible source/build
recipe. Review the reported `configure arguments`; local paths or unrelated
third-party module arguments may need their corresponding sources rather than
blind copy-and-paste. Preserve the options that affect nginx module
compatibility, add `--with-compat` when the target build supports it, and add
this module. The abbreviated command below intentionally omits the other
target-compatible options and assumes the locked `librclient.a` was built as
shown in the static example:

```sh
cd /absolute/path/to/nginx-src
RCLIENT_DIR=/absolute/path/to/rl-nginx/_deps/rl-c-client \
  ./configure \
    --with-compat \
    --add-dynamic-module=/absolute/path/to/rl-nginx
make modules
```

The artifact is `objs/ngx_http_rn_module.so`. Copy it to a module directory
owned by the deployment and reference that installed path before the `events`
block:

```nginx
load_module modules/ngx_http_rn_module.so;
```

The path is relative to the nginx prefix unless it is absolute. Module
directories and package layouts are distribution-specific; this project does
not claim that one install path works for every nginx package.

Before reload or restart:

1. Run `make dynamic-relocation-test` against the configured source tree.
2. Run the target nginx binary with `nginx -t` against the deployment config.
3. Confirm that `nginx -V` and the module build use the expected version and
   compatibility options.
4. Roll out with the failure policy and rollback procedure from
   [Operations](operations.md).

`--with-compat` reduces some build-option coupling; it does not make a module
portable across arbitrary nginx versions, vendor patches, architectures, or C
libraries.

## Runtime dependencies

The nginx module descriptor links the position-independent `librclient.a` into
the nginx binary or dynamic module. A deployment therefore does not need:

- `librclient.so`;
- `LD_LIBRARY_PATH` pointing to a C-client checkout; or
- an RPATH/RUNPATH pointing to the build workspace.

The operating system's `libcrypto` and normal nginx runtime libraries remain
runtime dependencies. Check a dynamic artifact on the deployment platform with
`ldd` and the relocation gate. The shared `librclient.so` produced by a normal
C-client `make` is a build output only and must not be copied as an rl-nginx
runtime dependency.

## GitHub source archives

GitHub-generated source archives do not bundle Git submodule contents. If you
build from such an archive, obtain a supported nginx source tree separately,
verify its full commit, and pass it through `NGINX_SRC` or the helper's first
argument. The C-client is also external, but the fetch helper can materialize
its locked public tag and commit from an extracted rl-nginx archive as long as
Git and public HTTPS access are available.

The project does not run `make install`, choose a system prefix, or produce a
binary package. Release consumers are responsible for integrating the reviewed
artifact into their nginx deployment, preserving its package ownership and
rollback model.
