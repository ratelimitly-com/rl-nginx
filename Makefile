SHELL := /bin/bash

RCLIENT_DIR ?=
NGINX_SRC ?= ./upstream-nginx
NGINX_BIN ?= $(NGINX_SRC)/objs/nginx
BUILD_FLAGS ?= --clean --debug
SANITIZER_RUNS ?= 3
KEEP_SANITIZED_BUILD ?= 0

SH_SCRIPTS := \
	tools/fetch-rl-c-client.sh \
	tools/resolve-rl-c-client.sh \
	tools/build-nginx.sh \
	tools/sanitized-lifecycle.sh \
	tests/build-nginx.sh \
	tests/test-config.sh \
	tests/test-numeric.sh \
	tests/test-dependency-bootstrap.sh \
	tests/test-srv-records.sh \
	start-nginx.sh \
	integration-tests/public.sh \
	integration-tests/dynamic-module-relocation.sh \
	integration-tests/lifecycle-regressions.sh \
	integration-tests/internal-full-stack.sh \
	tests/smoke-test.sh \
	tests/burst-test.sh

PY_SCRIPTS := \
	integration-tests/abort_http_clients.py \
	integration-tests/local_dns_server.py \
	integration-tests/test_local_dns_server.py \
	integration-tests/worker_udp_port.py

.PHONY: help check fetch syntax dependency-bootstrap-test unit build config-test public-test dynamic-relocation-test test sanitizers test-internal whitespace

help:
	@printf '%s\n' \
		'Targets:' \
		'  make check          required public-readiness gate' \
		'  make build          resolve C client and build nginx/module' \
		'  make dependency-bootstrap-test  deterministic dependency gate' \
		'  make test           unit, config, and public integration tests' \
		'  make dynamic-relocation-test  relocated dynamic-module gate' \
		'  make sanitizers     ASan/UBSan lifecycle gate' \
		'  make test-internal  optional private full-stack validation' \
		'' \
		'Variables:' \
		'  RCLIENT_DIR=<intentional override; default is locked ./_deps checkout>' \
		'  NGINX_SRC=./upstream-nginx' \
		'  NGINX_BIN=$$(NGINX_SRC)/objs/nginx' \
		'  BUILD_FLAGS="--clean --debug"' \
		'  SANITIZER_RUNS=3 KEEP_SANITIZED_BUILD=0'

check: fetch syntax unit build config-test public-test whitespace

fetch:
	@if [[ -n "$(RCLIENT_DIR)" ]]; then \
		RCLIENT_DIR="$(RCLIENT_DIR)" ./tools/resolve-rl-c-client.sh >/dev/null; \
		echo "Using explicit RCLIENT_DIR=$(RCLIENT_DIR)"; \
	else \
		./tools/fetch-rl-c-client.sh; \
	fi

syntax:
	@for script in $(SH_SCRIPTS); do \
		bash -n "$$script"; \
	done
	@python3 -c 'import ast, pathlib; paths = [pathlib.Path(path) for path in "$(PY_SCRIPTS)".split()]; [ast.parse(path.read_text(), filename=str(path)) for path in paths]'
	@sh -n config

dependency-bootstrap-test:
	./tests/test-dependency-bootstrap.sh

unit: dependency-bootstrap-test
	python3 integration-tests/test_local_dns_server.py
	./tests/test-numeric.sh
	RCLIENT_DIR="$(RCLIENT_DIR)" ./tests/test-srv-records.sh

build: fetch
	RCLIENT_DIR="$(RCLIENT_DIR)" ./tools/build-nginx.sh "$(NGINX_SRC)" $(BUILD_FLAGS)

config-test:
	RCLIENT_DIR="$(RCLIENT_DIR)" NGINX_BIN="$(NGINX_BIN)" ./tests/test-config.sh

public-test: fetch
	RCLIENT_DIR="$(RCLIENT_DIR)" NGINX_SRC="$(NGINX_SRC)" ./integration-tests/public.sh

dynamic-relocation-test: fetch
	RCLIENT_DIR="$(RCLIENT_DIR)" NGINX_SRC="$(NGINX_SRC)" ./integration-tests/dynamic-module-relocation.sh

test: unit build config-test public-test

sanitizers: fetch
	SANITIZER_RUNS="$(SANITIZER_RUNS)" KEEP_SANITIZED_BUILD="$(KEEP_SANITIZED_BUILD)" RCLIENT_DIR="$(RCLIENT_DIR)" ./tools/sanitized-lifecycle.sh

test-internal:
	./integration-tests/internal-full-stack.sh

whitespace:
	git diff --check
