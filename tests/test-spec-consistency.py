#!/usr/bin/env python3
"""Check source-backed claims in the normative specification."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src" / "ngx_http_ratelimitly_module.c"
SPEC_DIR = ROOT / "spec"
DSL = SPEC_DIR / "dsl.md"
BEHAVIOR = SPEC_DIR / "behavior.md"
IMPLEMENTATION = SPEC_DIR / "implementation.md"
INDEX = SPEC_DIR / "index.md"
ROADMAP = SPEC_DIR / "roadmap.md"
DEPENDENCY_LOCK = ROOT / "dependencies" / "rl-c-client.env"

CLIENT_DOC_URL = re.compile(
    r"https://github\.com/ratelimitly-com/rl-c-client/"
    r"(?:blob|tree|releases/tag)/([^/#)]+)"
)


DEFAULT_STATEMENTS = {
    "request_policy": "r_client_default_request_policy(&mcf->request_policy);",
    "failure": "mcf->fail_open = 1;",
    "debug": "mcf->debug = 0;",
    "ttl": "uint32_t ttl_ms = 30000;",
    "max_samples": "uint32_t max_samples = 128;",
    "min_sample_threshold": "uint32_t min_sample_threshold = 8;",
}

C_CLIENT_STATEMENTS = (
    "worker->policy = mcf->request_policy;",
    "worker->client_cfg.request_policy = &worker->policy;",
    "r_client_check_rate_limit_async_borrowed(",
    "r_client_report_latency(",
)

PHASE_STATEMENTS = (
    "cmcf->phases[NGX_HTTP_PRECONTENT_PHASE].handlers",
    "ngx_memmove(&h[1], &h[0]",
)

VERDICT_STATEMENTS = (
    'ngx_string("ratelimitly_verdict")',
    "ctx->admission_outcome == RN_ADMISSION_VALID_ALLOW",
    "ctx->admission_outcome == RN_ADMISSION_VALID_DENY",
)

LIMIT_STATEMENTS = (
    "#define RN_MAX_BUCKET_LEN 1024",
    "#define RN_MAX_SERVICE_LEN 1024",
    "#define RN_MAX_LABEL_LEN 256",
)

UDP_BATCH_STATEMENTS = (
    "#define RN_UDP_READ_BATCH_MAX 64",
    "received == RN_UDP_READ_BATCH_MAX",
    "ngx_post_event(ev, &ngx_posted_next_events);",
)

ENABLED_MERGE_STATEMENT = "ngx_conf_merge_value(conf->enabled, prev->enabled, 0);"


def strip_non_executable_c(source: str) -> str:
    """Remove comments and literal #if 0 blocks before checking C statements."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    source = re.sub(r"//[^\n]*", "", source)
    output: list[str] = []
    disabled_depth = 0
    for line in source.splitlines():
        directive = line.strip()
        if re.match(r"#\s*if\s+0(?:\s|$)", directive):
            disabled_depth += 1
            continue
        if disabled_depth:
            if re.match(r"#\s*if(?:def|ndef)?\b", directive):
                disabled_depth += 1
            elif re.match(r"#\s*endif\b", directive):
                disabled_depth -= 1
            continue
        output.append(line)
    return "\n".join(output)


def function_body(source: str, name: str) -> str:
    match = re.search(rf"\b{re.escape(name)}\s*\([^;]*?\)\s*\{{", source, re.DOTALL)
    if match is None:
        return ""
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
    return ""


def require(text: str, fragment: str, location: str, failures: list[str]) -> None:
    if fragment not in text:
        failures.append(f"{location} is missing {fragment!r}")


def client_documentation_link_failures(
    documents: dict[Path, str], expected_tag: str
) -> tuple[list[str], int]:
    failures: list[str] = []
    link_count = 0
    for path, document in documents.items():
        for match in CLIENT_DOC_URL.finditer(document):
            link_count += 1
            linked_tag = match.group(1)
            if linked_tag != expected_tag:
                failures.append(
                    f"{path.relative_to(ROOT)} links rl-c-client {linked_tag}, "
                    f"but the dependency lock selects {expected_tag}"
                )
    if link_count == 0:
        failures.append("public documentation contains no versioned rl-c-client links")
    return failures, link_count


def validate(raw_source: str) -> tuple[list[str], int]:
    failures: list[str] = []
    source = strip_non_executable_c(raw_source)
    dsl = DSL.read_text(encoding="utf-8")
    behavior = BEHAVIOR.read_text(encoding="utf-8")
    implementation = IMPLEMENTATION.read_text(encoding="utf-8")
    index = INDEX.read_text(encoding="utf-8")
    roadmap = ROADMAP.read_text(encoding="utf-8")

    source_directives = set(
        re.findall(r'ngx_string\("(ratelimitly(?:_[a-z_]+)?)"\)', source)
    )
    source_directives.discard("ratelimitly_test_fault")
    source_directives.discard("ratelimitly_verdict")
    source_directives.discard("ratelimitly_resolver")
    documented_directives = set(re.findall(r"^### `([^`]+)`$", dsl, re.MULTILINE))
    if source_directives != documented_directives:
        missing = sorted(source_directives - documented_directives)
        extra = sorted(documented_directives - source_directives)
        failures.append(
            f"Directive set mismatch. missing={missing} extra={extra}"
        )

    main_conf = function_body(
        source, "ngx_http_rn_create_main_conf"
    ).split("return mcf;", 1)[0]
    guard_parser = function_body(source, "ngx_http_rn_guard")
    for name, fragment in DEFAULT_STATEMENTS.items():
        scope = guard_parser if name in {
            "ttl", "max_samples", "buffer_size", "min_sample_threshold"
        } else main_conf
        require(scope, fragment, f"executable module default {name}", failures)

    dsl_defaults = (
        "| `ratelimitly_dns_srv` | `c-${api-key-id}.p0.ratelimitly.com` |",
        "| `ratelimitly_dns_resolver` | system DNS (`/etc/resolv.conf`) |",
        "| `ratelimitly_policy` | `standard unit=20ms` |",
        "| `ratelimitly_fail` | `open` |",
        "| `ratelimitly_bind` | kernel-selected local address, ephemeral port |",
        "| `ratelimitly_debug` | `off` |",
        "| `ratelimitly_guard ttl` | `30s` |",
        "| `ratelimitly_guard max_samples` | `128` |",
        "| `ratelimitly_guard buffer_size` | credential's `latency_buffer_size_max` |",
        "| `ratelimitly_guard min_sample_threshold` | `8` |",
    )
    for fragment in dsl_defaults:
        require(dsl, fragment, "DSL defaults table", failures)
    require(guard_parser, "ngx_flag_t buffer_size_set = 0;",
            "credential-derived buffer-size omission state", failures)
    require(source, "out_guard->buffer_size = guard->buffer_size_set",
            "credential-derived buffer-size selection", failures)
    require(source, "mcf->latency_buffer_size_max",
            "credential-derived buffer-size quota", failures)

    for fragment in LIMIT_STATEMENTS:
        require(source, fragment, "executable rendered-value limit", failures)
    for fragment in ("1..1024", "at most 256 bytes", "unitless value means seconds"):
        require(dsl, fragment, "DSL validation contract", failures)

    for function_name in (
        "ngx_http_rn_merge_srv_conf",
        "ngx_http_rn_merge_loc_conf",
    ):
        require(
            function_body(source, function_name),
            ENABLED_MERGE_STATEMENT,
            f"{function_name} disabled-default normalization",
            failures,
        )

    worker_init = function_body(source, "rn_worker_init")
    handler = function_body(source, "ngx_http_rn_handler")
    log_handler = function_body(source, "ngx_http_rn_log_handler")
    integration_scopes = (
        worker_init,
        worker_init,
        handler,
        log_handler,
    )
    for fragment, scope in zip(C_CLIENT_STATEMENTS, integration_scopes):
        require(scope, fragment, "executable module C-client integration", failures)

    require(behavior, "one replay", "behavior specification", failures)
    require(
        implementation,
        "disabled completion delivery",
        "implementation specification",
        failures,
    )
    policy_parser = function_body(source, "ngx_http_rn_set_policy")
    for fragment in (
        '"standard"',
        '"single_round"',
        '"custom"',
        "policy.replay_count = 0;",
        "policy.final_receive_units = 0;",
        "policy.completion_delivery = false;",
        "policy.replay_gap",
        "policy.final_receive_units",
        "policy.completion_delivery",
    ):
        require(policy_parser, fragment, "executable request-policy mapping", failures)
    require(
        function_body(source, "ngx_http_rn_init"),
        "mcf->dedup_ttl_ms_max",
        "credential policy-horizon validation",
        failures,
    )

    init = function_body(source, "ngx_http_rn_init")
    require(init, PHASE_STATEMENTS[0], "final admission phase registration", failures)
    if "cmcf->phases[NGX_HTTP_ACCESS_PHASE].handlers" in init:
        failures.append("RateLimitly registers as an access-phase authorization handler")
    require(init, PHASE_STATEMENTS[1], "last-running pre-content ordering", failures)
    require(behavior, "final HTTP pre-content handler", "admission contract", failures)
    require(
        behavior,
        "consumption of the requested resources",
        "consumption contract",
        failures,
    )
    verdict_getter = function_body(source, "ngx_http_rn_verdict_variable")
    for fragment in VERDICT_STATEMENTS:
        scope = source if fragment.startswith("ngx_string") else verdict_getter
        require(scope, fragment, "executable verdict variable", failures)
    require(
        behavior,
        "$ratelimitly_verdict",
        "verdict-variable contract",
        failures,
    )
    mapping = (SPEC_DIR / "mapping.md").read_text(encoding="utf-8")
    require(
        mapping,
        "r_client_derive_bucket_id",
        "wire hash contract",
        failures,
    )
    require(
        mapping,
        "98300f8a73dd010d75b92ce8d2298cc7",
        "wire bucket boundary oracle",
        failures,
    )
    udp_handler = function_body(source, "rn_udp_read_handler")
    require(
        source,
        UDP_BATCH_STATEMENTS[0],
        "executable UDP receive budget",
        failures,
    )
    for fragment in UDP_BATCH_STATEMENTS[1:]:
        require(
            udp_handler,
            fragment,
            "executable UDP receive yield",
            failures,
        )
    require(
        implementation,
        "at most 64 datagrams",
        "UDP batching contract",
        failures,
    )
    require(
        implementation,
        "next-event queue",
        "UDP event-loop yield contract",
        failures,
    )

    for filename in ("dsl.md", "behavior.md", "mapping.md", "implementation.md", "roadmap.md"):
        require(index, f"({filename})", "specification index", failures)

    for path in (DSL, BEHAVIOR, SPEC_DIR / "mapping.md", IMPLEMENTATION, INDEX):
        text = path.read_text(encoding="utf-8")
        if "(Draft)" in text or re.search(r"^# .*\bDraft\b", text, re.MULTILINE):
            failures.append(f"{path.relative_to(ROOT)} presents normative material as a draft")
        if re.search(
            r"^\s*(?:[-*]\s*)?Expose Prometheus counters\b",
            text,
            re.IGNORECASE | re.MULTILINE,
        ):
            failures.append(f"{path.relative_to(ROOT)} claims unimplemented Prometheus counters")

    for fragment in (
        "This file is non-normative.",
        "does **not** provide",
        "Prometheus counters",
        "fixed RateLimitly server address",
        "deterministic single-commit routing mode",
        "not a server/product option",
    ):
        require(roadmap, fragment, "roadmap/non-features document", failures)

    return failures, len(source_directives)


def negative_fixture_failures(source: str) -> list[str]:
    failures: list[str] = []
    statements = (
        *DEFAULT_STATEMENTS.values(),
        *C_CLIENT_STATEMENTS,
        *PHASE_STATEMENTS,
        *VERDICT_STATEMENTS,
        *LIMIT_STATEMENTS,
        *UDP_BATCH_STATEMENTS,
    )
    for statement in statements:
        mutated = source.replace(statement, f"/* disabled: {statement} */", 1)
        if mutated == source:
            failures.append(f"negative fixture could not find {statement!r}")
        elif not validate(mutated)[0]:
            failures.append(f"validator accepted disabled executable statement {statement!r}")

    dead_default = source.replace(
        DEFAULT_STATEMENTS["request_policy"],
        f"#if 0\n    {DEFAULT_STATEMENTS['request_policy']}\n#endif",
        1,
    )
    if not validate(dead_default)[0]:
        failures.append("validator accepted a default hidden in #if 0")

    for function_name in (
        "ngx_http_rn_merge_srv_conf",
        "ngx_http_rn_merge_loc_conf",
    ):
        body = function_body(source, function_name)
        mutated_body = body.replace(
            ENABLED_MERGE_STATEMENT,
            f"/* disabled: {ENABLED_MERGE_STATEMENT} */",
            1,
        )
        mutated = source.replace(body, mutated_body, 1)
        if mutated_body == body:
            failures.append(f"negative fixture could not mutate {function_name}")
        elif not validate(mutated)[0]:
            failures.append(f"validator accepted disabled merge in {function_name}")
    return failures


def main() -> int:
    source = MODULE.read_text(encoding="utf-8")
    failures, directive_count = validate(source)
    failures.extend(negative_fixture_failures(source))

    lock = DEPENDENCY_LOCK.read_text(encoding="utf-8")
    tag_match = re.search(r'^RL_C_CLIENT_TAG="([^"]+)"$', lock, re.MULTILINE)
    if tag_match is None:
        failures.append("rl-c-client dependency lock contains no tag")
        client_link_count = 0
    else:
        expected_tag = tag_match.group(1)
        doc_paths = [
            ROOT / "README.md",
            ROOT / "SECURITY.md",
            ROOT / "THIRD_PARTY_NOTICES.md",
            *list((ROOT / "docs").glob("*.md")),
            *list(SPEC_DIR.glob("*.md")),
        ]
        documents = {
            path: path.read_text(encoding="utf-8") for path in doc_paths
        }
        link_failures, client_link_count = client_documentation_link_failures(
            documents, expected_tag
        )
        failures.extend(link_failures)

        mutated_documents = dict(documents)
        for path, document in mutated_documents.items():
            marker = f"/blob/{expected_tag}/"
            if marker in document:
                mutated_documents[path] = document.replace(
                    marker, "/blob/v0.0.0/", 1
                )
                break
        else:
            failures.append("documentation-link red case found no versioned blob link")
            mutated_documents = {}
        if mutated_documents and not client_documentation_link_failures(
            mutated_documents, expected_tag
        )[0]:
            failures.append("validator accepted a stale rl-c-client documentation link")

    if failures:
        for failure in failures:
            print(f"spec consistency: FAIL: {failure}", file=sys.stderr)
        return 1
    mutation_count = (
        len(DEFAULT_STATEMENTS)
        + len(C_CLIENT_STATEMENTS)
        + len(PHASE_STATEMENTS)
        + len(LIMIT_STATEMENTS)
        + len(UDP_BATCH_STATEMENTS)
        + 4
    )
    print(
        "spec consistency: PASS "
        f"({directive_count} directives, {client_link_count} locked client links, "
        f"executable defaults, {mutation_count} red cases)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
