#!/usr/bin/env python3
"""MCP 2026-07-28 conformance probe (Agentic Standard v2, AS-4).

Raw, stateless, stdlib-only probe of every MCP server's Streamable HTTP
endpoint. Per server it checks, with no `initialize` and no session id:

  discover  POST `server/discover` (headers Content-Type: application/json,
            Accept: application/json, text/event-stream,
            MCP-Protocol-Version: 2026-07-28, Mcp-Method: server/discover;
            params._meta = protocolVersion + clientCapabilities).
            PASS only if result.supportedVersions contains "2026-07-28".
            A server on go-sdk default options only advertises 2025-11-25 and
            older and answers -32022; the fix is one line in the server's
            internal/adapters/inbound/mcp/server.go:
            mcp.StreamableHTTPOptions{Stateless: true}.
  tools     POST `tools/list` the same way. FAIL if the server demands an
            Mcp-Session-Id (or answers -32022). Per tool the authority level
            `_meta["com.warehouse/authority"]` (L1..L4) is read.
  authority with --require-authority a missing/invalid level is a FAIL;
            otherwise it is a WARN reporting declared/total.
  legacy    `initialize` with protocolVersion 2025-06-18 must still answer 200
            (clients not yet migrated keep working).

Targets: `--target name=url` (repeatable), and/or `--base <prefix>` which probes
`<prefix>/<name>` for every MCP service derived from the same source
scripts/run-mcp-acceptance.sh uses (scripts/exposure_inventory.py --kind mcps;
needs PyYAML), e.g. `--base http://localhost:8000/api/mcp` (the Kong form).

Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = usage error.
Session ids, headers and credentials in URLs are never printed.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

TARGET_VERSION = "2026-07-28"
LEGACY_VERSION = "2025-06-18"
AUTHORITY_KEY = "com.warehouse/authority"
AUTHORITY_LEVELS = ("L1", "L2", "L3", "L4")
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CAPS = "io.modelcontextprotocol/clientCapabilities"
ERR_UNSUPPORTED_VERSION = -32022
HINT = "set mcp.StreamableHTTPOptions{Stateless: true} (internal/adapters/inbound/mcp/server.go)"
MAX_PAGES = 20

PASS, FAIL, WARN, SKIP = "PASS", "FAIL", "WARN", "SKIP"
CHECKS = ("discover", "tools", "authority", "legacy")


class Unreachable(Exception):
    """The endpoint could not be reached at all (connect error / timeout)."""


class Reply:
    def __init__(self, status: int, message: dict[str, Any] | None, text: str, session: bool):
        self.status = status
        self.message = message  # decoded JSON-RPC message, or None
        self.text = text
        self.session = session  # server issued an Mcp-Session-Id (value never kept)

    @property
    def error(self) -> dict[str, Any] | None:
        err = (self.message or {}).get("error")
        return err if isinstance(err, dict) else None

    @property
    def result(self) -> dict[str, Any] | None:
        res = (self.message or {}).get("result")
        return res if isinstance(res, dict) else None


def parse_body(text: str) -> dict[str, Any] | None:
    """Decode a JSON-RPC message from plain JSON or an SSE stream (`data:` lines)."""
    text = text.strip()
    if not text:
        return None
    candidates = []
    if text[0] in "{[":
        candidates.append(text)
    events: list[str] = []
    for line in text.splitlines():
        if line.startswith("data:"):
            events.append(line[5:].strip())
    candidates.extend(events)
    for candidate in candidates:
        try:
            decoded = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(decoded, dict) and ("result" in decoded or "error" in decoded):
            return decoded
    return None


def safe_url(url: str) -> str:
    """The URL without credentials (userinfo) or query string."""
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if parts.port:
        host = f"{host}:{parts.port}"
    return urllib.parse.urlunsplit((parts.scheme, host, parts.path, "", ""))


def _post(url: str, body: dict[str, Any], headers: dict[str, str], timeout: float) -> Reply:
    request_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    request_headers.update(headers)
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=request_headers, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, raw, session = response.status, response.read(), bool(response.headers.get("Mcp-Session-Id"))
    except urllib.error.HTTPError as error:
        status, raw, session = error.code, error.read(), bool(error.headers.get("Mcp-Session-Id"))
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise Unreachable(f"{type(reason).__name__}: {reason}") from None
    text = raw.decode("utf-8", "replace")
    return Reply(status, parse_body(text), text, session)


def _stateless(url: str, method: str, params: dict[str, Any], timeout: float) -> Reply:
    params = dict(params)
    params["_meta"] = {META_VERSION: TARGET_VERSION, META_CAPS: {}}
    return _post(
        url,
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
        {"MCP-Protocol-Version": TARGET_VERSION, "Mcp-Method": method},
        timeout,
    )


def _snippet(reply: Reply) -> str:
    err = reply.error
    if err:
        return f"{err.get('code')}: {str(err.get('message', ''))[:120]}"
    return " ".join(reply.text.split())[:120] or "empty body"


def _unsupported_version(reply: Reply) -> bool:
    err = reply.error
    return bool(err) and err.get("code") == ERR_UNSUPPORTED_VERSION


def _demands_session(reply: Reply) -> bool:
    if reply.status == 200 and not reply.error:
        return False
    message = str(reply.error.get("message", "")) if reply.error else reply.text
    return "session" in message.lower()


def check_discover(url: str, timeout: float) -> dict[str, str]:
    reply = _stateless(url, "server/discover", {}, timeout)
    if _unsupported_version(reply):
        return {"status": FAIL, "detail": f"-32022 protocol version not supported; hint: {HINT}"}
    if reply.status != 200 or reply.result is None:
        return {"status": FAIL, "detail": f"HTTP {reply.status}, {_snippet(reply)}"}
    versions = reply.result.get("supportedVersions")
    if not isinstance(versions, list):
        return {"status": FAIL, "detail": "result has no supportedVersions list"}
    if TARGET_VERSION not in versions:
        return {
            "status": FAIL,
            "detail": f"-32022 protocol version not supported: supportedVersions {','.join(map(str, versions))} lacks {TARGET_VERSION}; hint: {HINT}",
        }
    return {"status": PASS, "detail": f"supportedVersions includes {TARGET_VERSION}"}


def check_tools(url: str, timeout: float) -> tuple[dict[str, str], list[dict[str, Any]] | None]:
    tools: list[dict[str, Any]] = []
    cursor = None
    for _ in range(MAX_PAGES):
        params = {"cursor": cursor} if cursor else {}
        reply = _stateless(url, "tools/list", params, timeout)
        if _unsupported_version(reply):
            return {"status": FAIL, "detail": f"-32022 protocol version not supported; hint: {HINT}"}, None
        if _demands_session(reply):
            return {
                "status": FAIL,
                "detail": f"server demands an Mcp-Session-Id (HTTP {reply.status}); hint: {HINT}",
            }, None
        if reply.status != 200 or reply.result is None:
            return {"status": FAIL, "detail": f"HTTP {reply.status}, {_snippet(reply)}"}, None
        page = reply.result.get("tools")
        if not isinstance(page, list):
            return {"status": FAIL, "detail": "result has no tools list"}, None
        tools.extend(t for t in page if isinstance(t, dict))
        cursor = reply.result.get("nextCursor")
        if not cursor:
            break
    return {"status": PASS, "detail": f"{len(tools)} tool(s) listed without a session"}, tools


def check_authority(tools: list[dict[str, Any]] | None, require: bool) -> dict[str, Any]:
    if tools is None:
        return {"status": SKIP, "detail": "tools/list failed", "declared": 0, "total": 0, "missing": []}
    missing, invalid = [], []
    for tool in tools:
        meta = tool.get("_meta")
        level = meta.get(AUTHORITY_KEY) if isinstance(meta, dict) else None
        name = str(tool.get("name", "?"))
        if level is None:
            missing.append(name)
        elif level not in AUTHORITY_LEVELS:
            invalid.append(name)
    total = len(tools)
    declared = total - len(missing) - len(invalid)
    detail = f"{declared}/{total} declared"
    if missing:
        detail += f"; missing: {', '.join(missing[:5])}{' ...' if len(missing) > 5 else ''}"
    if invalid:
        detail += f"; invalid (not L1..L4): {', '.join(invalid[:5])}{' ...' if len(invalid) > 5 else ''}"
    if declared == total:
        status = PASS
    else:
        status = FAIL if require else WARN
    return {"status": status, "detail": detail, "declared": declared, "total": total,
            "missing": missing, "invalid": invalid}


def check_legacy(url: str, timeout: float) -> dict[str, str]:
    reply = _post(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": LEGACY_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp-conformance-probe", "version": "1"},
            },
        },
        {},
        timeout,
    )
    if reply.status != 200 or reply.result is None:
        return {"status": FAIL, "detail": f"initialize {LEGACY_VERSION} answered HTTP {reply.status}, {_snippet(reply)}"}
    return {"status": PASS, "detail": f"initialize {LEGACY_VERSION} answered 200"}


def probe(name: str, url: str, timeout: float, require_authority: bool) -> dict[str, Any]:
    out: dict[str, Any] = {"name": name, "url": safe_url(url), "checks": {}}
    try:
        out["checks"]["discover"] = check_discover(url, timeout)
        tools_result, tools = check_tools(url, timeout)
        out["checks"]["tools"] = tools_result
        out["checks"]["authority"] = check_authority(tools, require_authority)
        out["checks"]["legacy"] = check_legacy(url, timeout)
    except Unreachable as error:
        for check in CHECKS:
            out["checks"].setdefault(check, {"status": SKIP, "detail": "unreachable"})
        first = next(c for c in CHECKS if out["checks"][c]["detail"] == "unreachable")
        out["checks"][first] = {"status": FAIL, "detail": f"unreachable: {error}"}
    statuses = [c["status"] for c in out["checks"].values()]
    out["status"] = FAIL if FAIL in statuses else (WARN if WARN in statuses else PASS)
    return out


def derive_targets(base: str, root: Path) -> list[tuple[str, str]]:
    """`<base>/<name>` for every MCP service of scripts/exposure_inventory.py (as run-mcp-acceptance.sh)."""
    sys.path.insert(0, str(root / "scripts"))
    try:
        import exposure_inventory  # type: ignore[import-not-found]
        names = exposure_inventory.load_inventory(root).mcps
    except ImportError as error:  # PyYAML missing
        raise SystemExit(f"cannot derive the MCP list ({error}); install PyYAML or pass --target name=url") from None
    except (OSError, ValueError) as error:
        raise SystemExit(f"cannot derive the MCP list: {error}") from None
    return [(name, f"{base.rstrip('/')}/{name}") for name in names]


def parse_target(value: str) -> tuple[str, str]:
    name, sep, url = value.partition("=")
    if not sep or not name or not url.startswith(("http://", "https://")):
        raise argparse.ArgumentTypeError(f"--target expects NAME=http(s)://URL, got {value!r}")
    return name, url


def render_table(results: list[dict[str, Any]]) -> str:
    header = ["SERVER", "DISCOVER", "TOOLS", "AUTHORITY", "LEGACY", "RESULT"]
    rows = []
    for r in results:
        c = r["checks"]
        authority = c["authority"]
        auth_cell = authority["status"]
        if authority.get("total"):
            auth_cell += f" {authority['declared']}/{authority['total']}"
        rows.append([r["name"], c["discover"]["status"], c["tools"]["status"], auth_cell,
                     c["legacy"]["status"], r["status"]])
    widths = [max(len(str(x[i])) for x in [header] + rows) for i in range(len(header))]
    lines = ["  ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(row)).rstrip()
             for row in [header] + rows]
    for r in results:
        for check in CHECKS:
            entry = r["checks"][check]
            if entry["status"] in (FAIL, WARN):
                lines.append(f"  {entry['status']} {r['name']} {check}: {entry['detail']}")
    failed = sum(1 for r in results if r["status"] == FAIL)
    lines.append(f"{len(results)} server(s), {failed} failed")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--target", action="append", default=[], type=parse_target, metavar="NAME=URL",
                        help="explicit endpoint, repeatable")
    parser.add_argument("--base", help="probe <BASE>/<name> for every MCP service derived from "
                        "scripts/exposure_inventory.py (e.g. http://localhost:8000/api/mcp)")
    parser.add_argument("--require-authority", action="store_true",
                        help="FAIL (instead of WARN) when a tool lacks a valid com.warehouse/authority")
    parser.add_argument("--timeout", type=float, default=10.0, help="per-request timeout in seconds (default 10)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    targets = list(args.target)
    if args.base:
        targets.extend(derive_targets(args.base, args.root))
    if not targets:
        parser.error("give at least one --target NAME=URL or --base URL")

    results = [probe(name, url, args.timeout, args.require_authority) for name, url in targets]
    ok = all(r["status"] != FAIL for r in results)
    if args.json:
        print(json.dumps({"version": TARGET_VERSION, "ok": ok, "servers": results}, indent=2))
    else:
        print(render_table(results))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
