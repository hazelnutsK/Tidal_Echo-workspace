#!/usr/bin/env python3
"""Tidal Echo desktop body over `claude -p` stream-json ("pbody").

The classic desktop body is an interactive CC launched with
--dangerously-load-development-channels and fed by channel/server.ts, and it
can only reach her through the mcp__companion__reply tool. This bridge owns one
resident `claude -p --input-format stream-json` process instead:

    phone -> relay /channel/in (SSE) -> this bridge -> CC stdin (stream-json)
    CC text blocks -> this bridge -> relay /channel/out (type=reply)
    CC react/call  -> mcp__companion__react / call (plugin kept, reply denied)

Every text block CC writes becomes one message on her phone, so there is no
"forgot to call reply" failure mode. A block that is just [[silent]] is not
sent (keepalive wake-ups etc.); [[image:path-or-url]] attaches a photo. The
rules for the model live in PBODY_CONTRACT below and are appended to the
system prompt (or, if backend/pbody-system.md exists, that file + the contract
replace it), so CLAUDE.md does not need to know which body it is in.

Inbound is formatted exactly like the channel notification CC renders:
    <channel source="companion" chat_id="me" message_id=".." user=".." ts="..">
and the cursor file is the plugin's own last_in_id, acknowledged only when CC
echoes the message back (--replay-user-messages). Unacknowledged messages are
re-sent after a respawn.

Modes
  --sandbox  Terminal REPL. Replies, uploads and the plugin's react/call all go
             to a stub relay inside this process; nothing reaches her phone,
             nothing is persisted, ombre writes are denied.
  --live     The real desktop body. Normally started by the relay (_spawn_cc
             with desktop_body=pbody) or start-all.ps1. Refuses to start while
             another desktop body is running unless --force.

Plan and remaining gaps: docs/pbody-plan.md
"""

from __future__ import annotations

import argparse
import collections
import json
import mimetypes
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def load_dotenv(path: Path) -> None:
    try:
        for raw in path.read_text(encoding="utf-8-sig").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass


HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HOME = Path.home()
CHANNEL_DIR = HOME / ".claude" / "channels" / "companion"
load_dotenv(HERE / ".env")
load_dotenv(CHANNEL_DIR / ".env")

RELAY_URL = os.environ.get("RELAY_URL", "http://127.0.0.1:3011/relay").rstrip("/")
RELAY_SECRET = os.environ.get("RELAY_SECRET", "")
AI_NAME = os.environ.get("RELAY_AI_NAME", "小克")
HUMAN_NAME = os.environ.get("RELAY_HUMAN_NAME", "小雪")
SOURCE = os.environ.get("RELAY_CHANNEL_NAME", "companion")
CHAT_ID = "me"

CC_CWD = Path(os.environ.get("PBODY_CWD", str(HOME)))          # CLAUDE.md + memory live here
CC_SETTINGS = os.environ.get("PBODY_SETTINGS", str(REPO / "backend" / "cc-settings.json"))
CONTEXT_CTL = REPO / "backend" / "context_ctl.json"
# Optional: our own system prompt. If this file exists, CC's default system prompt
# is REPLACED by it (+ the contract) via --system-prompt-file; otherwise the
# contract is only appended. CLAUDE.md / MEMORY.md load either way (they are
# context reminders, not the system prompt). Measured 2026-10-03, sonnet, same
# flags: append 35,769 tokens vs replace 33,506. Replacing also drops Anthropic's
# tone/format rules and the file-memory writing guide -- put back what you want.
SYSTEM_PROMPT_FILE = Path(os.environ.get("PBODY_SYSTEM_PROMPT", str(REPO / "backend" / "pbody-system.md")))
# Built-in tools the chat body gets (--tools). MCP tools are not affected, but
# they are deferred, so ToolSearch must stay or ombre/react can't be loaded.
# Measured 2026-10-03 (sonnet): all built-ins ~15k tokens of schema; this set ~3k
# more than none. She chose to keep Edit and Skill (the play skill lives there).
# Empty string = CC default (everything).
PBODY_TOOLS = os.environ.get("PBODY_TOOLS", "Read,Write,Edit,Bash,WebSearch,WebFetch,ToolSearch,Skill").strip()
CURSOR_FILE = CHANNEL_DIR / "last_in_id"                        # shared with the plugin on purpose
INBOX_DIR = CHANNEL_DIR / "inbox"


def default_state_dir() -> Path:
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "TidalEcho" / "pbody"
    return HOME / ".local" / "state" / "tidal-echo" / "pbody"


STATE_DIR = Path(os.environ.get("PBODY_STATE_DIR", str(default_state_dir())))
STATE_FILE = STATE_DIR / "state.json"
TURN_LOG = STATE_DIR / "turns.jsonl"

# Where replies/uploads go. The sandbox swaps this for its stub.
OUT_BASE = RELAY_URL

PBODY_CONTRACT = f"""\
# 这个身体是 -p 管道（pbody）

- 这里没有 reply 工具：我写出来的正文就是发给{HUMAN_NAME}的消息。每一段正文（两次工具调用之间的那块文字）都会变成她手机上的一条气泡。CLAUDE.md 里所有"用 companion reply 发给她"的地方，在这里直接说出来就是。
- 所以正文里不写给自己看的旁白（"让我查一下""好的我来看看"之类），也不复述工具结果。想的东西放在 thinking 里。
- 不想对她开口的回合，比如 keepalive 醒来只是续缓存、Garden/朋友圈/读书事件看完没话说、forge-prep 写完便签，正文就只写 [[silent]]，这一轮什么都不会发出去。
- 发图：正文里写 [[image:本机路径或 http(s) 链接]]，可以写几个，最多 6 张。标记会被抹掉，图跟着这条消息一起过去。peek 那里说"把图夹在 images 里发给她"，在这里就用这个标记。
- react 和 call 还在（mcp__companion__react / mcp__companion__call），想用就用。[[voice]] [[timer]] [[ask]] [[keep]] [[peek]] 这些标记照旧写在正文里。
"""

# Sandbox: memory is shared with the real body, so a test chat must not write
# into it. Reads (breath/pulse/letter_read) stay allowed.
SANDBOX_DENY = [
    "mcp__ombre-brain__hold", "mcp__ombre-brain__grow", "mcp__ombre-brain__anchor",
    "mcp__ombre-brain__release", "mcp__ombre-brain__letter_write", "mcp__ombre-brain__trace",
    "mcp__ombre-brain__plan", "mcp__ombre-brain__dream",
]
SANDBOX_NOTE = (
    "\n【测试沙盒】这是离线测试：消息是在终端里模拟的，发出去的话会被本地假 relay 接住，"
    "不会送到她手机。照常说话就好，但别写记忆、别发朋友圈/日志、别改任何文件。\n"
)

SILENT_RE = re.compile(r"\[\[\s*silent\s*\]\]", re.I)
IMAGE_RE = re.compile(r"\[\[\s*(?:image|img)\s*:\s*([^\]]+?)\s*\]\]", re.I)
MAX_IMAGES = 6


def log(tag: str, message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] [{tag}] {message}", file=sys.stderr, flush=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def read_cursor() -> int:
    try:
        return int(CURSOR_FILE.read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        return 0


def advance_cursor(message_id: int) -> None:
    if message_id > read_cursor():
        CURSOR_FILE.write_text(str(message_id), encoding="utf-8")


# ---------------------------------------------------------------------------
# argv / env
# ---------------------------------------------------------------------------

def claude_exe() -> list[str]:
    """npm puts a .CMD shim on PATH; exec the real claude.exe behind it so args
    and stdin never pass through cmd.exe quoting."""
    override = os.environ.get("PBODY_CLAUDE", "").strip()
    found = override or shutil.which("claude") or "claude"
    if found.lower().endswith((".cmd", ".bat")):
        real = Path(found).parent / "node_modules" / "@anthropic-ai" / "claude-code" / "bin" / "claude.exe"
        if real.exists():
            return [str(real)]
        return ["cmd", "/c", found]
    return [found]


def resolve_resume(value: str) -> str:
    if value == "active":
        return str(read_json(CONTEXT_CTL).get("active_sid") or "")
    if value == "last":
        return str(read_json(STATE_FILE).get("session_id") or "")
    return value


def prompt_args(sandbox: bool) -> list[str]:
    """Contract appended to CC's system prompt, or -- when pbody-system.md exists --
    that file + the contract replacing it (re-read on every spawn)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    text = PBODY_CONTRACT + (SANDBOX_NOTE if sandbox else "")
    own = ""
    try:
        own = SYSTEM_PROMPT_FILE.read_text(encoding="utf-8-sig").strip()
    except OSError:
        pass
    path = STATE_DIR / ("contract-sandbox.md" if sandbox else "contract.md")
    if own:
        path.write_text(own + "\n\n" + text, encoding="utf-8")
        return ["--system-prompt-file", str(path)]
    path.write_text(text, encoding="utf-8")
    return ["--append-system-prompt-file", str(path)]


def build_argv(args: argparse.Namespace, resume_sid: str, extra: list[str]) -> list[str]:
    argv = claude_exe() + [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--replay-user-messages",          # the echo is our delivery receipt
        # Hidden flag (verified on 2.1.280): without it 4.7+ thinking is stored
        # as empty signature-only blocks and thinking live goes blank;
        # showThinkingSummaries in cc-settings.json is ignored under -p.
        "--thinking-display", "summarized",
        "--dangerously-skip-permissions",
        *prompt_args(args.sandbox),
    ]
    if CC_SETTINGS:
        argv += ["--settings", CC_SETTINGS]
    model = args.model or str(read_json(CONTEXT_CTL).get("desktop_model") or "").strip()
    if model:
        argv += ["--model", model]
    if args.fallback_model:
        argv += ["--fallback-model", args.fallback_model]
    if resume_sid:
        argv += ["--resume", resume_sid]
        if args.fork:
            argv += ["--fork-session"]
    elif args.session_id:
        argv += ["--session-id", args.session_id]
    elif not args.sandbox:
        argv += ["--session-id", str(uuid.uuid4())]
    if PBODY_TOOLS:
        argv += ["--tools", PBODY_TOOLS]   # one comma list; the next token is a flag, so it can't swallow more
    deny = [f"mcp__{SOURCE}__reply"] + (SANDBOX_DENY if args.sandbox else [])
    argv += ["--disallowedTools", ",".join(deny)]
    return argv + extra


def build_env(live: bool) -> dict[str, str]:
    # Same wash as app.py::_spawn_cc: inherited CLAUDECODE / CLAUDE_CODE_SESSION_ID
    # make CC think it is a nested child and stop writing its transcript.
    env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE") or k == "AI_AGENT")}
    env.pop("ANTHROPIC_API_KEY", None)        # would silently beat the subscription login
    env["CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT"] = "1"
    env["RELAY_CHANNEL_HOST"] = "0"            # the plugin must not open /channel/in; we own inbound
    env["TIDAL_PBODY"] = "1"                   # reply_guard.js stands down: text is the reply here
    if live:
        env["RELAY_ACT_FEED"] = "1"            # act_hook.py tool cards, same as the channel body
    else:
        env.pop("RELAY_ACT_FEED", None)
    return env


# ---------------------------------------------------------------------------
# relay I/O
# ---------------------------------------------------------------------------

def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {RELAY_SECRET}"}


def relay_post(path: str, body: dict[str, Any], attempts: int = 3) -> dict[str, Any]:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    delay = 1.0
    for attempt in range(attempts):
        req = urllib.request.Request(OUT_BASE + path, data=data, method="POST",
                                     headers={**auth_headers(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except (urllib.error.URLError, TimeoutError):
            if attempt + 1 >= attempts:
                raise
            time.sleep(delay)
            delay *= 2
    return {}


def upload_image(src: str) -> dict[str, Any]:
    """Local path or http(s) URL -> relay attachment (same road as server.ts uploadOutbound)."""
    if re.match(r"^https?://", src, re.I):
        with urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": "Mozilla/5.0"}),
                                    timeout=60) as resp:
            data = resp.read()
            mime = (resp.headers.get_content_type() or "").strip()
        name = urllib.parse.urlsplit(src).path.rsplit("/", 1)[-1] or "download"
    else:
        path = Path(src.strip('"'))
        data = path.read_bytes()
        name = path.name
        mime = ""
    mime = mime if mime and mime != "application/octet-stream" else (mimetypes.guess_type(name)[0] or "application/octet-stream")
    if not data:
        raise ValueError("empty file")
    req = urllib.request.Request(
        f"{OUT_BASE}/app/upload?name={urllib.parse.quote(name)}", data=data, method="POST",
        headers={**auth_headers(), "Content-Type": mime})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def act(text: str, glyph: str = "terminal") -> None:
    try:
        relay_post("/channel/out", {"type": "act", "text": text, "glyph": glyph}, attempts=1)
    except Exception as exc:
        log("act", f"failed: {exc}")


# ---------------------------------------------------------------------------
# the CC process
# ---------------------------------------------------------------------------

class CCProcess:
    def __init__(self, argv: list[str], env: dict[str, str]) -> None:
        self.proc = subprocess.Popen(
            argv, cwd=str(CC_CWD), env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.events: queue.Queue[dict[str, Any]] = queue.Queue()
        self.session_id = ""
        self._write_lock = threading.Lock()
        threading.Thread(target=self._read_stdout, name="cc-stdout", daemon=True).start()
        threading.Thread(target=self._read_stderr, name="cc-stderr", daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        # readline on the byte stream: a chunk boundary can never split a line.
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                log("cc", f"non-JSON stdout: {line[:200]}")
                continue
            if event.get("type") == "system" and event.get("subtype") == "init":
                self.session_id = str(event.get("session_id") or "")
            self.events.put(event)
        self.events.put({"type": "bridge_exit", "code": self.proc.wait()})

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for raw in self.proc.stderr:
            text = raw.decode("utf-8", "replace").rstrip()
            if text:
                log("cc-err", text[:300])

    @property
    def alive(self) -> bool:
        return self.proc.poll() is None

    def send_user(self, content: str) -> None:
        payload = {"type": "user", "message": {"role": "user", "content": content}}
        # ensure_ascii: \uXXXX escapes make stdin pure ASCII, so no codepage on
        # this machine can garble her Chinese (a raw UTF-8 echo pipe did, in the smoke test).
        data = (json.dumps(payload, ensure_ascii=True) + "\n").encode("ascii")
        with self._write_lock:
            assert self.proc.stdin is not None
            self.proc.stdin.write(data)
            self.proc.stdin.flush()

    def close(self) -> None:
        if not self.alive:
            return
        try:
            assert self.proc.stdin is not None
            self.proc.stdin.close()       # EOF = let the current turn finish, then exit
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()


# ---------------------------------------------------------------------------
# inbound formatting (mirrors channel/server.ts deliverInbound)
# ---------------------------------------------------------------------------

def attr(value: str) -> str:
    return value.replace("&", "&amp;").replace('"', "&quot;")


def channel_block(content: str, message_id: str, user: str, ts: str, image_path: str = "") -> str:
    attrs = f'source="{SOURCE}" chat_id="{CHAT_ID}" message_id="{attr(message_id)}" user="{attr(user)}" ts="{attr(ts)}"'
    if image_path:
        attrs += f' image_path="{attr(image_path)}"'
    return f"<channel {attrs}>\n{content}\n</channel>"


def download_attachment(att: dict[str, Any]) -> tuple[str, str, str] | None:
    url = str(att.get("url") or "")
    base = url.split("/")[-1].split("?")[0]
    if not base or not all(c.isalnum() or c in "_.-" for c in base):
        return None
    try:
        req = urllib.request.Request(f"{RELAY_URL}/uploads/{base}", headers=auth_headers())
        with urllib.request.urlopen(req, timeout=60) as resp:
            INBOX_DIR.mkdir(parents=True, exist_ok=True)
            dest = INBOX_DIR / base
            dest.write_bytes(resp.read())
    except Exception as exc:
        log("in", f"attachment {base} failed: {exc}")
        return None
    kind = "image" if att.get("kind") == "image" else "file"
    return kind, str(att.get("name") or base), str(dest)


def format_inbound(msg: dict[str, Any]) -> str | None:
    content = str(msg.get("content") or "")
    atts = [a for a in (msg.get("attachments") or []) if isinstance(a, dict)]
    if not content and not atts:
        return None
    image_path = ""
    if atts:
        local = [x for x in (download_attachment(a) for a in atts) if x]
        image_path = next((p for k, _, p in local if k == "image"), "")
        if local:
            lines = [f"[图片] {p}" if k == "image" else f"[文件: {n}] {p}" for k, n, p in local]
            header = f"({HUMAN_NAME}发来 {len(local)} 个附件，已存到本机，用 Read 打开看)"
            content = (content + "\n" if content else "") + header + "\n" + "\n".join(lines)
        elif not content:
            content = f"({HUMAN_NAME}发来附件，但下载失败了)"
    return channel_block(
        content,
        str(msg.get("id") or ""),
        str(msg.get("user") or "human"),
        str(msg.get("ts") or now_iso()),
        image_path,
    )


# ---------------------------------------------------------------------------
# the body
# ---------------------------------------------------------------------------

DIM, BOLD, CYAN, YELLOW, RESET = "\033[2m", "\033[1m", "\033[36m", "\033[33m", "\033[0m"

NUDGE = (
    "<reply-missing>她刚才那句你这一轮一个字都没说出口（正文是空的，也没有 [[silent]]）。"
    "在这个身体里正文就是发给她的话，现在直接说；真的不想回就只写 [[silent]]。别提这条提醒。</reply-missing>"
)


class Body:
    """Owns the CC process: spawns, respawns with --resume, consumes events,
    turns text blocks into messages."""

    def __init__(self, args: argparse.Namespace, extra_argv: list[str]) -> None:
        self.args = args
        self.extra_argv = extra_argv
        self.live = not args.sandbox
        self.turn_done = threading.Event()
        self.turn_done.set()
        self.cc: CCProcess | None = None
        self._spawn_lock = threading.Lock()
        self._restarts: list[float] = []
        # Written to stdin but not yet echoed back: (relay message id, user, block).
        # Re-sent after a respawn; the cursor only moves on the echo.
        self.pending: collections.deque[tuple[int, str, str]] = collections.deque()
        self._seen_blocks: collections.deque[str] = collections.deque(maxlen=200)
        self._alerted: dict[str, float] = {}
        self._turn = {"human": False, "spoke": False, "silent": False}
        self._nudged = False
        self.spawn(resolve_resume(args.resume) if args.resume else "")
        threading.Thread(target=self._consume, name="cc-events", daemon=True).start()

    # -- process ---------------------------------------------------------------

    def spawn(self, resume_sid: str) -> None:
        argv = build_argv(self.args, resume_sid, self.extra_argv)
        log("spawn", " ".join(a if " " not in a else f'"{a}"' for a in argv[1:]))
        self.cc = CCProcess(argv, build_env(self.live))
        for _, _, block in self.pending:
            self.cc.send_user(block)
        if self.pending:
            self.turn_done.clear()
            log("spawn", f"re-sent {len(self.pending)} unacknowledged message(s)")

    def send(self, block: str, mid: int = 0, user: str = "human") -> None:
        with self._spawn_lock:
            self.pending.append((mid, user, block))
            if not (self.cc and self.cc.alive):
                self._respawn("process gone before send")   # re-sends pending, this one included
                return
            self.turn_done.clear()
            self.cc.send_user(block)

    def _respawn(self, why: str) -> None:
        now = time.time()
        self._restarts = [t for t in self._restarts if now - t < 600] + [now]
        if len(self._restarts) > 5:
            act("-p 身体 10 分钟里挂了 5 次，桥放弃了，要人看一下", "lock")
            log("spawn", "CC died 5 times in 10 minutes; giving up")
            os._exit(3)
        sid = (self.cc.session_id if self.cc else "") or str(read_json(STATE_FILE).get("session_id") or "")
        log("spawn", f"respawning ({why}); resume={sid or '-'}")
        # A respawn must never fall back to --session-id: that sid already exists.
        self.args.session_id = ""
        self.spawn(sid if self.live else "")

    def _consume(self) -> None:
        while True:
            assert self.cc is not None
            cc = self.cc
            event = cc.events.get()
            try:
                self._handle(event)
            except Exception as exc:
                log("event", f"handler error on {event.get('type')}: {exc}")
            if event.get("type") == "bridge_exit":
                if not self.live:
                    log("cc", f"exited (code {event.get('code')})")
                    os._exit(0)
                with self._spawn_lock:
                    if self.cc is cc:
                        time.sleep(2)
                        self._respawn(f"exit code {event.get('code')}")
                if not self.pending:
                    self.turn_done.set()

    # -- events ----------------------------------------------------------------

    def _handle(self, ev: dict[str, Any]) -> None:
        kind, sub = ev.get("type"), ev.get("subtype")
        if kind == "system" and sub == "init":
            # CC re-emits init at the start of every turn; only a new session is news.
            if ev.get("session_id") == getattr(self, "_init_sid", None):
                return
            self._init_sid = ev.get("session_id")
            servers = ", ".join(f"{s.get('name')}:{s.get('status')}" for s in ev.get("mcp_servers") or [])
            log("init", f"session={ev.get('session_id')} model={ev.get('model')} mcp=[{servers}]")
            if self.live:
                state = read_json(STATE_FILE)
                state.update(session_id=ev.get("session_id"), model=ev.get("model"), started_at=now_iso())
                write_json(STATE_FILE, state)
        elif kind == "system" and sub == "api_retry":
            self._api_retry(ev)
        elif kind == "system" and sub == "compact_boundary":
            log("compact", json.dumps(ev.get("compact_metadata") or {}, ensure_ascii=False)[:200])
        elif kind == "user" and ev.get("isReplay"):
            self._acknowledge()
        elif kind == "assistant" and not ev.get("parent_tool_use_id"):   # subagents never talk to her
            message = ev.get("message") or {}
            for block in message.get("content") or []:
                btype = block.get("type")
                if btype == "thinking" and self.args.show_thinking:
                    print(f"{DIM}┌ thinking\n{block.get('thinking') or ''}\n└{RESET}", flush=True)
                elif btype == "text":
                    self._deliver_text(str(message.get("id") or ""), str(block.get("text") or ""))
                elif btype == "tool_use":
                    self._tool_use(block)
        elif kind == "result":
            self._result(ev)

    def _acknowledge(self) -> None:
        if not self.pending:
            log("in", "echo with nothing pending (ignored)")
            return
        mid, user, _ = self.pending.popleft()
        if user == "human":
            self._turn["human"] = True
        if self.live and mid:
            advance_cursor(mid)
        log("in", f"CC took #{mid or '-'} ({user})")

    def _deliver_text(self, message_id: str, text: str) -> None:
        key = f"{message_id}:{hash(text)}"
        if key in self._seen_blocks:
            return
        self._seen_blocks.append(key)
        if not text.strip():
            return
        if SILENT_RE.search(text):
            self._turn["silent"] = True
            log("out", f"silent block ({len(text)} chars kept in transcript only)")
            return
        sources = [m.group(1).strip() for m in IMAGE_RE.finditer(text)][:MAX_IMAGES]
        text = IMAGE_RE.sub("", text).strip()
        attachments, failed = [], []
        for src in sources:
            try:
                attachments.append(upload_image(src))
            except Exception as exc:   # a picture is a bonus, never a blocker
                failed.append(src)
                log("out", f"image failed {src[:80]}: {exc}")
        if not text and not attachments:
            return
        body: dict[str, Any] = {"type": "reply", "chat_id": CHAT_ID, "text": text, "ts": now_iso()}
        if attachments:
            body["attachments"] = attachments
        try:
            out = relay_post("/channel/out", body)
            self._turn["spoke"] = True
            self._nudged = False
            imgs = f" +{len(attachments)} img" if attachments else ""
            log("out", f"reply #{out.get('id')} {len(text)} chars{imgs}")
        except Exception as exc:
            log("out", f"reply NOT delivered ({exc}): {text[:80]}")
            act(f"-p 身体有一条话没送出去：{exc}", "lock")
        if failed:
            log("out", f"{len(failed)} image(s) failed")

    def _tool_use(self, block: dict[str, Any]) -> None:
        name = str(block.get("name") or "")
        inp = block.get("input") or {}
        if name.startswith(f"mcp__{SOURCE}__"):   # react / call reached her too
            self._turn["spoke"] = True
        if not self.args.show_thinking:
            return
        short = name.replace("mcp__", "").replace("__", ".")
        detail = inp.get("command") or inp.get("file_path") or inp.get("query") or inp.get("url") or ""
        if not detail and inp:
            detail = json.dumps(inp, ensure_ascii=False)
        print(f"{YELLOW}⚒ {short}{RESET} {DIM}{str(detail)[:160]}{RESET}", flush=True)

    def _api_retry(self, ev: dict[str, Any]) -> None:
        err = str(ev.get("error") or "")
        log("retry", f"attempt {ev.get('attempt')}/{ev.get('max_retries')} {err} "
                     f"status={ev.get('error_status')} wait={ev.get('retry_delay_ms')}ms")
        if not self.live:
            return
        if err in ("authentication_failed", "billing_error"):
            msg, gap = "订阅登录失效了，-p 身体说不了话，要在电脑上重新 claude login", 1800
        elif err in ("rate_limit", "overloaded"):
            msg, gap = "被限流了，正在重试，回得会慢一点", 600
        else:
            return
        if time.time() - self._alerted.get(err, 0) > gap:
            self._alerted[err] = time.time()
            act(msg, "lock")

    def _result(self, ev: dict[str, Any]) -> None:
        usage = ev.get("usage") or {}
        inp = int(usage.get("input_tokens") or 0)
        cr = int(usage.get("cache_read_input_tokens") or 0)
        cw = int(usage.get("cache_creation_input_tokens") or 0)
        out = int(usage.get("output_tokens") or 0)
        ctx = inp + cr + cw
        hit = cr / ctx if ctx else 0
        log("turn", f"{ev.get('subtype')} {ev.get('duration_ms')}ms turns={ev.get('num_turns')} "
                    f"ctx={ctx} read={cr} write={cw} out={out} hit={hit:.0%} ~${ev.get('total_cost_usd') or 0:.3f}")
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with TURN_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "at": now_iso(), "mode": "live" if self.live else "sandbox",
                "session_id": ev.get("session_id"), "subtype": ev.get("subtype"),
                "is_error": ev.get("is_error"), "duration_ms": ev.get("duration_ms"),
                "num_turns": ev.get("num_turns"), "input": inp, "cache_read": cr,
                "cache_write": cw, "output": out, "cost_usd": ev.get("total_cost_usd"),
                "spoke": self._turn["spoke"], "silent": self._turn["silent"],
            }, ensure_ascii=False) + "\n")
        # Layer-one guard (replaces reply_guard.js for this body): she said
        # something, the turn ended, nothing went out and it wasn't [[silent]].
        turn, self._turn = self._turn, {"human": False, "spoke": False, "silent": False}
        if turn["human"] and not turn["spoke"] and not turn["silent"] and not self._nudged and not self.pending:
            self._nudged = True
            log("guard", "turn ended without a word to her; nudging once")
            self.send(channel_block(NUDGE, "", "system", now_iso()), 0, "system")
            return
        if not self.pending:
            self.turn_done.set()


# ---------------------------------------------------------------------------
# live
# ---------------------------------------------------------------------------

def inbound_events(since: int):
    """SSE /channel/in with ?since= backfill, reconnect forever (same as the plugin)."""
    backoff = 1
    while True:
        url = f"{RELAY_URL}/channel/in?since={since}"
        req = urllib.request.Request(url, headers={**auth_headers(), "Accept": "text/event-stream"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                log("relay", f"inbound connected (since={since})")
                backoff = 1
                data: list[str] = []
                for raw in resp:
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line.startswith("data:"):
                        data.append(line[5:].lstrip())
                    elif line == "" and data:
                        payload, data = "\n".join(data), []
                        try:
                            msg = json.loads(payload)
                        except json.JSONDecodeError:
                            continue
                        mid = int(msg.get("id") or 0) if isinstance(msg, dict) else 0
                        if mid and mid > since:
                            since = mid
                            yield msg
            log("relay", "inbound ended; reconnecting")
        except Exception as exc:
            log("relay", f"inbound dropped ({exc}); retry in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 15)


def other_desktop_bodies() -> list[int]:
    """Interactive channel CCs, or another live bridge (not us)."""
    if os.name != "nt":
        return []
    cmd = ("Get-CimInstance Win32_Process | Where-Object { "
           "($_.Name -eq 'claude.exe' -and $_.CommandLine -like '*dangerously-load-development-channels*') -or "
           "($_.Name -like 'python*' -and $_.CommandLine -like '*pbody_bridge.py*--live*') } | "
           "Select-Object -ExpandProperty ProcessId")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                             capture_output=True, text=True, timeout=30).stdout
        mine = {os.getpid(), os.getppid()}   # the venv launcher shows up as our parent
        return [int(x) for x in out.split() if x.strip().isdigit() and int(x) not in mine]
    except Exception:
        return []


def run_live(args: argparse.Namespace) -> None:
    if not RELAY_SECRET:
        raise SystemExit("RELAY_SECRET missing (examples/.env or ~/.claude/channels/companion/.env)")
    pids = other_desktop_bodies()
    if pids and not args.force:
        raise SystemExit(
            f"another desktop body is running (pid {pids}); two bodies would both answer.\n"
            "Stop it first, or pass --force if you really mean it.")
    body = Body(args, [])
    cursor = read_cursor()
    log("live", f"relay={RELAY_URL} cursor={cursor}")
    for msg in inbound_events(cursor):
        mid = int(msg.get("id") or 0)
        block = format_inbound(msg)
        if block is None:
            advance_cursor(mid)
            continue
        try:
            body.send(block, mid, str(msg.get("user") or "human"))
            log("in", f"#{mid} {msg.get('user')} -> CC ({len(block)} chars)")
        except Exception as exc:
            # stays pending; the respawn path re-sends it
            log("in", f"#{mid} write failed ({exc})")


# ---------------------------------------------------------------------------
# sandbox
# ---------------------------------------------------------------------------

class StubRelay(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), StubHandler)
        self.next_id = 900000


class StubHandler(BaseHTTPRequestHandler):
    server: StubRelay

    def log_message(self, *_: Any) -> None:
        pass

    def _json(self, code: int, body: dict[str, Any]) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        self._json(404, {"detail": "sandbox stub"})

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path.removeprefix("/relay")
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.server.next_id += 1
        mid = self.server.next_id
        if path == "/app/upload":
            name = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("name", ["file"])[0]
            print(f"{CYAN}  ↑ upload {name} ({len(data)} bytes){RESET}", flush=True)
            self._json(200, {"url": f"/uploads/sandbox-{mid}", "name": name, "size": len(data),
                             "mime": self.headers.get("Content-Type") or "", "kind": "image"})
            return
        if path != "/channel/out":
            self._json(404, {"detail": "sandbox stub"})
            return
        try:
            body = json.loads(data.decode("utf-8"))
        except json.JSONDecodeError:
            self._json(400, {"detail": "bad json"})
            return
        t = body.get("type")
        if t == "reply":
            atts = body.get("attachments") or []
            extra = f" {DIM}[+{len(atts)} 图]{RESET}" if atts else ""
            print(f"\n{BOLD}{CYAN}{AI_NAME} ▸ {HUMAN_NAME}{RESET}{extra}\n{body.get('text') or ''}\n", flush=True)
        elif t == "react":
            print(f"{CYAN}  ♡ react #{body.get('id')} {body.get('emoji') or '(撤回)'}{RESET}", flush=True)
        elif t == "call":
            print(f"{CYAN}  ☎ call: {body.get('text')}{RESET}", flush=True)
        else:
            print(f"{DIM}  · {t}: {str(body.get('text') or '')[:120]}{RESET}", flush=True)
        self._json(200, {"ok": True, "id": mid})


def sandbox_mcp_config(stub_port: int) -> Path:
    """Explicit MCP set for --strict-mcp-config: companion pointed at the stub,
    ombre kept (writes denied separately). Written to the state dir, removed on exit."""
    project = read_json(HOME / ".mcp.json").get("mcpServers") or {}
    user_cfg = read_json(HOME / ".claude.json")
    servers: dict[str, Any] = {}
    companion = dict(project.get("companion") or {})
    if not companion:
        raise SystemExit("companion server not found in ~/.mcp.json")
    sandbox_state = STATE_DIR / "sandbox-channel"
    sandbox_state.mkdir(parents=True, exist_ok=True)
    companion["env"] = {
        **(companion.get("env") or {}),
        "RELAY_URL": f"http://127.0.0.1:{stub_port}",
        "RELAY_SECRET": "sandbox",
        "RELAY_STATE_DIR": str(sandbox_state),   # its own cursor/inbox; never the real ones
        "RELAY_CHANNEL_HOST": "0",
        "RELAY_AI_NAME": AI_NAME,
        "RELAY_HUMAN_NAME": HUMAN_NAME,
        "RELAY_CHANNEL_NAME": SOURCE,
    }
    servers["companion"] = companion
    ombre = (user_cfg.get("mcpServers") or {}).get("ombre-brain")
    if ombre:
        servers["ombre-brain"] = ombre
    path = STATE_DIR / "sandbox-mcp.json"
    write_json(path, {"mcpServers": servers})
    return path


SANDBOX_HELP = f"""\
  直接打字      = {HUMAN_NAME}发来一句（user="human"）
  /sys 文本     = 系统帧（user="system"，模拟 <desire-pulse> <keepalive> 之类）
  /img 路径 [话] = 带一张本机图片（和插件一样写成 [图片] 路径，让他自己 Read）
  /multi        = 多行输入，单独一行 . 结束
  /wait         = 不等这轮结束就继续打字（切换）
  /quit         = 退出
"""


def run_sandbox(args: argparse.Namespace) -> None:
    global OUT_BASE
    stub = StubRelay()
    threading.Thread(target=stub.serve_forever, name="stub-relay", daemon=True).start()
    OUT_BASE = f"http://127.0.0.1:{stub.server_address[1]}"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    mcp_path = sandbox_mcp_config(stub.server_address[1])
    body = Body(args, ["--no-session-persistence", "--strict-mcp-config", "--mcp-config", str(mcp_path)])
    print(f"{DIM}sandbox: stub relay on :{stub.server_address[1]}, nothing reaches the phone.{RESET}")
    print(SANDBOX_HELP)
    fake_id = 800000
    wait = True
    try:
        while True:
            if wait:
                body.turn_done.wait()
            try:
                line = input(f"{BOLD}{HUMAN_NAME} ▸ {RESET}")
            except EOFError:
                break
            if not line.strip():
                continue
            user, image = "human", ""
            if line.strip() == "/quit":
                break
            if line.strip() == "/wait":
                wait = not wait
                print(f"{DIM}wait-for-turn = {wait}{RESET}")
                continue
            if line.strip() == "/multi":
                parts = []
                while (nxt := input()) != ".":
                    parts.append(nxt)
                line = "\n".join(parts)
            elif line.startswith("/sys "):
                user, line = "system", line[5:]
            elif line.startswith("/img "):
                rest = line[5:].strip().split(" ", 1)
                image = str(Path(rest[0].strip('"')).resolve())
                said = rest[1] if len(rest) > 1 else ""
                line = (said + "\n" if said else "") + \
                    f"({HUMAN_NAME}发来 1 个附件，已存到本机，用 Read 打开看)\n[图片] {image}"
            fake_id += 1
            body.send(channel_block(line, str(fake_id), user, now_iso(), image), fake_id, user)
        body.turn_done.wait()
    except KeyboardInterrupt:
        print()
    finally:
        if body.cc:
            body.cc.close()
        mcp_path.unlink(missing_ok=True)   # it holds the ombre token
        stub.shutdown()


# ---------------------------------------------------------------------------

def main() -> None:
    if os.name == "nt":
        os.system("")  # turn on ANSI colours in conhost
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
        if not sys.stdin.isatty():
            sys.stdin.reconfigure(encoding="utf-8")  # piped test scripts; a console reads Unicode anyway
    except AttributeError:
        pass
    p = argparse.ArgumentParser(description="Tidal Echo desktop body over claude -p")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--sandbox", action="store_true", help="terminal REPL, stub relay, nothing persisted")
    mode.add_argument("--live", action="store_true", help="be the desktop body")
    p.add_argument("--model", default="", help="default: context_ctl.json desktop_model")
    p.add_argument("--fallback-model", default="", help="used only when the main model is overloaded")
    p.add_argument("--resume", default="", help="session id, or 'active' (relay's active_sid) / 'last' (this bridge's)")
    p.add_argument("--session-id", default="", help="fresh session with this id (the relay passes one on reset)")
    p.add_argument("--fork", action="store_true", help="with --resume: branch a new session id, leave the original untouched")
    p.add_argument("--show-thinking", action="store_true", help="echo thinking and tool calls to the terminal")
    p.add_argument("--force", action="store_true", help="live: start even if another desktop body is running")
    args = p.parse_args()
    if args.sandbox:
        args.show_thinking = True
        run_sandbox(args)
    else:
        run_live(args)


if __name__ == "__main__":
    main()
