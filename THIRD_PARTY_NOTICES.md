# Third-party notices

This file records third-party source and build dependencies relevant to this
repository. Each dependency's license text remains authoritative; preserve
the applicable notices when redistributing source or binaries.

## nginx

The `upstream-nginx/` submodule contains nginx source at the immutable revision
documented in [`docs/compatibility.md`](docs/compatibility.md). nginx is
copyrighted by Igor Sysoev and Nginx, Inc. and is available under the
two-clause BSD-style license in
[`upstream-nginx/LICENSE`](upstream-nginx/LICENSE). The submodule's source and
license notice must remain intact in redistributions that include it.

Upstream source: <https://github.com/nginx/nginx>.

## rl-c-client

Builds fetch the public `rl-c-client` `v0.5.1` release at the full commit in
[`dependencies/rl-c-client.env`](dependencies/rl-c-client.env). The checkout
is materialized under `_deps/rl-c-client` and is intentionally ignored rather
than committed to this repository. It is licensed under the MIT License; the
fetched checkout contains the authoritative license file, also available at the
[`v0.5.0 LICENSE`](https://github.com/ratelimitly-com/rl-c-client/blob/v0.5.1/LICENSE).

Upstream source: <https://github.com/ratelimitly-com/rl-c-client>.

## System build dependencies

The build links against system-provided OpenSSL/libcrypto, PCRE2, and zlib
development libraries. This repository does not redistribute those libraries;
the operating system or package distributor remains responsible for the
corresponding notices and license terms. Operators should preserve the
notices required by their distribution when shipping a resulting nginx binary.

No other third-party source package is intentionally bundled by the tracked
files in this repository.
