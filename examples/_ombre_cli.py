"""Minimal MCP Streamable-HTTP client for ombre-brain — one-shot CLI.
Usage: python _ombre_cli.py list
       python _ombre_cli.py call <tool> <json-args-file(utf-8)>
"""
import json, os, sys, uuid
from pathlib import Path
import httpx

# 与 api_loop.py 共用 examples/.env 里的 MCP_URL / MCP_TOKEN(v2.7 起 /mcp 有静态 Token 鉴权)
for _raw in (Path(__file__).resolve().parent / ".env").read_text(encoding="utf-8").splitlines():
    _line = _raw.strip()
    if _line and not _line.startswith("#") and "=" in _line:
        _k, _v = _line.split("=", 1)
        os.environ.setdefault(_k.strip(), _v.strip().strip('"').strip("'"))

URL = os.environ.get("MCP_URL", "https://hazel.zeabur.app/mcp")
HEADERS_BASE = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
if os.environ.get("MCP_TOKEN", "").strip():
    HEADERS_BASE["Authorization"] = f"Bearer {os.environ['MCP_TOKEN'].strip()}"


def parse_body(resp: httpx.Response):
    ctype = resp.headers.get("content-type", "")
    if "text/event-stream" in ctype:
        for line in resp.text.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                data = line[5:].strip()
                if data and data != "[DONE]":
                    return json.loads(data)
        return None
    return resp.json() if resp.text.strip() else None


def main():
    mode = sys.argv[1]
    client = httpx.Client(timeout=60, trust_env=False)
    sid_headers = dict(HEADERS_BASE)

    def rpc(method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            body["id"] = uuid.uuid4().hex[:8]
        r = client.post(URL, headers=sid_headers, json=body)
        if "mcp-session-id" in r.headers:
            sid_headers["mcp-session-id"] = r.headers["mcp-session-id"]
        r.raise_for_status()
        return parse_body(r)

    init = rpc("initialize", {
        "protocolVersion": "2025-03-26",
        "capabilities": {},
        "clientInfo": {"name": "terminal-xiaoke", "version": "1.0"},
    })
    rpc("notifications/initialized", {}, notify=True)

    if mode == "list":
        out = rpc("tools/list", {})
        for t in out["result"]["tools"]:
            desc = (t.get("description") or "").split("\n")[0][:120]
            req = (t.get("inputSchema") or {}).get("required") or []
            props = list(((t.get("inputSchema") or {}).get("properties") or {}).keys())
            print(f"- {t['name']}  required={req} props={props}\n    {desc}")
    elif mode == "call":
        tool = sys.argv[2]
        args = json.load(open(sys.argv[3], encoding="utf-8"))
        out = rpc("tools/call", {"name": tool, "arguments": args})
        result = out.get("result") or out
        for c in result.get("content", []):
            if c.get("type") == "text":
                print(c["text"][:2000])


if __name__ == "__main__":
    main()
