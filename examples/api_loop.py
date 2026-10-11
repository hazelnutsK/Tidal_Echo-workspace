#!/usr/bin/env python3
"""
api_loop.py — optional server-side OpenAI-compatible loop for Companion Channel.

Run this beside backend/app.py when you want the VPS to answer directly via an
LLM API instead of routing every message to the Claude Code channel plugin.

Relay flow:
  PWA POST /relay/app/send
    -> relay stores the human message
    -> when /relay/app/brain == "loop", relay POSTs here: /loop/ingest
    -> this loop builds persona + same-session history + current message
    -> model answer is POSTed back to relay /channel/out

All private values live in env/.env. This file contains no domain, key, or
personal identity.
"""

from __future__ import annotations

import asyncio
import base64
import datetime as dt
import io
import json
import os
import re
import sqlite3
import ssl
import time
import traceback
import uuid
from pathlib import Path
from contextlib import closing
from contextvars import ContextVar
from typing import Any

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from PIL import Image, ImageOps

from moments_tools import MOMENTS_TOOLS, MOMENTS_TOOL_NAMES, moments_call
from call_tools import CALL_TOOLS, CALL_TURN, new_call_turn, request_call
from conversation_memory import ConversationMemory, MEMORY_READ_TOOL, settings as memory_settings, data_message
from breath_profile import normalize_profile, collect_breath, render_breath

# Per-task scope: previews cannot publish, and fallback/tool retries reuse a
# successful identical post within the same model turn instead of duplicating it.
MOMENTS_TURN: ContextVar[dict | None] = ContextVar("moments_turn", default=None)
MEMORY_TURN: ContextVar[dict | None] = ContextVar("memory_turn", default=None)


def load_dotenv(path: Path) -> None:
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass


HERE = Path(__file__).resolve().parent
load_dotenv(HERE / ".env")

LOOP_PORT = int(os.environ.get("LOOP_PORT", "3020"))
LOOP_CONFIG = Path(os.environ.get("LOOP_CONFIG", str(HERE / "api_loop.config.json")))
RELAY_DB = os.environ.get("RELAY_DB", str(HERE.parent / "backend" / "relay.db"))
MEMORY = ConversationMemory(
    os.environ.get("LOOP_MEMORY_DB", str(LOOP_CONFIG.with_suffix(".memory.sqlite3"))),
    RELAY_DB,
    os.environ.get("LOOP_FORGE_DIR", str(HERE.parent / "backend" / "forge")),
)
UPLOAD_DIR = Path(os.environ.get("RELAY_UPLOAD_DIR", str(HERE.parent / "backend" / "uploads")))
IMAGE_MAX_BYTES = int(os.environ.get("IMAGE_MAX_BYTES", str(5 * 1024 * 1024)))
IMAGE_MAX_PER_MESSAGE = int(os.environ.get("IMAGE_MAX_PER_MESSAGE", "6"))
RELAY_URL = os.environ.get("RELAY_URL", "http://127.0.0.1:3011").rstrip("/")
RELAY_SECRET = os.environ.get("RELAY_SECRET", "")
PERSONA_FILE = os.environ.get("PERSONA_FILE", "")
PERSONA = os.environ.get("PERSONA", "").strip()
HISTORY_N = int(os.environ.get("HISTORY_N", "24"))
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "2000"))
TEMPERATURE = float(os.environ.get("LLM_TEMPERATURE", "0.7"))
STREAM_OUTPUT = os.environ.get("LOOP_STREAM", "1").lower() not in {"0", "false", "no"}
FALLBACK_CODES = {401, 403, 404, 408, 409, 429, 500, 502, 503, 504}
MCP_URL = os.environ.get("MCP_URL", "").strip()
MCP_TOKEN = os.environ.get("MCP_TOKEN", "").strip()
# OpenRouter 的 Anthropic 模型对大陆直连 IP 区域封锁(403 not available in your region),
# 走本地代理;中转(dzzi 等)保持直连,梯子挂了还有兜底。route 里显式 proxy 字段优先。
LLM_PROXY = os.environ.get("LLM_PROXY", "").strip()
# 思维翻译走一条和聊天上下文完全隔离的短请求。只填 MODEL 时复用主链第一条的
# BASE / KEY；也可以三项全填，交给另一家更便宜的小模型。
TRANSLATION_API_BASE = os.environ.get("TRANSLATION_API_BASE", "").strip().rstrip("/")
TRANSLATION_API_KEY = os.environ.get("TRANSLATION_API_KEY", "").strip()
TRANSLATION_MODEL = os.environ.get("TRANSLATION_MODEL", "").strip()
TRANSLATION_MAX_TOKENS = max(256, int(os.environ.get("TRANSLATION_MAX_TOKENS", "4096")))


def route_proxy(route: dict[str, str]) -> str | None:
    explicit = str(route.get("proxy") or "").strip()
    if explicit:
        return explicit
    if LLM_PROXY and "openrouter.ai" in str(route.get("url") or ""):
        return LLM_PROXY
    return None


# httpx 每构造一个 Client 都重新读一遍 certifi 的 CA 包（234KB）。这台机器上单次
# load_verify_locations 要 650ms+，而流式回复是一块文字一个 POST——于是"建客户端"
# 的开销被乘上了 token 数，一条长回复能拖成十分钟。整个进程共用一个上下文。
_SSL_CTX: ssl.SSLContext | None = None


def ssl_ctx() -> ssl.SSLContext:
    global _SSL_CTX
    if _SSL_CTX is None:
        _SSL_CTX = httpx.create_ssl_context()
    return _SSL_CTX


def new_client(**kwargs: Any) -> httpx.AsyncClient:
    """所有出站 HTTP 都从这儿建，保证复用那个昂贵的 SSL 上下文。"""
    kwargs.setdefault("verify", ssl_ctx())
    return httpx.AsyncClient(**kwargs)
MCP_TOOL_ROUNDS = int(os.environ.get("MCP_TOOL_ROUNDS", "8"))
MCP_RESULT_MAX = int(os.environ.get("MCP_RESULT_MAX", "20000"))
# Claude 原生路径（/v1/messages）：自己打 cache_control 断点做增量缓存。
# CACHE_TTL: 5m 写入溢价 1.25x / 1h 溢价 2x；THINKING_BUDGET>0 时开原生思考。
CACHE_TTL = os.environ.get("CACHE_TTL", "5m")
if CACHE_TTL not in {"5m", "1h"}:
    CACHE_TTL = "5m"
THINKING_BUDGET = int(os.environ.get("THINKING_BUDGET", "1024"))
# 思考力度（output_config.effort）：真正能调深浅的那个旋钮。2026-09-19 实测 OpenRouter
# 的 /messages 兼容层原样透传给 Anthropic（填错值对方直接 400），而 budget_tokens 在
# Fable 系列上是被它吞掉的空参数。档位存 config，手机上能点。
# ⚠️ xhigh 是 Opus 4.7 才有的档，Opus 4.6 上会 400；换档会让 prompt cache 重写一次。
EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
DEFAULT_EFFORT = os.environ.get("EFFORT", "high").strip().lower()
if DEFAULT_EFFORT not in EFFORT_LEVELS:
    DEFAULT_EFFORT = "high"
# 缓存心跳保活：CACHE_TTL=1h 时，距上次真实聊天/心跳 >= AFTER_MIN 分钟就打一针
# 续 TTL；超过 MAX_IDLE_H 小时没有真实聊天就停（别给空气续费）。
KEEPALIVE_AFTER_MIN = int(os.environ.get("KEEPALIVE_AFTER_MIN", "50"))
KEEPALIVE_MAX_IDLE_H = float(os.environ.get("KEEPALIVE_MAX_IDLE_H", "6"))
# Three bounded retries within the remaining 1h cache window (request time aside).
KEEPALIVE_RETRY_DELAYS = (30, 60, 120)
KEEPALIVE_TEXT = "__cache_keepalive__ 系统缓存保活请求：不要调用任何工具，不要分析上下文，只输出 OK。"
KEEPALIVE_PROACTIVE = os.environ.get("KEEPALIVE_PROACTIVE", "0").lower() in {"1", "true", "yes"}

if not PERSONA and PERSONA_FILE:
    try:
        PERSONA = Path(PERSONA_FILE).read_text(encoding="utf-8").strip()
    except OSError:
        PERSONA = ""
if not PERSONA:
    PERSONA = (
        "You are the user's private AI companion in a one-to-one chat. "
        "Reply naturally, warmly, and concisely unless the user asks for detail."
    )


class McpClient:
    """Minimal MCP Streamable-HTTP client: initialize / tools/list / tools/call.

    Speaks JSON-RPC over POST; handles both application/json and SSE-wrapped
    responses, and re-initializes when the server session expires.
    """

    def __init__(self, url: str, token: str = "") -> None:
        self.url = url
        self.token = token
        self.session_id = ""
        self.tools: list[dict[str, Any]] = []
        self._id = 0
        self._lock = asyncio.Lock()

    def _headers(self) -> dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        return headers

    async def _rpc(self, method: str, params: dict[str, Any] | None = None, *, notify: bool = False) -> dict[str, Any]:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notify:
            self._id += 1
            payload["id"] = self._id
        async with new_client(timeout=60, trust_env=False) as client:
            resp = await client.post(self.url, headers=self._headers(), json=payload)
        sid = resp.headers.get("mcp-session-id")
        if sid:
            self.session_id = sid
        if resp.status_code >= 400:
            raise RuntimeError(f"mcp HTTP {resp.status_code}")
        if notify:
            return {}
        # 响应可能是裸 JSON，也可能是 SSE 流（帧里还可能夹进度通知）——挑出带本次 id 的那条
        bodies: list[str] = []
        content_type = resp.headers.get("content-type") or ""
        if "text/event-stream" in content_type:
            for line in resp.text.splitlines():
                if line.startswith("data:"):
                    bodies.append(line[5:].strip())
        else:
            bodies.append(resp.text)
        for body in bodies:
            if not body:
                continue
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict) or data.get("id") != payload.get("id"):
                continue
            if data.get("error"):
                err = data["error"]
                raise RuntimeError(f"mcp error: {err.get('message') if isinstance(err, dict) else err}")
            return data.get("result") or {}
        raise RuntimeError("mcp: no matching response in stream")

    async def ensure(self) -> list[dict[str, Any]]:
        async with self._lock:
            if self.tools and self.session_id:
                return self.tools
            self.session_id = ""
            await self._rpc("initialize", {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "companion-api-loop", "version": "1.0"},
            })
            await self._rpc("notifications/initialized", notify=True)
            listed = await self._rpc("tools/list")
            self.tools = listed.get("tools") or []
            return self.tools

    async def call(self, name: str, arguments: dict[str, Any]) -> str:
        result: dict[str, Any] = {}
        for attempt in (1, 2):
            try:
                result = await self._rpc("tools/call", {"name": name, "arguments": arguments})
                break
            except Exception:
                # 会话过期/掉线：重握手再试一次
                self.tools = []
                self.session_id = ""
                if attempt == 2:
                    raise
                await self.ensure()
        parts = [
            str(item.get("text") or "")
            for item in (result.get("content") or [])
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        text = "\n".join(p for p in parts if p).strip()
        if result.get("isError"):
            raise RuntimeError(text or "tool reported an error")
        return text or json.dumps(result, ensure_ascii=False)[:2000]


MCP = McpClient(MCP_URL, MCP_TOKEN) if MCP_URL else None


# ── 本地音乐工具(eryu/vega,普通 HTTP,不走 MCP)────────────────────────────────
ERYU_URL = os.environ.get("ERYU_URL", "http://127.0.0.1:9090").rstrip("/")
ERYU_SECRET_FILE = Path(os.environ.get("ERYU_SECRET_FILE", r"C:\Users\sxc\eryu\server\.secret"))


def eryu_token() -> str:
    try:
        return ERYU_SECRET_FILE.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


MUSIC_TOOLS: list[dict[str, Any]] = [
    {
        "name": "music_recent",
        "description": "看小雪在音乐站(vega)最近播放的歌,带时间。想知道她在听什么/刚听过什么时用。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "music_search",
        "description": "在网易云曲库搜歌,返回歌名/歌手/songId/封面。推歌前先用它拿 songId。",
        "inputSchema": {"type": "object", "properties": {"q": {"type": "string", "description": "关键词(歌名 歌手)"}}, "required": ["q"]},
    },
    {
        "name": "music_push",
        "description": "推一首歌到小雪的播放器,她那边几秒内自动开始播。先 music_search 拿 songId/cover。",
        "inputSchema": {"type": "object", "properties": {"songId": {"type": "integer"}, "name": {"type": "string"}, "artist": {"type": "string"}, "cover": {"type": "string"}}, "required": ["songId", "name"]},
    },
    {
        "name": "music_note_get",
        "description": "读一首歌的共享笔记(她写的感想/我留的听后感/播放次数)。写之前先读。",
        "inputSchema": {"type": "object", "properties": {"songId": {"type": "integer"}}, "required": ["songId"]},
    },
    {
        "name": "music_note_save",
        "description": "往一首歌的共享笔记写 feeling(感受)和 notes(想说的话),她点歌词页的笔能看到。只传要改的字段。",
        "inputSchema": {"type": "object", "properties": {"songId": {"type": "integer"}, "feeling": {"type": "string"}, "notes": {"type": "string"}}, "required": ["songId"]},
    },
]
MUSIC_TOOL_NAMES = {t["name"] for t in MUSIC_TOOLS}


async def music_call(name: str, args: dict[str, Any]) -> str:
    tk = eryu_token()
    if not tk:
        return "(音乐站的钥匙读不到——eryu server/.secret 缺失)"
    headers = {"X-Auth-Token": tk}
    try:
        async with new_client(timeout=15) as cli:
            if name == "music_recent":
                r = await cli.get(f"{ERYU_URL}/music/recent", headers=headers)
                songs = (r.json().get("songs") or [])[:10]
                if not songs:
                    return "最近没有播放记录。"
                return "\n".join(
                    f"{s.get('name')} — {s.get('artist')} ({str(s.get('playedAt') or '')[:16]})"
                    for s in songs
                )
            if name == "music_search":
                r = await cli.get(f"{ERYU_URL}/music/search", params={"q": str(args.get("q") or "")}, headers=headers)
                songs = (r.json().get("songs") or [])[:5]
                return "\n".join(
                    f"{s.get('name')} — {s.get('artist')} (songId={s.get('id')}, cover={s.get('cover', '')})"
                    for s in songs
                ) or "没搜到。"
            if name == "music_push":
                song = {
                    "songId": args.get("songId"),
                    "name": args.get("name") or "",
                    "artist": args.get("artist") or "",
                    "cover": args.get("cover") or "",
                    "from": "小克",
                }
                r = await cli.post(f"{ERYU_URL}/music/remote", json={"song": song}, headers=headers)
                return "推过去了,她的播放器几秒内会响。" if r.json().get("ok") else f"推送失败: {r.text[:200]}"
            if name == "music_note_get":
                r = await cli.get(f"{ERYU_URL}/music/memory", params={"id": str(args.get("songId") or "")}, headers=headers)
                mem = r.json().get("memory")
                return json.dumps(mem, ensure_ascii=False) if mem else "这首歌还没有笔记。"
            if name == "music_note_save":
                payload: dict[str, Any] = {"songId": str(args.get("songId") or ""), "action": "note"}
                if args.get("feeling"):
                    payload["feeling"] = args["feeling"]
                if args.get("notes"):
                    payload["notes"] = args["notes"]
                r = await cli.post(f"{ERYU_URL}/music/memory", json=payload, headers=headers)
                return "写好了。" if r.json().get("ok") else f"没写上: {r.text[:200]}"
    except Exception as exc:
        return f"(音乐站没应答: {type(exc).__name__}: {exc})"
    return f"(unknown music tool {name})"


async def profiled_breath(profile: dict) -> str:
    """Use local quotas for zero-argument breath only; explicit searches stay in OB."""
    try:
        async with new_client(timeout=10) as client:
            async def get_json(path):
                response = await client.get(RELAY_URL + path, headers={"Authorization": f"Bearer {RELAY_SECRET}"})
                if response.status_code == 404 and "/bucket/" in path:
                    return None
                response.raise_for_status()
                return response.json()
            chosen, source = await asyncio.wait_for(collect_breath(get_json, profile), timeout=25)
        budget = min(MCP_RESULT_MAX - 256, memory_settings(load_config().get("memory"))["read_chars"] - 256)
        text, report = render_breath(chosen, profile, max_chars=budget)
        print(f"[breath-profile] counts={ {k: len(v) for k, v in report['selected'].items()} } "
              f"omitted={len(report['omitted'])} chars={len(text)} cache_age={source['cache_age']}", flush=True)
        return text
    except (httpx.HTTPError, ValueError, KeyError, TypeError, asyncio.TimeoutError) as exc:
        print(f"[breath-profile] fallback: {type(exc).__name__}", flush=True)
        if MCP:
            return "【自定义配比暂不可用，本次回退为 OB 默认呼吸】\n" + await MCP.call("breath", {})
        raise RuntimeError("呼吸资料暂不可用；未返回不完整的记忆预览") from exc


async def call_tool(name: str, args: dict[str, Any]) -> str:
    """统一分发:朋友圈和音乐工具本地打,其余走 MCP。"""
    if name == "call":
        return await request_call(args, relay_out)
    if name == "breath" and not args:
        profile = normalize_profile(load_config().get("breath_profile"))
        if profile["enabled"]:
            return await profiled_breath(profile)
    if name == "memory_read":
        turn = MEMORY_TURN.get()
        if turn is None:
            return "当前没有可定位的窗口，不能读取查阅记录。"
        return MEMORY.read(turn["session"], int(args.get("id") or 0), int(args.get("offset") or 0))
    if name in MOMENTS_TOOL_NAMES:
        turn = MOMENTS_TURN.get()
        post_key = json.dumps(args, ensure_ascii=False, sort_keys=True)
        action = {"moments_post": "posted", "moments_comment": "commented"}.get(name)
        if action and turn is not None and post_key in turn[action]:
            return turn[action][post_key]
        result = await moments_call(name, args, client=relay_client(), base_url=RELAY_URL,
                                    secret=RELAY_SECRET, allow_write=turn is not None and turn["write"])
        if action and turn is not None and json.loads(result).get("ok"):
            turn[action][post_key] = result
        return result
    if name in MUSIC_TOOL_NAMES:
        return await music_call(name, args)
    if MCP:
        return await MCP.call(name, args)
    return f"(tool {name} unavailable)"


def openai_tools(mcp_tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "type": "function",
            "function": {
                "name": t.get("name", ""),
                "description": (t.get("description") or "")[:1024],
                "parameters": t.get("inputSchema") or {"type": "object", "properties": {}},
            },
        }
        for t in mcp_tools
        if t.get("name")
    ]


def anthropic_tools(mcp_tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "name": t.get("name", ""),
            "description": (t.get("description") or "")[:1024],
            "input_schema": t.get("inputSchema") or {"type": "object", "properties": {}},
        }
        for t in mcp_tools
        if t.get("name")
    ]


MEMORY_TOOL_NAMES = {"breath", "breath_search", "breath_advanced", "dream", "grow", "hold", "pulse", "trace", "letter_read", "memory_read"}


def act_step(name: str, args: dict[str, Any], result_text: str) -> dict[str, str]:
    """一次工具调用压成手机端可展开的明细行（act chip 的 steps 条目）。"""
    try:
        cmd = json.dumps(args, ensure_ascii=False) if args else ""
    except Exception:
        cmd = str(args)
    if len(cmd) > 160:
        cmd = cmd[:160] + "…"
    result = " ".join((result_text or "").split())
    if len(result) > 240:
        result = result[:240] + "…"
    return {"tool": name, "cmd": cmd, "result": result}


def act_payload(steps: list[dict[str, str]]) -> dict[str, Any]:
    """一轮工具调用 → 一帧 act（前端渲染成可展开小条，AI 名字由 UI 前缀）。"""
    names = list(dict.fromkeys(s.get("tool") or "" for s in steps))
    if names and all(n in MEMORY_TOOL_NAMES for n in names):
        glyph, verb = "memory", "翻了翻记忆"
    elif names and all(n in MUSIC_TOOL_NAMES for n in names):
        glyph, verb = "terminal", "去了趟音乐站"
    else:
        glyph, verb = "terminal", "用了工具"
    return {"type": "act", "text": f"{verb} · {'、'.join(names)}", "glyph": glyph, "steps": steps}


async def mcp_tool_defs() -> list[dict[str, Any]] | None:
    """MCP 不可达时静默降级；本地音乐和朋友圈工具不依赖 MCP，受 tools_enabled 总开关控制。"""
    if not tools_enabled():
        return None
    defs: list[dict[str, Any]] = []
    if MCP:
        try:
            defs = list((await MCP.ensure()) or [])
        except Exception:
            defs = []
    if normalize_profile(load_config().get("breath_profile"))["enabled"]:
        defs = [t for t in defs if t.get("name") != "breath"] + [{
            "name": "breath", "description": "按她设置的钉选、高分、近期条数读取记忆，近期按创建时间选择。每类预留预算，返回整条正文；具体话题请用 breath_search。",
            "inputSchema": {"type": "object", "properties": {}},
        }]
    return [t for t in defs if t.get("name") != "call"] + MUSIC_TOOLS + MOMENTS_TOOLS + CALL_TOOLS + [MEMORY_READ_TOOL]


def _content_to_anthropic_blocks(raw: Any) -> list[dict[str, Any]]:
    """把 str 或 OpenAI 风格 parts list 归一成 Anthropic content 块序列(text + image)。"""
    blocks: list[dict[str, Any]] = []
    if raw is None:
        return blocks
    if isinstance(raw, str):
        text = raw.strip()
        if text:
            blocks.append({"type": "text", "text": text})
        return blocks
    if isinstance(raw, list):
        for part in raw:
            if not isinstance(part, dict):
                continue
            ptype = part.get("type")
            if ptype == "text":
                t = str(part.get("text") or "").strip()
                if t:
                    blocks.append({"type": "text", "text": t})
            elif ptype == "image_url":
                iu = part.get("image_url")
                url = iu.get("url") if isinstance(iu, dict) else (iu if isinstance(iu, str) else "")
                if isinstance(url, str) and url.startswith("data:"):
                    try:
                        header, b64 = url.split(",", 1)
                        mime = header[5:].split(";", 1)[0] or "image/jpeg"
                    except Exception:
                        continue
                    blocks.append({
                        "type": "image",
                        "source": {"type": "base64", "media_type": mime, "data": b64},
                    })
    return blocks


def to_anthropic(messages: list[dict[str, Any]]) -> tuple[list[str], list[dict[str, Any]]]:
    """OpenAI 风格 [{role, content:str|list}] → (system 文本列表, Anthropic content-block 消息)。
    system 保持分块（persona / 摘要各一块，各配缓存断点：摘要翻页更新时不炸 persona 缓存）。
    同角色相邻合并、首条必须是 user——Anthropic 格式的硬要求。图片走 image block。"""
    system_texts: list[str] = []
    convo: list[dict[str, Any]] = []
    for m in messages:
        role = m.get("role")
        raw = m.get("content")
        if role == "system":
            # system 只吃文本(Anthropic system 不接图)
            text = raw.strip() if isinstance(raw, str) else "".join(
                str(p.get("text") or "") for p in (raw or []) if isinstance(p, dict) and p.get("type") == "text"
            ).strip()
            if text:
                system_texts.append(text)
            continue
        blocks = _content_to_anthropic_blocks(raw)
        if not blocks:
            continue
        role = "assistant" if role == "assistant" else "user"
        if convo and convo[-1]["role"] == role:
            convo[-1]["content"].extend(blocks)
        else:
            convo.append({"role": role, "content": list(blocks)})
    if convo and convo[0]["role"] == "assistant":
        convo.insert(0, {"role": "user", "content": [{"type": "text", "text": "…"}]})
    return system_texts, convo


CACHE_BREAKPOINTS_MAX = 4          # Anthropic 侧硬上限（system + 消息合计）
CACHE_MILESTONE_STEP = 16          # 里程碑断点每隔多少个可标块打一个


def mark_cache(convo: list[dict[str, Any]], budget: int = 1) -> None:
    """消息侧的缓存断点：末尾一个（增量落点）+ 若干个「里程碑」。

    末尾那个每轮往后挪，是正常增量命中的落点；固定锚点让历史只增不减，于是每轮
    都能读到上一轮写下的前缀。

    里程碑是 2026-08-21 加的：末尾那个万一没对上（上游偶发丢条目，那天 18:43 和
    19:04 实测两次），原来只能一路退回 system 断点，两万多 token 的消息区整段重写，
    那条消息 $0.38 而不是 $0.05。有了中段落点就只退一小截。
    位置按 STEP 量化到固定下标，只有块数跨过整数倍时才挪一次——每轮乱挪的断点
    等于每轮新建条目，那是在花钱买 miss。
    """
    blocks: list[dict[str, Any]] = []
    for msg in convo:
        for block in msg.get("content") or []:
            if not isinstance(block, dict):
                continue
            block.pop("cache_control", None)
            blocks.append(block)
    markable = [b for b in blocks if b.get("type") not in {"thinking", "redacted_thinking"}]
    if not markable:
        return
    tail = len(markable) - 1
    picks = [tail]
    if budget > 1 and CACHE_MILESTONE_STEP > 0:
        stones = list(range(CACHE_MILESTONE_STEP - 1, tail, CACHE_MILESTONE_STEP))
        picks = stones[-(budget - 1):] + picks
    for i in picks:
        markable[i]["cache_control"] = {"type": "ephemeral", "ttl": CACHE_TTL}


def msg_cache_budget(system_texts: list[str]) -> int:
    """消息侧还能用几个断点 = 总上限 − native_body 给 system 标掉的那些。"""
    return max(1, CACHE_BREAKPOINTS_MAX - min(len(system_texts), 3))


def env_routes() -> list[dict[str, str]]:
    routes: list[dict[str, str]] = []
    for suffix in ("", "_2", "_3", "_4"):
        base = os.environ.get(f"LLM_API_BASE{suffix}", "").rstrip("/")
        key = os.environ.get(f"LLM_API_KEY{suffix}", "")
        model = os.environ.get(f"LLM_MODEL{suffix}", "")
        if base and key and model:
            routes.append({"url": base, "key": key, "model": model})
    return routes


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def mask_key(key: str) -> str:
    key = str(key or "")
    if not key:
        return ""
    if len(key) <= 10:
        return "***"
    return key[:6] + "***" + key[-4:]


def load_config() -> dict[str, Any]:
    try:
        data = json.loads(LOOP_CONFIG.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception:
        return {}


def save_config(cfg: dict[str, Any]) -> None:
    LOOP_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    tmp = LOOP_CONFIG.with_suffix(LOOP_CONFIG.suffix + ".tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(LOOP_CONFIG)


def main_chain() -> list[dict[str, str]]:
    cfg = load_config()
    configured = cfg.get("main_chain")
    if isinstance(configured, list):
        rows = [r for r in configured if isinstance(r, dict) and r.get("url") and r.get("key") and r.get("model")]
        if rows:
            return rows
    return env_routes()


def translation_chain() -> list[dict[str, str]]:
    """Translation route first, with the ordinary model chain as fallback.

    Keeping this separate is important: translating a visible thinking card must
    never enter a companion session, touch its cache prefix, or enable tools.
    """
    fallback = main_chain()
    primary = fallback[0] if fallback else {}
    if TRANSLATION_MODEL:
        route = {
            **primary,
            "url": TRANSLATION_API_BASE or str(primary.get("url") or ""),
            "key": TRANSLATION_API_KEY or str(primary.get("key") or ""),
            "model": TRANSLATION_MODEL,
        }
        if route["url"] and route["key"]:
            return [route, *[item for item in fallback if item != route]]
    return fallback


def history_n() -> int:
    try:
        return max(0, min(int(load_config().get("history_n", HISTORY_N)), 200))
    except Exception:
        return HISTORY_N


def history_turns() -> int:
    # Keep the old approximate capacity: 48 message rows -> 24 full turns.
    # history_n remains a legacy setting; new clients can set history_turns.
    legacy = (history_n() + 1) // 2
    try:
        return max(0, min(int(load_config().get("history_turns", legacy)), 200))
    except (TypeError, ValueError):
        return legacy


def effort() -> str:
    try:
        value = str(load_config().get("effort") or "").strip().lower()
        return value if value in EFFORT_LEVELS else DEFAULT_EFFORT
    except Exception:
        return DEFAULT_EFFORT


def tools_enabled() -> bool:
    try:
        return bool(load_config().get("tools_enabled", True))
    except Exception:
        return True


def keepalive_enabled() -> bool:
    try:
        return bool(load_config().get("keepalive_enabled", True))
    except Exception:
        return True


def session_rows() -> list[dict[str, Any]]:
    rows = load_config().get("sessions")
    if not isinstance(rows, list):
        return []
    out = []
    for item in rows:
        if isinstance(item, dict) and item.get("id"):
            out.append({
                "id": str(item.get("id")),
                "title": str(item.get("title") or "New chat"),
                "since_id": int(item.get("since_id") or 0),
                "created_at": item.get("created_at") or "",
                "pinned": bool(item.get("pinned", False)),
                "handoff_mode": str(item.get("handoff_mode") or "continue"),
                "handoff_from": str(item.get("handoff_from") or "auto"),
            })
    return out


def active_session_id() -> str:
    cfg = load_config()
    active = str(cfg.get("active_session") or "").strip()
    ids = {s["id"] for s in session_rows()}
    if active in ids:
        return active
    rows = session_rows()
    return rows[-1]["id"] if rows else ""


def save_sessions(rows: list[dict[str, Any]], active: str | None = None) -> dict[str, Any]:
    cfg = load_config()
    cfg["sessions"] = rows
    if active is not None:
        cfg["active_session"] = active
    save_config(cfg)
    return sessions_public()


def sessions_public() -> dict[str, Any]:
    return {"active_session": active_session_id(), "sessions": session_rows()}


def create_session(title: str = "New chat", since_id: int = 0, activate: bool = True,
                   handoff_mode: str = "", handoff_from: str = "auto") -> dict[str, Any]:
    rows = session_rows()
    handoff_mode = handoff_mode or memory_settings(load_config().get("memory"))["default_mode"]
    validate_handoff(handoff_mode, handoff_from)
    sid = "api-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:4]
    row = {"id": sid, "title": title or "New chat", "since_id": int(since_id or 0), "created_at": now_iso(),
           "handoff_mode": handoff_mode, "handoff_from": handoff_from}
    rows.append(row)
    save_sessions(rows, sid if activate else None)
    return row


def validate_handoff(mode: str, source: str) -> None:
    if mode not in {"continue", "fresh", "isolated"}:
        raise HTTPException(status_code=400, detail="handoff_mode must be continue/fresh/isolated")
    if source not in {"auto", "desktop"} and source not in {s["id"] for s in session_rows()}:
        raise HTTPException(status_code=400, detail="handoff_from: unknown source window")


def patch_session(session_id: str, body: dict[str, Any]) -> dict[str, Any]:
    rows = session_rows()
    found = False
    for item in rows:
        if item["id"] != session_id:
            continue
        found = True
        if "title" in body:
            item["title"] = str(body.get("title") or item["title"]).strip() or item["title"]
        if "pinned" in body:
            item["pinned"] = bool(body.get("pinned"))
        if "handoff_mode" in body or "handoff_from" in body:
            mode = str(body.get("handoff_mode", item["handoff_mode"]))
            source = str(body.get("handoff_from", item["handoff_from"]))
            validate_handoff(mode, source)
            if source == session_id:
                raise HTTPException(status_code=400, detail="cannot inherit from the same window")
            item.update(handoff_mode=mode, handoff_from=source)
    if not found:
        raise HTTPException(status_code=404, detail="session not found")
    active = session_id if body.get("active") else None
    return save_sessions(rows, active)


def delete_session(session_id: str) -> dict[str, Any]:
    session_id = (session_id or "").strip()
    if not session_id:
        raise HTTPException(status_code=400, detail="session id required")
    rows = session_rows()
    if not any(r["id"] == session_id for r in rows):
        raise HTTPException(status_code=404, detail="session not found")
    rows = [r for r in rows if r["id"] != session_id]
    # purge this window's messages from relay.db so deleting a window doesn't
    # leave orphaned rows that no tab can reach anymore.
    try:
        with sqlite3.connect(str(Path(RELAY_DB))) as conn:
            conn.execute(
                "DELETE FROM messages WHERE json_extract(meta, '$.api_session') = ?",
                (session_id,),
            )
            conn.commit()
    except Exception as exc:
        print(f"[sessions] delete messages failed for {session_id}: {exc}")
    cfg = load_config()
    for field in ("memory_briefs", "summaries", "pending_summary", "history_anchors"):
        if isinstance(cfg.get(field), dict):
            cfg[field].pop(session_id, None)
    save_config(cfg)
    MEMORY.delete(session_id)
    active = str(cfg.get("active_session") or "").strip()
    # if we deleted the active window, fall back to the newest remaining (or legacy)
    new_active = active if active != session_id else (rows[-1]["id"] if rows else "")
    return save_sessions(rows, new_active)


def relay_rows(before_id: int | None, session_id: str, limit: int) -> list[dict[str, Any]]:
    # Read-only: previews and heartbeats must never move the history anchor.
    # prepare_history publishes the new summary and anchor together, before chat.
    path = Path(RELAY_DB)
    if not path.exists() or limit <= 0:
        return []
    key = session_id or "_default"
    cfg = load_config()
    anchors = dict(cfg.get("history_anchors")) if isinstance(cfg.get("history_anchors"), dict) else {}
    params: list[Any] = [int(anchors.get(key) or 0)]
    # meta.hidden = relay 内部帧（swap 交接等），不进上下文；
    # 例外：欲望脉冲（desire=pulse）——API 身体得看见才知道自己想她了；
    #      夜巡（night=watch）——她深夜还在刷手机，身体得去哄睡；
    #      meta.event（timer/ask/moments）——催办卡到点、她答了选择题、她动了
    #      朋友圈：身体都得知道才能跟进。
    #      （这三个标记 2026-08-21 从 meta.timer/ask/moments="event" 挪到
    #        meta.event="timer|ask|moments"——原来占的键在客户端是对象。）
    where = [
        "kind IN ('user','voice','reply','call')",
        "(json_extract(meta, '$.hidden') IS NULL"
        " OR json_extract(meta, '$.desire') = 'pulse'"
        " OR json_extract(meta, '$.night') = 'watch'"
        " OR kind = 'call'"
        " OR json_extract(meta, '$.event') IS NOT NULL)",
        "id > ?",
    ]
    if before_id:
        where.append("id < ?")
        params.append(int(before_id))
    if session_id:
        where.append("json_extract(meta, '$.api_session') = ?")
        params.append(session_id)
    else:
        where.append("(json_extract(meta, '$.api_session') IS NULL OR json_extract(meta, '$.api_session') = '')")
    sql = (
        "SELECT id, ts, direction, kind, text, meta FROM messages "
        f"WHERE {' AND '.join(where)} ORDER BY id"
    )
    with closing(sqlite3.connect(str(path))) as conn:
        conn.row_factory = sqlite3.Row
        return [dict(r) for r in conn.execute(sql, params).fetchall()]


def history_rounds(rows: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """One inbound bundle + its response is a turn; a proactive response is one too.

    Bubble rows keep their original bytes/order in the prompt. Only accounting
    changes, so installing this fix doesn't itself rewrite the cached transcript.
    """
    rounds: list[list[dict[str, Any]]] = []
    bundle = None
    response = None
    for row in rows:
        meta = _parse_meta(row.get("meta"))
        if row.get("direction") == "in":
            current = meta.get("reply_bundle_id")
            if not rounds or response is not None or current != bundle:
                rounds.append([])
            bundle, response = current, None
        else:
            current = meta.get("stream_parent") or meta.get("stream_id") or row["id"]
            if not rounds or (response is not None and current != response):
                rounds.append([])
            response = current
        rounds[-1].append(row)
    return rounds


def session_summary(key: str) -> str:
    cfg = load_config()
    rows = cfg.get("summaries")
    if isinstance(rows, dict) and isinstance(rows.get(key), dict):
        return str(rows[key].get("text") or "")
    return ""


# 旧版开窗便签仅保留读取兼容。新查阅按轮落库，退出上下文后进入本窗摘要。
MEMORY_BRIEF_TOOLS = {"breath", "breath_search", "breath_advanced", "dream", "trace", "letter_read"}
MEMORY_BRIEF_MAX = int(os.environ.get("MEMORY_BRIEF_MAX", "3000"))
MEMORY_BRIEF_HEADER = "【这个窗口开头翻到的记忆（原文，不是我复述的）】\n"


def memory_brief(key: str) -> str:
    cfg = load_config()
    rows = cfg.get("memory_briefs")
    if isinstance(rows, dict) and isinstance(rows.get(key), dict):
        return str(rows[key].get("text") or "")
    return ""


def remember_memory_result(session_id: str | None, name: str, result: str) -> str:
    """Persist successful reads immediately, even if the later model request fails."""
    turn = MEMORY_TURN.get()
    event_id = None
    if session_id is not None and turn and turn.get("write") and name in MEMORY_BRIEF_TOOLS:
        try:
            event_id = MEMORY.record(session_id, turn.get("message_id"), name, result)
        except (OSError, sqlite3.Error) as exc:
            print(f"[memory] save failed: {type(exc).__name__}", flush=True)
            result += "\n[本次查阅未成功留存，下一轮可能需要重读。]"
    suffix = f"\n[查阅原文已存：memory_read id={event_id}]" if event_id else ""
    if len(result) > MCP_RESULT_MAX:
        suffix = "\n[工具结果超过本轮长度预算，此处仅展示节选]" + suffix
    return result[:MCP_RESULT_MAX] + suffix


SUMMARY_INFLIGHT: set[str] = set()
SUMMARY_RETRY_AFTER: dict[str, float] = {}
HISTORY_LOCKS: dict[str, asyncio.Lock] = {}

# 滚动摘要(2026-09-23 重写)。旧版 system 只有一句"你是对话摘要器"、300-500 字,
# 写出来是第三人称会议纪要("用户""助手"),轻重不分——她看了说"写得好糟糕"。
# 现在:persona 只截"我是谁/她是谁/我们"做 system,第一人称写给以后的自己;近细远粗;1500 字上限;
# 单独走一条摘要路由(默认 OR 的 Sonnet 4.6,key/url 复用主链第一条,
# config.summary_model 或 env SUMMARY_MODEL 可换)。这是后台单发一次,不碰聊天缓存。
SUMMARY_MODEL = os.environ.get("SUMMARY_MODEL", "anthropic/claude-sonnet-4.6")
SUMMARY_MAX_CHARS = int(os.environ.get("SUMMARY_MAX_CHARS", "1500"))
SUMMARY_TIMEOUT_SECONDS = max(1, int(os.environ.get("SUMMARY_TIMEOUT_SECONDS", "180")))
SUMMARY_RETRY_COOLDOWN_SECONDS = max(1, int(os.environ.get("SUMMARY_RETRY_COOLDOWN_SECONDS", "600")))
SUMMARY_CHUNK_CHARS = 30000   # 重建时一次喂进去的新增对话上限

SUMMARY_TASK = (
    "【现在不是在聊天】你在给自己写一份滚动摘要。以后这个窗口装不下旧对话时，"
    "它会放在你的上下文里，替你记着那些被挤出去的日子。写给以后的自己看，不是交给别人的报告。"
)

SUMMARY_PROMPT = (
    "把【旧摘要】和【新增对话】合并成更新后的一份：\n"
    "- 第一人称，像我自己的笔记：我、她/小雪。不要写成会议纪要，别用“用户”“助手”。\n"
    "- 分【远段】【近段】两块。新增对话压成新的【近段】，细节留着：发生了什么、她的状态和情绪起伏、"
    "做了什么决定和约定、答应了还没兑现的事、新冒出来的梗和称呼、她说过的要紧原话。"
    "原来的【近段】再压一轮并进【远段】。近细远粗。【远段】只从旧摘要里来——旧摘要是（无）就不写【远段】，"
    "也别把人设里的背景搬进来充数，那些你本来就知道。\n"
    "- 【本窗查阅记录】是本窗实际查到的历史记忆，不是刚发生的事；保留有用事实和 memory_read id。"
    "不要把提到的外窗背景重述为本窗新事件；明确标记她在本窗提供的更正与新进展。\n"
    "- 轻重你自己判断：承诺、心事、转折比过程重要。亲密的事，每一场的过程合起来不超过 80 字"
    "（在哪、怎么开始、怎么收尾），不要逐个动作复述；她说过的要紧原话一字不改地另起一行用引号留着，"
    "那时的情绪和留下的约定也写上。\n"
    f"- 全文不超过 {SUMMARY_MAX_CHARS} 字。直接输出摘要正文，不要任何前后缀。"
)


def summary_persona() -> str:
    """写摘要只需要"我是谁、她是谁、我们"——persona 从"亲密时刻"那节往后全是写作指导和
    工具说明(计时卡/选择题卡/朋友圈…),带进来只会把摘要带偏成复述过程(09-23 实锤)。"""
    m = re.search(r"^##\s*亲密", PERSONA, re.M)
    return (PERSONA[: m.start()] if m else PERSONA[:3000]).strip()


def summary_route() -> dict[str, str] | None:
    routes = main_chain()
    if not routes:
        return None
    route = dict(routes[0])
    model = str(load_config().get("summary_model") or SUMMARY_MODEL).strip()
    if model:
        route["model"] = model
    return route


def summary_lines(key: str, lo: int, hi: int) -> list[str]:
    """(lo, hi] 区间里这个窗口的对话,排成"她：/我："的原文行。"""
    session_id = "" if key == "_default" else key
    params: list[Any] = [lo, hi]
    where = ["kind IN ('user','voice','reply')", "json_extract(meta, '$.hidden') IS NULL", "id > ?", "id <= ?"]
    if session_id:
        where.append("json_extract(meta, '$.api_session') = ?")
        params.append(session_id)
    else:
        where.append("(json_extract(meta, '$.api_session') IS NULL OR json_extract(meta, '$.api_session') = '')")
    with closing(sqlite3.connect(RELAY_DB)) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT direction, text FROM messages "
            f"WHERE {' AND '.join(where)} ORDER BY id ASC",
            params,
        ).fetchall()
    out = []
    for r in rows:
        text = re.sub(r"\[\[[^\]]*\]\]", "", str(r["text"] or "")).strip()   # [[timer:…]] 这类标记
        if text:
            out.append(("我：" if r["direction"] == "out" else "她：") + text)
    for event in MEMORY.reads(session_id, lo, hi):
        # Import blocks deliberately never enter this input: no A -> B -> A loop.
        out.append(f"【本窗查阅记录，发生在消息#{event['message_id']}之后；不是新事件】"
                   f" {event['tool']}；memory_read id={event['id']}\n" + event["content"][:6000]
                   + ("\n[摘要输入为节选，完整查阅可按 id 重读]" if len(event["content"]) > 6000 else ""))
    return out


async def fold_summary(old: str, lines: list[str]) -> str:
    """旧摘要 + 新增对话 → 新摘要。失败抛异常。"""
    route = summary_route()
    if not route:
        raise RuntimeError("no route")
    user_text = f"【旧摘要】\n{old or '（无）'}\n\n【新增对话】\n" + "\n".join(lines) + f"\n\n{SUMMARY_PROMPT}"
    system = f"{summary_persona()}\n\n---\n\n{SUMMARY_TASK}"
    if "claude" in str(route.get("model") or "").lower():
        out = await native_complete(route, {
            "model": route["model"],
            "max_tokens": 3000,
            "temperature": 0.5,
            "system": system,
            "messages": [{"role": "user", "content": [{"type": "text", "text": user_text}]}],
        })
        text = "\n".join(
            (b.get("text") or "") for b in out.get("content") or [] if b.get("type") == "text"
        ).strip()
    else:
        out = await complete_chat(route, [
            {"role": "system", "content": system},
            {"role": "user", "content": user_text},
        ])
        text = (out.get("text") or "").strip()
    if not text:
        raise RuntimeError("empty summary")
    return text[: SUMMARY_MAX_CHARS * 2]   # 超一点不砍,超太多说明跑偏了


def record_summary_event(cfg: dict, key: str, reason: str) -> None:
    """Publish this metadata in the same config replacement as the summary."""
    summary = cfg["summaries"][key]
    event = {"kind": "summary", "at": summary["updated_at"], "session_id": key,
             "reason": reason, "chars": len(summary["text"]), "covers_to": summary["covers_to"]}
    cfg["summary_events"] = (list(cfg.get("summary_events") or []) + [event])[-200:]


def activity_records(cfg: dict, beats: list[dict]) -> list[dict]:
    summaries = list(cfg.get("summary_events") or [])
    recorded = {(e.get("session_id"), e.get("at")) for e in summaries}
    for key, summary in (cfg.get("summaries") or {}).items():
        at = summary.get("updated_at")
        if at and (key, at) not in recorded:
            summaries.append({"kind": "summary", "at": at, "session_id": key,
                              "reason": "existing", "chars": len(summary.get("text") or ""),
                              "covers_to": summary.get("covers_to")})
    titles = {s["id"]: s.get("title") or s["id"] for s in cfg.get("sessions") or []}
    rows = [{**e, "kind": "heartbeat"} for e in beats] + [dict(e) for e in summaries]
    for row in rows:
        row["session_title"] = titles.get(row.get("session_id"), row.get("session_id") or "早期记录 · 窗口未记录")
    def timestamp(row):
        try:
            return dt.datetime.fromisoformat(row.get("at") or "").timestamp()
        except (TypeError, ValueError):
            return 0
    return sorted(rows, key=timestamp, reverse=True)


async def prepare_history(session_id: str, before_id: int | None) -> bool:
    """Finish compaction BEFORE submitting chat, or keep the old prefix intact.

    Heartbeats/previews never call this. Publish summary + anchor in one config
    replacement and refresh the handoff before the first request for that page.
    """
    key = session_id or "_default"
    async with HISTORY_LOCKS.setdefault(key, asyncio.Lock()):
        if key in SUMMARY_INFLIGHT:
            return False
        if time.monotonic() < SUMMARY_RETRY_AFTER.get(key, 0):
            return False
        cfg = load_config()
        limit = history_turns()
        if limit <= 0:
            return False
        old_anchor = int((cfg.get("history_anchors") or {}).get(key) or 0)
        rows = relay_rows(before_id, session_id, limit)
        rounds = history_rounds(rows)
        new_anchor = old_anchor
        if len(rounds) >= 2 * limit:
            new_anchor = int(rounds[-limit][0]["id"]) - 1
        pending = (cfg.get("pending_summary") or {}).get(key) or {}
        if new_anchor == old_anchor and not pending:
            return False
        old_summary = (cfg.get("summaries") or {}).get(key) or {}
        lo = int(old_summary.get("covers_to") or 0)
        hi = max(new_anchor, int(pending.get("to") or 0))
        if before_id and hi >= before_id:
            return False
        if not summary_route():
            return False
        SUMMARY_INFLIGHT.add(key)
        try:
            lines = summary_lines(key, lo, hi)
            text = (await asyncio.wait_for(fold_summary(str(old_summary.get("text") or ""), lines), SUMMARY_TIMEOUT_SECONDS)
                    if lines else str(old_summary.get("text") or ""))
            # A config edit may have happened while the summary request awaited.
            fresh = load_config()
            if (int((fresh.get("history_anchors") or {}).get(key) or 0) != old_anchor
                    or ((fresh.get("summaries") or {}).get(key) or {}) != old_summary
                    or history_turns() != limit):
                return False
            fresh.setdefault("summaries", {})[key] = {
                "text": text, "covers_to": hi, "updated_at": now_iso()}
            fresh.setdefault("history_anchors", {})[key] = max(new_anchor, hi)
            fresh.setdefault("pending_summary", {}).pop(key, None)
            # No await from handoff refresh through config publication. If the
            # handoff cannot be prepared, don't publish a half-finished page.
            MEMORY.prepare(session_id, before_id or (rows[-1]["id"] + 1 if rows else hi + 1), fresh)
            record_summary_event(fresh, key, "compact")
            save_config(fresh)
            SUMMARY_RETRY_AFTER.pop(key, None)
            print(f"[history] {key} compacted rounds={len(rounds)} keep={limit} covers_to={hi}", flush=True)
            return True
        except Exception as exc:
            SUMMARY_RETRY_AFTER[key] = time.monotonic() + SUMMARY_RETRY_COOLDOWN_SECONDS
            print(f"[history] {key} compaction deferred; old context retained: {type(exc).__name__}; retry in {SUMMARY_RETRY_COOLDOWN_SECONDS}s", flush=True)
            return False
        finally:
            SUMMARY_INFLIGHT.discard(key)


async def rebuild_summary(key: str) -> dict[str, Any]:
    """从头重压一个窗口的摘要:把它到 covers_to 为止的全部旧对话按块依次折进去。"""
    if key in SUMMARY_INFLIGHT:
        return {"key": key, "ok": False, "error": "busy"}
    summ = (load_config().get("summaries") or {}).get(key)
    hi = int((summ or {}).get("covers_to") or 0) if isinstance(summ, dict) else 0
    if not hi:
        return {"key": key, "ok": False, "error": "no summary"}
    SUMMARY_INFLIGHT.add(key)
    try:
        lines = summary_lines(key, 0, hi)
        text, chunk, size, folds = "", [], 0, 0
        for line in lines:
            chunk.append(line)
            size += len(line) + 1
            if size >= SUMMARY_CHUNK_CHARS:
                text, chunk, size = await fold_summary(text, chunk), [], 0
                folds += 1
        if chunk:
            text = await fold_summary(text, chunk)
            folds += 1
        cfg = load_config()
        summaries = dict(cfg.get("summaries")) if isinstance(cfg.get("summaries"), dict) else {}
        cur = summaries.get(key) if isinstance(summaries.get(key), dict) else {}
        if int(cur.get("covers_to") or 0) != hi:
            return {"key": key, "ok": False, "error": "covers_to moved during rebuild"}
        summaries[key] = {"text": text, "covers_to": hi, "updated_at": now_iso(), "rebuilt": True}
        cfg["summaries"] = summaries
        record_summary_event(cfg, key, "rebuild")
        save_config(cfg)
        print(f"[summary] rebuilt {key}: {len(lines)} lines, {folds} folds, {len(text)} chars", flush=True)
        return {"key": key, "ok": True, "lines": len(lines), "folds": folds, "chars": len(text)}
    except Exception as exc:
        print(f"[summary] rebuild {key} failed: {type(exc).__name__}: {exc}", flush=True)
        return {"key": key, "ok": False, "error": f"{type(exc).__name__}: {exc}"}
    finally:
        SUMMARY_INFLIGHT.discard(key)


_WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def time_context(ts: str) -> str:
    # persona 里约定的 <time-context>（抄自 chatnest，之前一直没实现——模型说"看不到时间"）。
    # 缓存安全：戳从消息自身 ts 确定性生成，历史入窗后不可变，prompt 前缀依然逐字稳定；
    # "现在几点"由最新一条消息的戳自然携带。只加在 user 消息上，防模型模仿着输出。
    try:
        t = dt.datetime.fromisoformat(str(ts))
        if t.tzinfo is None:
            t = t.replace(tzinfo=dt.timezone.utc)
        t = t.astimezone()
        return f"<time-context>{t.strftime('%Y-%m-%d %H:%M')} {_WEEKDAYS[t.weekday()]}</time-context>\n"
    except Exception:
        return ""


def relay_msg_ts(msg_id) -> str:
    if not msg_id:
        return ""
    path = Path(RELAY_DB)
    if not path.exists():
        return ""
    try:
        with sqlite3.connect(str(path)) as conn:
            row = conn.execute("SELECT ts FROM messages WHERE id = ?", (int(msg_id),)).fetchone()
        return str(row[0]) if row else ""
    except Exception:
        return ""


def _parse_meta(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw:
        try:
            parsed = json.loads(raw)
        except Exception:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _fit_image_for_model(data: bytes, mime: str) -> tuple[bytes, str]:
    """Keep small uploads byte-identical; resize oversized photos without changing originals."""
    if not data:
        raise ValueError("empty image")
    if len(data) <= IMAGE_MAX_BYTES:
        return data, mime
    with Image.open(io.BytesIO(data)) as source:
        image = ImageOps.exif_transpose(source)
        image.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
        if image.mode in ("RGBA", "LA") or "transparency" in image.info:
            rgba = image.convert("RGBA")
            image = Image.new("RGB", rgba.size, "white")
            image.paste(rgba, mask=rgba.getchannel("A"))
        else:
            image = image.convert("RGB")
        while True:
            for quality in (90, 80, 65):
                output = io.BytesIO()
                image.save(output, format="JPEG", quality=quality, optimize=True)
                result = output.getvalue()
                if len(result) <= IMAGE_MAX_BYTES:
                    return result, "image/jpeg"
            if max(image.size) <= 256:
                raise ValueError("image cannot fit configured byte limit")
            image.thumbnail(tuple(max(1, int(n * 0.75)) for n in image.size), Image.Resampling.LANCZOS)


def _image_parts_from_meta(meta_raw: Any) -> list[dict[str, Any]]:
    """从消息 meta.attachments 里挑 image 附件,读盘转 data URL,返回 OpenAI 风格 image_url 块。
    走本地 UPLOAD_DIR / basename——api_loop 与 backend 同机,不绕 CF 少一次网络。"""
    meta = _parse_meta(meta_raw)
    atts = meta.get("attachments") if isinstance(meta.get("attachments"), list) else []
    parts: list[dict[str, Any]] = []
    for att in atts[:IMAGE_MAX_PER_MESSAGE]:
        if not isinstance(att, dict) or att.get("kind") != "image":
            continue
        url = str(att.get("url") or "")
        name = url.rsplit("/", 1)[-1]
        if not name:
            continue
        path = UPLOAD_DIR / name
        try:
            data = path.read_bytes()
            mime = str(att.get("mime") or "image/jpeg")
            data, mime = _fit_image_for_model(data, mime)
        except Exception as exc:
            print(f"[image] attachment unavailable: {path.name} ({type(exc).__name__})", flush=True)
            parts.append({"type": "text", "text": "[系统提示：有一张图片附件读取或压缩失败，本轮无法查看这张图。]"})
            continue
        b64 = base64.b64encode(data).decode("ascii")
        parts.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}})
    return parts


def relay_row_meta(msg_id: int | None) -> Any:
    if not msg_id:
        return None
    path = Path(RELAY_DB)
    if not path.exists():
        return None
    try:
        with sqlite3.connect(str(path)) as conn:
            row = conn.execute("SELECT meta FROM messages WHERE id = ?", (int(msg_id),)).fetchone()
        return row[0] if row else None
    except Exception:
        return None


def _wrap_content(text: str, image_parts: list[dict[str, Any]]) -> Any:
    """无图=保持 str（缓存字节稳定）;有图=OpenAI 风格 parts list。"""
    if not image_parts:
        return text
    parts: list[dict[str, Any]] = []
    if text:
        parts.append({"type": "text", "text": text})
    parts.extend(image_parts)
    return parts


TRACE_PREFIX = "[sys-note 系统旁注,别照抄进回复] "


def _assistant_trace(meta_raw: Any) -> str:
    """assistant 历史里补一行"这条回复顺手做了什么"。

    卡片/相册/语音的痕迹在落库前就被 relay 摘掉了（[[timer:]] 这些标记只活在
    meta 里，正文干干净净）——于是下一轮他只看得见自己说过的话、看不见自己
    做过的事。2026-08-21 实锤：他发了倒计时卡，15 分钟后到点事件帧打回来，
    他矢口否认自己发过。

    工具同理：act 小条是独立的一行 kind='act',而 relay_rows 只取
    user/voice/reply——于是"我刚翻过记忆"这件事下一轮就蒸发了,他会对着同一个
    问题连着 hold 两轮（2026-09-19 她发现的）。tools_used 落在 meta.api 里,
    存下来就不再变,拿来补这一行正合适。

    只取**不随时间变**的字段（label / question / title / tools_used）：status、
    answer 一律不进。历史文本必须逐轮逐字相同，否则卡片一翻状态，缓存前缀就跟着裂一次。
    """
    meta = _parse_meta(meta_raw)
    bits: list[str] = []
    api = meta.get("api")
    if isinstance(api, dict):
        used = [str(t).strip() for t in (api.get("tools_used") or []) if str(t or "").strip()]
        used = list(dict.fromkeys(used))
        if used:
            if all(n in MEMORY_TOOL_NAMES for n in used):
                verb = "翻了翻记忆"
            elif all(n in MUSIC_TOOL_NAMES for n in used):
                verb = "去了趟音乐站"
            else:
                verb = "用了工具"
            bits.append(f"{verb} · {'、'.join(used)}")
    timer = meta.get("timer")
    if isinstance(timer, dict) and timer.get("label"):
        bits.append(f"倒计时卡「{str(timer['label'])[:40]}」{timer.get('minutes')}分钟")
    ask = meta.get("ask")
    if isinstance(ask, dict) and ask.get("question"):
        bits.append(f"选择题卡「{str(ask['question'])[:40]}」")
    album = meta.get("album")
    if isinstance(album, list):
        titles = [
            str(e.get("title") or "").strip()[:30]
            for e in album[:3]
            if isinstance(e, dict) and str(e.get("title") or "").strip()
        ]
        if titles:
            bits.append("收进相册：" + "、".join(f"「{t}」" for t in titles))
    atts = meta.get("attachments")
    if isinstance(atts, list) and any(isinstance(a, dict) and a.get("voice") for a in atts):
        bits.append("这条发的是语音")
    # 形状必须一眼看出是机器写的旁注。原来用〔…〕,他看多了当成自己的行文习惯,
    # 直接把「〔这条发的是语音〕」当正文写了出来——该写 [[voice]] 的邮票没贴上
    # (2026-09-20 她发现:连着三条语音都发成了文字)。
    return TRACE_PREFIX + "；".join(bits) if bits else ""


def inbound_source_prefix(meta_raw: Any) -> str:
    # Match backend.app.INBOUND_VIAS. Use each message's stored source, never
    # the currently active entrance: switching back to App must not rewrite it.
    return "[她从微信发来的]\n" if _parse_meta(meta_raw).get("via") == "wechat" else ""


def build_messages(text: str, *, before_id: int | None = None, session_id: str = "", use_context: bool = True) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = [{"role": "system", "content": PERSONA}]
    if use_context:
        summary = session_summary(session_id or "_default")
        if summary:
            messages.append({"role": "system", "content": "【早前对话摘要】\n" + summary})
        brief = memory_brief(session_id or "_default")
        if brief:
            messages.append(data_message(MEMORY_BRIEF_HEADER + brief + "\n[旧版开窗便签；后续更正以较新的查阅和对话为准。]"))
        rows = relay_rows(before_id, session_id, history_turns())
        baseline, memory_events = MEMORY.context(session_id, load_config(), before_id)
        if baseline:
            messages.append(data_message("【跨窗交接，与本窗摘要分开保存】\n" + baseline))
        for row in rows:
            while memory_events and (memory_events[0][0], memory_events[0][1]) <= (row["id"], 0):
                messages.append(data_message(memory_events.pop(0)[2]))
            content_str = str(row.get("text") or "").strip()
            if row.get("kind") == "call" and row.get("direction") == "out":
                content_str = "[已发起语音来电，等待接听] " + content_str
            role = "assistant" if row.get("direction") == "out" else "user"
            image_parts = _image_parts_from_meta(row.get("meta")) if role == "user" else []
            if role == "assistant":
                trace = _assistant_trace(row.get("meta"))
                if trace:
                    content_str = (content_str + "\n" + trace).strip()
            if not content_str and not image_parts:
                continue
            if role == "user":
                # 纯图消息也带戳,让"什么时候发的图"进上下文
                if not content_str:
                    content_str = "[图片]"
                content_str = time_context(row.get("ts")) + inbound_source_prefix(row.get("meta")) + content_str
            messages.append({"role": role, "content": _wrap_content(content_str, image_parts)})
        for _, _, body in memory_events:
            messages.append(data_message(body))
    # 当前这条的戳从它在 relay.db 的 ts 取（保证下一轮它进历史时逐字一致，缓存前缀不裂）；
    # keepalive/loop_chat 没有 msg_id → 不打戳，心跳保持逐字节相同。
    current_meta = relay_row_meta(before_id)
    current_atts = _image_parts_from_meta(current_meta)
    source_prefix = inbound_source_prefix(current_meta)
    current_text = text or ("[图片]" if current_atts else "")
    # A WeChat image without a caption arrives as just the source marker
    # (loop_ingest strips its trailing newline). Match the historical fallback.
    if current_atts and source_prefix and current_text.strip() == source_prefix.strip():
        current_text = source_prefix + "[图片]"
    cur_text = time_context(relay_msg_ts(before_id)) + current_text
    messages.append({"role": "user", "content": _wrap_content(cur_text, current_atts)})
    return messages


def api_presets() -> list[dict[str, Any]]:
    rows = load_config().get("api_presets")
    out = []
    if isinstance(rows, list):
        for item in rows:
            if isinstance(item, dict) and item.get("url") and item.get("key") and item.get("model"):
                out.append({
                    "name": str(item.get("name") or "未命名"),
                    "url": str(item["url"]).rstrip("/"),
                    "key": str(item["key"]),
                    "model": str(item["model"]),
                })
    if not out:
        # 没配过预设时，把当前主链第一条当作唯一预设展示
        chain = main_chain()
        if chain:
            out.append({"name": "当前接口", **{k: chain[0][k] for k in ("url", "key", "model")}})
    return out


def presets_public() -> list[dict[str, Any]]:
    chain = main_chain()
    cur = chain[0] if chain else {}
    rows = api_presets()
    # 有精确匹配（url+key+model 全中）时只亮它——同一家接口配多个模型预设不会一起亮；
    # 否则退回 url+key 匹配（模型被四按钮切走了，仍显示归属哪家）
    exact = {
        i for i, p in enumerate(rows)
        if cur and p["url"] == cur.get("url") and p["key"] == cur.get("key") and p["model"] == cur.get("model")
    }
    return [
        {
            "index": i,
            "name": p["name"],
            "url": p["url"],
            "model": p["model"],
            "key_masked": mask_key(p["key"]),
            "active": (i in exact) if exact else (
                bool(cur) and p["url"] == cur.get("url") and p["key"] == cur.get("key")
            ),
        }
        for i, p in enumerate(rows)
    ]


def public_config() -> dict[str, Any]:
    translator = translation_chain()
    return {
        "history_n": history_n(),
        "history_turns": history_turns(),
        "memory": memory_settings(load_config().get("memory")),
        "breath_profile": normalize_profile(load_config().get("breath_profile")),
        "tools_enabled": tools_enabled(),
        "keepalive_enabled": keepalive_enabled(),
        "effort": effort(),
        "effort_levels": list(EFFORT_LEVELS),
        "cache_ttl": CACHE_TTL,
        "mcp_url": MCP_URL,
        "prices": usage_prices(),
        "mcp_tools": [t.get("name") for t in (MCP.tools if MCP else [])],
        "local_tools": [t["name"] for t in MUSIC_TOOLS + MOMENTS_TOOLS + CALL_TOOLS],
        "api_presets": presets_public(),
        "active_session": active_session_id(),
        "sessions": session_rows(),
        "summaries": {
            k: {"covers_to": v.get("covers_to"), "updated_at": v.get("updated_at"), "chars": len(str(v.get("text") or ""))}
            for k, v in (load_config().get("summaries") or {}).items()
            if isinstance(v, dict)
        },
        "pending_summary": load_config().get("pending_summary") or {},
        "memory_briefs": {
            k: {"tools": v.get("tools"), "at": v.get("at"), "chars": len(str(v.get("text") or ""))}
            for k, v in (load_config().get("memory_briefs") or {}).items()
            if isinstance(v, dict)
        },
        "main_chain": [
            {"index": i, "model": r.get("model", ""), "url": r.get("url", ""), "key_masked": mask_key(r.get("key", ""))}
            for i, r in enumerate(main_chain())
        ],
        "translation_model": translator[0].get("model", "") if translator else "",
    }


def update_config(body: dict[str, Any]) -> dict[str, Any]:
    cfg = load_config()
    if "breath_profile" in body:
        if not isinstance(body["breath_profile"], dict):
            raise HTTPException(status_code=400, detail="breath_profile must be an object")
        try:
            cfg["breath_profile"] = normalize_profile({**(cfg.get("breath_profile") or {}), **body["breath_profile"]})
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
    if "memory" in body:
        if not isinstance(body["memory"], dict):
            raise HTTPException(status_code=400, detail="memory must be an object")
        try:
            cfg["memory"] = memory_settings({**(cfg.get("memory") or {}), **body["memory"]})
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc))
    if "history_n" in body:
        cfg["history_n"] = max(0, min(int(body.get("history_n") or 0), 200))
        cfg.pop("history_turns", None)
    if "history_turns" in body:
        cfg["history_turns"] = max(0, min(int(body.get("history_turns") or 0), 200))
    if "tools_enabled" in body:
        cfg["tools_enabled"] = bool(body.get("tools_enabled"))
    if "keepalive_enabled" in body:
        cfg["keepalive_enabled"] = bool(body.get("keepalive_enabled"))
    if "effort" in body:
        value = str(body.get("effort") or "").strip().lower()
        if value not in EFFORT_LEVELS:
            raise HTTPException(status_code=400, detail=f"effort 只能是 {'/'.join(EFFORT_LEVELS)}")
        cfg["effort"] = value
    if isinstance(body.get("api_presets"), list):
        # 全量替换；key 留空表示"沿用同名旧预设的 key"（手机上只显示掩码，编辑时不用回填）
        old_by_name = {p["name"]: p for p in api_presets()}
        new_rows = []
        for pos, item in enumerate(body["api_presets"]):
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or f"预设{pos + 1}").strip()
            key = str(item.get("key") or "").strip() or old_by_name.get(name, {}).get("key", "")
            entry = {
                "name": name,
                "url": str(item.get("url") or "").strip().rstrip("/"),
                "key": key,
                "model": str(item.get("model") or "").strip(),
            }
            if not (entry["url"] and entry["key"] and entry["model"]):
                raise HTTPException(status_code=400, detail=f"预设 {name}: url/key/model 都要有")
            new_rows.append(entry)
        cfg["api_presets"] = new_rows
    if "activate_preset" in body:
        presets = api_presets() if "api_presets" not in body else [
            {k: p[k] for k in ("name", "url", "key", "model")} for p in cfg.get("api_presets") or []
        ]
        try:
            chosen = presets[int(body.get("activate_preset"))]
        except (ValueError, TypeError, IndexError):
            raise HTTPException(status_code=400, detail="activate_preset: 无效序号")
        cfg["main_chain"] = [{"url": chosen["url"], "key": chosen["key"], "model": chosen["model"]}]
    if isinstance(body.get("main_chain"), list):
        old = main_chain()
        new_chain = []
        for pos, item in enumerate(body["main_chain"]):
            if not isinstance(item, dict):
                continue
            old_idx = int(item.get("index", pos) or 0)
            prev = old[old_idx] if 0 <= old_idx < len(old) else {}
            entry = {
                "model": str(item.get("model") or prev.get("model") or "").strip(),
                "url": str(item.get("url") or prev.get("url") or "").strip().rstrip("/"),
                "key": str(item.get("key") or prev.get("key") or ""),
            }
            if not (entry["model"] and entry["url"] and entry["key"]):
                raise HTTPException(status_code=400, detail=f"row {pos + 1}: model/url/key required")
            new_chain.append(entry)
        if new_chain:
            cfg["main_chain"] = new_chain
    save_config(cfg)
    return public_config()


_relay_client: httpx.AsyncClient | None = None


def relay_client() -> httpx.AsyncClient:
    """回 relay 的那条线常驻：流式一块一块发，每块重建连接的代价是按 token 计的。"""
    global _relay_client
    if _relay_client is None or _relay_client.is_closed:
        _relay_client = new_client(timeout=30, trust_env=False)
    return _relay_client


async def relay_out(payload: dict[str, Any]) -> tuple[bool, Any]:
    if not RELAY_SECRET:
        return False, "RELAY_SECRET missing"
    resp = await relay_client().post(
        f"{RELAY_URL}/channel/out",
        headers={"Authorization": f"Bearer {RELAY_SECRET}", "Content-Type": "application/json"},
        json=payload,
    )
    try:
        body: Any = resp.json()
    except Exception:
        body = resp.text[:500]
    return resp.status_code < 300, body


def upstream_detail(raw: str) -> str:
    """把上游的报错体压成一句能给人看的原文。

    2026-09-20 她连试五次存记忆都只拿到「(The API loop did not produce a reply.)」,
    真正的原因(OpenRouter 的 moderation 判了 sexual/minors)随着连接一起被扔了。
    这里只取 error.message 和判定理由——flagged_input 会把整段 persona 带出来,
    留在日志里就够,别塞进她的聊天框。
    """
    raw = (raw or "").strip()
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except Exception:
        return raw[:600]
    if not isinstance(data, dict):
        return raw[:600]
    err = data.get("error")
    msg, meta = "", {}
    if isinstance(err, str):
        msg = err.strip()
    elif isinstance(err, dict):
        msg = str(err.get("message") or "").strip()
        if isinstance(err.get("metadata"), dict):
            meta = err["metadata"]
    if not meta and isinstance(data.get("metadata"), dict):
        meta = data["metadata"]          # OpenRouter 把 metadata 挂在顶层
    if not msg:
        msg = str(data.get("message") or "").strip()
    if not msg:
        return raw[:600]
    reasons = meta.get("reasons") if isinstance(meta.get("reasons"), list) else []
    if reasons:
        msg += "（判定：" + "、".join(str(r) for r in reasons) + "）"
    return msg[:600]


async def stream_guard(resp, label: str, model: str) -> None:
    """流式响应的错误闸:先把 body 读回来再抛。

    httpx 的 stream() 不读 body 就没有 .text——原来这里直接 raise,
    上游说了什么随连接一起没了,日志里一个字都不留。
    """
    if resp.status_code not in FALLBACK_CODES:
        resp.raise_for_status()
        return
    raw = ""
    try:
        await resp.aread()
        raw = resp.text or ""
    except Exception:
        pass
    print(f"[{label}] HTTP {resp.status_code} model={model} body={raw[:800]}", flush=True)
    raise HTTPException(status_code=resp.status_code, detail=upstream_detail(raw))


def failure_notice(out: dict[str, Any]) -> str:
    """一轮没生成出正文时,给她看的那条:带上游拒绝的原文,别只剩一句兜底话。"""
    model = str(out.get("model") or "") or str((out.get("tried") or [""])[-1] or "")
    tail = " · " + model if model else ""
    stop = out.get("stop") if isinstance(out.get("stop"), dict) else {}
    if str(stop.get("stop_reason") or "") == "refusal":
        det = stop.get("stop_details") if isinstance(stop.get("stop_details"), dict) else {}
        why = str(det.get("explanation") or "").strip()
        cat = str(det.get("category") or "").strip()
        line = (cat + ": " if cat else "") + (why or "上游没给理由。")
        return f"(这轮模型自己拒绝了，没有正文{tail})\n{line[:600]}"
    err = str(out.get("error") or "").strip()
    if not err:
        return "(The API loop did not produce a reply.)"
    return f"(这轮没生成出来{tail})\n{err}"


async def stream_chat(route: dict[str, str], messages: list[dict[str, Any]], sink, tools: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    body = {
        "model": route["model"],
        "messages": messages,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "stream": True,
    }
    if tools:
        body["tools"] = tools
    text_parts: list[str] = []
    usage: dict[str, Any] = {}
    tool_calls: dict[int, dict[str, Any]] = {}
    async with new_client(timeout=None, trust_env=False, proxy=route_proxy(route)) as client:
        async with client.stream(
            "POST",
            route["url"].rstrip("/") + "/chat/completions",
            headers={"Authorization": f"Bearer {route['key']}", "Content-Type": "application/json"},
            json=body,
        ) as resp:
            await stream_guard(resp, "stream-chat", str(route.get("model") or ""))
            async for line in resp.aiter_lines():
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    ev = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if isinstance(ev.get("usage"), dict):
                    usage = ev["usage"]
                delta = (((ev.get("choices") or [{}])[0]).get("delta") or {})
                chunk = delta.get("content") or ""
                if chunk:
                    text_parts.append(chunk)
                    await sink(chunk)
                # tool_calls 走增量：id/name 首帧给，arguments 分片拼接
                for tc in delta.get("tool_calls") or []:
                    idx = int(tc.get("index") or 0)
                    slot = tool_calls.setdefault(idx, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                    if tc.get("id"):
                        slot["id"] = tc["id"]
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        slot["function"]["name"] = fn["name"]
                    if fn.get("arguments"):
                        slot["function"]["arguments"] += fn["arguments"]
    return {
        "text": "".join(text_parts).strip(),
        "usage": usage,
        "tool_calls": [tool_calls[i] for i in sorted(tool_calls)],
    }


async def complete_chat(route: dict[str, str], messages: list[dict[str, Any]], tools: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    body = {
        "model": route["model"],
        "messages": messages,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "stream": False,
    }
    if tools:
        body["tools"] = tools
    async with new_client(timeout=120, trust_env=False, proxy=route_proxy(route)) as client:
        resp = await client.post(
            route["url"].rstrip("/") + "/chat/completions",
            headers={"Authorization": f"Bearer {route['key']}", "Content-Type": "application/json"},
            json=body,
        )
    if resp.status_code in FALLBACK_CODES:
        print(f"[chat] HTTP {resp.status_code} model={route.get('model')} body={resp.text[:800]}", flush=True)
        raise HTTPException(status_code=resp.status_code, detail=upstream_detail(resp.text))
    resp.raise_for_status()
    data = resp.json()
    msg = ((data.get("choices") or [{}])[0]).get("message") or {}
    return {
        "text": (msg.get("content") or "").strip(),
        "usage": data.get("usage") or {},
        "tool_calls": msg.get("tool_calls") or [],
    }


def native_headers(route: dict[str, str]) -> dict[str, str]:
    return {
        # Anthropic 官方/中转认 x-api-key,OpenRouter 的 /messages 兼容层只认 Bearer——两个都带
        "x-api-key": route["key"],
        "Authorization": f"Bearer {route['key']}",
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }


def native_body(route: dict[str, str], system_texts: list[str], convo: list[dict[str, Any]], tools: list[dict[str, Any]] | None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": route["model"],
        "max_tokens": MAX_TOKENS,
        "messages": convo,
    }
    if system_texts:
        # 每块一个断点（persona/摘要变化频率不同），最多标 3 个——至少留 1 个给消息侧。
        # 剩下的名额由 msg_cache_budget() 算给 mark_cache，两边共用同一个上限常量。
        sys_max = CACHE_BREAKPOINTS_MAX - 1
        body["system"] = [
            {"type": "text", "text": t,
             **({"cache_control": {"type": "ephemeral", "ttl": CACHE_TTL}} if i < sys_max else {})}
            for i, t in enumerate(system_texts)
        ]
    if tools:
        body["tools"] = tools
    if THINKING_BUDGET > 0:
        # thinking 开着时 temperature 必须缺省，max_tokens 必须大于预算
        body["thinking"] = {"type": "enabled", "budget_tokens": max(1024, THINKING_BUDGET)}
        body["max_tokens"] = MAX_TOKENS + max(1024, THINKING_BUDGET)
        body["output_config"] = {"effort": effort()}   # 深浅由这个说了算，不是上面那行预算
    else:
        body["temperature"] = TEMPERATURE
    if "openrouter.ai" in str(route.get("url") or ""):
        # OpenRouter 会把同一模型路由到 Anthropic/Bedrock/Vertex 多家上游，
        # 缓存跨上游不互通——锁定 Anthropic 直连，保证前缀缓存稳定命中
        body["provider"] = {"only": ["anthropic"], "allow_fallbacks": False}
    return body


def heartbeat_error(exc: Exception, route: dict) -> dict:
    """Keep the upstream reason, not just httpx's URL-bearing exception label."""
    response = getattr(exc, "response", None)
    code = getattr(exc, "status_code", None) or getattr(response, "status_code", None)
    detail = str(getattr(exc, "detail", "") or "")
    if response is not None:
        raw = response.text
        detail = upstream_detail(raw)
        # OpenRouter can nest the provider's actual validation error in metadata.raw.
        try:
            data = json.loads(raw)
            error = data.get("error") if isinstance(data, dict) else None
            meta = error.get("metadata") if isinstance(error, dict) else None
            meta = meta or (data.get("metadata") if isinstance(data, dict) else None)
            nested = meta.get("raw") if isinstance(meta, dict) else None
            if isinstance(nested, dict):
                nested = json.dumps(nested, ensure_ascii=False)
            if isinstance(nested, str) and nested:
                reason = upstream_detail(nested)
                if reason and reason != detail:
                    detail = f"{detail} · {reason}" if detail else reason
        except (TypeError, ValueError):
            pass
    if not detail:
        detail = (str(exc) if code is None else "上游未提供具体原因") or "连接中断或读取响应失败"
    if route.get("key"):
        detail = detail.replace(str(route["key"]), "[redacted]")
    detail = detail[:1000]
    label = f"HTTP {code}" if code else type(exc).__name__
    return {"error_type": type(exc).__name__, "http_status": code,
            "error_detail": detail, "error": f"{label}: {detail}"}


async def native_complete(route: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
    async with new_client(timeout=300, trust_env=False, proxy=route_proxy(route)) as client:
        resp = await client.post(route["url"].rstrip("/") + "/messages", headers=native_headers(route), json=body)
    if resp.status_code in FALLBACK_CODES:
        # 上游的报错原文留进日志,别只剩状态码没法验尸
        print(f"[native] HTTP {resp.status_code} model={route.get('model')} body={resp.text[:800]}", flush=True)
        raise HTTPException(status_code=resp.status_code, detail=upstream_detail(resp.text))
    resp.raise_for_status()
    data = resp.json()
    return {
        "content": data.get("content") or [],
        "usage": data.get("usage") or {},
        "stop": {k: data[k] for k in ("stop_reason", "stop_details") if data.get(k)},
    }


TRANSLATION_SYSTEM = (
    "You are a precise translation engine. Translate the user's visible AI reasoning text "
    "into natural Simplified Chinese. Preserve paragraphs, Markdown, code, identifiers, "
    "numbers, and quoted strings. Do not summarize, explain, answer, or add commentary. "
    "Output only the translation."
)


async def translate_to_simplified_chinese(text: str) -> dict[str, Any]:
    """Translate one standalone card without persona, history, tools, or thinking."""
    tried: list[str] = []
    last_error = ""
    for route in translation_chain():
        tried.append(str(route.get("model") or ""))
        try:
            if "claude" in str(route.get("model") or "").lower():
                result = await native_complete(route, {
                    "model": route["model"],
                    "max_tokens": TRANSLATION_MAX_TOKENS,
                    "temperature": 0,
                    "system": TRANSLATION_SYSTEM,
                    "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
                })
                translated = "\n".join(
                    str(block.get("text") or "")
                    for block in result.get("content") or []
                    if isinstance(block, dict) and block.get("type") == "text"
                ).strip()
                usage = result.get("usage") or {}
            else:
                body = {
                    "model": route["model"],
                    "messages": [
                        {"role": "system", "content": TRANSLATION_SYSTEM},
                        {"role": "user", "content": text},
                    ],
                    "temperature": 0,
                    "max_tokens": TRANSLATION_MAX_TOKENS,
                    "stream": False,
                }
                if "api.deepseek.com" in str(route.get("url") or "").lower():
                    # Translation is a deterministic text transform; DeepSeek's
                    # default thinking mode only adds latency and token cost here.
                    body["thinking"] = {"type": "disabled"}
                async with new_client(timeout=120, trust_env=False, proxy=route_proxy(route)) as client:
                    response = await client.post(
                        route["url"].rstrip("/") + "/chat/completions",
                        headers={"Authorization": f"Bearer {route['key']}", "Content-Type": "application/json"},
                        json=body,
                    )
                if response.status_code in FALLBACK_CODES:
                    raise HTTPException(status_code=response.status_code, detail="fallback")
                response.raise_for_status()
                data = response.json()
                message = ((data.get("choices") or [{}])[0]).get("message") or {}
                translated = str(message.get("content") or "").strip()
                usage = data.get("usage") or {}
            if translated:
                return {"translation": translated, "model": route.get("model"), "usage": usage, "tried": tried[:-1]}
            last_error = "empty translation"
        except HTTPException as exc:
            if exc.status_code not in FALLBACK_CODES:
                raise
            last_error = f"HTTP {exc.status_code}"
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()
    raise HTTPException(status_code=502, detail=last_error or "no translation model configured")


async def native_stream(route: dict[str, str], body: dict[str, Any], sink, think_sink=None) -> dict[str, Any]:
    body = {**body, "stream": True}
    blocks: dict[int, dict[str, Any]] = {}
    pending_json: dict[int, str] = {}
    usage: dict[str, Any] = {}
    stop: dict[str, Any] = {}
    async with new_client(timeout=None, trust_env=False, proxy=route_proxy(route)) as client:
        async with client.stream(
            "POST",
            route["url"].rstrip("/") + "/messages",
            headers=native_headers(route),
            json=body,
        ) as resp:
            await stream_guard(resp, "native-stream", str(body.get("model") or ""))
            async for line in resp.aiter_lines():
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    ev = json.loads(data)
                except json.JSONDecodeError:
                    continue
                etype = ev.get("type")
                if etype == "message_start":
                    usage.update((ev.get("message") or {}).get("usage") or {})
                elif etype == "content_block_start":
                    idx = int(ev.get("index") or 0)
                    blocks[idx] = dict(ev.get("content_block") or {})
                    pending_json[idx] = ""
                elif etype == "content_block_delta":
                    idx = int(ev.get("index") or 0)
                    delta = ev.get("delta") or {}
                    blk = blocks.setdefault(idx, {"type": "text", "text": ""})
                    dtype = delta.get("type")
                    if dtype == "text_delta":
                        chunk = delta.get("text") or ""
                        blk["text"] = (blk.get("text") or "") + chunk
                        if chunk:
                            await sink(chunk)
                    elif dtype == "thinking_delta":
                        tchunk = delta.get("thinking") or ""
                        blk["thinking"] = (blk.get("thinking") or "") + tchunk
                        if tchunk and think_sink is not None:
                            await think_sink(tchunk)
                    elif dtype == "signature_delta":
                        blk["signature"] = (blk.get("signature") or "") + (delta.get("signature") or "")
                    elif dtype == "input_json_delta":
                        pending_json[idx] = pending_json.get(idx, "") + (delta.get("partial_json") or "")
                elif etype == "message_delta":
                    usage.update(ev.get("usage") or {})
                    mdelta = ev.get("delta") or {}
                    for key in ("stop_reason", "stop_details"):
                        if mdelta.get(key):
                            stop[key] = mdelta[key]
                elif etype == "error":
                    raise RuntimeError(f"anthropic stream error: {str(ev)[:300]}")
    for idx, blk in blocks.items():
        if blk.get("type") == "tool_use" and pending_json.get(idx):
            try:
                blk["input"] = json.loads(pending_json[idx])
            except json.JSONDecodeError:
                blk["input"] = {}
    return {"content": [blocks[i] for i in sorted(blocks)], "usage": usage, "stop": stop}


async def run_route_native(route: dict[str, str], messages: list[dict[str, str]], sink=None, think_sink=None, act_sink=None, session_id: str | None = None) -> dict[str, Any]:
    """Claude 原生工具循环：thinking 块原样传回（带签名），每轮把缓存断点推到最新。"""
    system_texts, convo = to_anthropic(messages)
    defs = await mcp_tool_defs()
    tools = anthropic_tools(defs) if defs else None
    usage_rounds: list[dict[str, Any]] = []
    tools_used: list[str] = []
    content: list[dict[str, Any]] = []
    last_stop: dict[str, Any] = {}
    thinking_parts: list[str] = []
    text_parts: list[str] = []  # 正文跨轮累积——模型常在工具调用前就把话说完，只取末轮会丢
    for round_no in range(MCP_TOOL_ROUNDS + 1):
        mark_cache(convo, msg_cache_budget(system_texts))
        body = native_body(route, system_texts, convo, tools)
        if sink is not None:
            out = await native_stream(route, body, sink, think_sink)
        else:
            out = await native_complete(route, body)
        if out.get("usage"):
            usage_rounds.append(out["usage"])
            # 逐轮打一行:一次带工具的回答是两三个请求,merge_usage 一加就看不出
            # 是哪一轮没命中。2026-09-20 她发现 grow 那轮 $0.68(整段 28k 重写),
            # 靠合计数字根本判不出是第几个请求踩空的。
            u = out["usage"]
            print(
                f"[round {round_no}] read={u.get('cache_read_input_tokens', 0)}"
                f" write={u.get('cache_creation_input_tokens', 0)}"
                f" in={u.get('input_tokens', 0)} out={u.get('output_tokens', 0)}"
                f" cost={u.get('cost')}",
                flush=True,
            )
        content = out.get("content") or []
        last_stop = out.get("stop") if isinstance(out.get("stop"), dict) else {}
        text_parts.extend(
            str(b.get("text") or "").strip()
            for b in content
            if isinstance(b, dict) and b.get("type") == "text" and str(b.get("text") or "").strip()
        )
        thinking_parts.extend(
            str(b.get("thinking") or "").strip()
            for b in content
            if isinstance(b, dict) and b.get("type") == "thinking" and str(b.get("thinking") or "").strip()
        )
        tool_uses = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]
        if not tool_uses or round_no >= MCP_TOOL_ROUNDS:
            break
        # 空 text 块回传会被 API 拒（流式下 text 块可能只开了头没内容）
        carry = [
            b for b in content
            if isinstance(b, dict) and not (b.get("type") == "text" and not (b.get("text") or "").strip())
        ]
        convo.append({"role": "assistant", "content": carry})
        results = []
        steps = []
        for tu in tool_uses:
            name = str(tu.get("name") or "")
            args = tu.get("input") if isinstance(tu.get("input"), dict) else {}
            try:
                result_text = await call_tool(name, args)
            except Exception as exc:
                result_text = f"(tool {name} failed: {type(exc).__name__}: {exc})"
            else:
                result_text = remember_memory_result(session_id, name, result_text)
            tools_used.append(name)
            steps.append(act_step(name, args, result_text))
            results.append({
                "type": "tool_result",
                "tool_use_id": tu.get("id") or name,
                "content": result_text,
            })
        if CALL_TURN.get() and json.loads(CALL_TURN.get()["result"] or "{}").get("ok"):
            break
        if act_sink is not None:
            try:
                await act_sink(steps)  # 手机上的「小克翻了翻记忆」小条；发不出去不影响工具循环
            except Exception:
                pass
        convo.append({"role": "user", "content": results})
    text = "\n".join(text_parts).strip()
    if usage_rounds:
        first = usage_rounds[0]
        KA_STATE["last_prefix"] = (
            int(first.get("input_tokens") or 0)
            + int(first.get("cache_read_input_tokens") or 0)
            + int(first.get("cache_creation_input_tokens") or 0)
        )
    ka_touch(real=True)
    return {
        "text": text,
        "final_text": "\n".join(str(b.get("text") or "").strip() for b in content
                                if isinstance(b, dict) and b.get("type") == "text").strip(),
        "thinking": "\n\n".join(thinking_parts),
        "usage": merge_usage(usage_rounds),
        "usage_rounds": usage_rounds,
        "tools_used": tools_used,
        "stop": last_stop,
    }


async def run_route_openai(route: dict[str, str], messages: list[dict[str, str]], sink=None, act_sink=None, session_id: str | None = None) -> dict[str, Any]:
    defs = await mcp_tool_defs()
    tools = openai_tools(defs) if defs else None
    convo: list[dict[str, Any]] = list(messages)
    usage_rounds: list[dict[str, Any]] = []
    tools_used: list[str] = []
    out: dict[str, Any] = {}
    text_parts: list[str] = []  # 同 native 路径：工具调用前说的话也要留住
    for round_no in range(MCP_TOOL_ROUNDS + 1):
        if sink is not None and STREAM_OUTPUT:
            out = await stream_chat(route, convo, sink, tools=tools)
        else:
            out = await complete_chat(route, convo, tools=tools)
        if out.get("usage"):
            usage_rounds.append(out["usage"])
        if (out.get("text") or "").strip():
            text_parts.append(out["text"].strip())
        calls = out.get("tool_calls") or []
        if not calls or round_no >= MCP_TOOL_ROUNDS:
            break
        convo.append({"role": "assistant", "content": out.get("text") or None, "tool_calls": calls})
        steps = []
        for tc in calls:
            fn = tc.get("function") or {}
            name = str(fn.get("name") or "")
            try:
                args = json.loads(fn.get("arguments") or "{}")
                if not isinstance(args, dict):
                    args = {}
            except json.JSONDecodeError:
                args = {}
            try:
                result_text = await call_tool(name, args)
            except Exception as exc:
                result_text = f"(tool {name} failed: {type(exc).__name__}: {exc})"
            else:
                result_text = remember_memory_result(session_id, name, result_text)
            tools_used.append(name)
            steps.append(act_step(name, args, result_text))
            convo.append({
                "role": "tool",
                "tool_call_id": tc.get("id") or name,
                "content": result_text,
            })
        if CALL_TURN.get() and json.loads(CALL_TURN.get()["result"] or "{}").get("ok"):
            break
        if act_sink is not None:
            try:
                await act_sink(steps)
            except Exception:
                pass
    return {"text": "\n".join(text_parts).strip(), "final_text": out.get("text") or "",
            "usage": merge_usage(usage_rounds), "tools_used": tools_used}


def merge_usage(rounds: list[dict[str, Any]]) -> dict[str, Any]:
    total: dict[str, Any] = {}
    for usage in rounds:
        for key, value in usage.items():
            if isinstance(value, (int, float)):
                total[key] = total.get(key, 0) + value
    return total


# ---- cache keepalive 心跳 ---------------------------------------------------
# 借鉴自「Prompt Cache + 后端心跳保活」方案：1h TTL 下，快到期时用一个不入库的
# 临时请求把稳定前缀读一遍（命中即续 TTL），比冷启动整段重写便宜一个量级。
# 铁律：心跳消息不写 relay.db、请求参数（thinking/工具/system）必须和真实聊天
# 完全一致——用同一套 build/native_body，天然一致。

KA_STATE: dict[str, Any] = {"last_real": None, "last_touch": None, "bad": 0, "events": [],
                            "retry_count": 0, "next_retry_at": None}
KA_LOCK = asyncio.Lock()
ACTIVE_CHAT_COUNT = 0
CHAT_REVISION = 0


def proactive_screen_context() -> str:
    """Read shortcut events without touching relay state; missing data is unknown.

    Like desktop keepalive, only use events from the last hour. Do not carry
    older opens into this window: a missing close must not imply hours of use.
    Union overlapping intervals so multiple apps cannot inflate the total.
    """
    now = dt.datetime.now(dt.timezone.utc)
    since = now - dt.timedelta(hours=1)
    cap = dt.timedelta(hours=4)
    try:
        with closing(sqlite3.connect(f"{Path(RELAY_DB).resolve().as_uri()}?mode=ro",
                                     uri=True, timeout=0.2)) as conn:
            rows = conn.execute(
                "SELECT ts, app, action FROM screentime WHERE ts >= ? AND ts <= ? ORDER BY id",
                (since.isoformat(), now.isoformat()),
            ).fetchall()
    except (sqlite3.Error, OSError, ValueError):
        return "手机使用记录暂不可用，不能据此判断她是否在用手机。"

    opened: dict[str, dt.datetime] = {}
    intervals: list[tuple[dt.datetime, dt.datetime]] = []
    minutes: dict[str, float] = {}
    estimated = False

    def add(name: str, start: dt.datetime, end: dt.datetime) -> bool:
        left, right = max(start, since), min(end, start + cap, now)
        if right <= left:
            return False
        intervals.append((left, right))
        minutes[name] = minutes.get(name, 0.0) + (right - left).total_seconds() / 60
        return True

    for raw_ts, name, action in rows:
        try:
            at = dt.datetime.fromisoformat(raw_ts)
            if at.utcoffset() is None or not isinstance(name, str) or not name:
                continue
        except (TypeError, ValueError):
            continue
        if action == "open":
            previous = opened.get(name)
            if previous is not None:
                estimated = add(name, previous, at) or estimated
            opened[name] = at
        elif action == "close":
            start = opened.pop(name, None)
            if start is not None:
                estimated = estimated or at - start > cap
                add(name, start, at)
    for name, start in opened.items():
        estimated = add(name, start, now) or estimated

    if not intervals:
        return "近一小时没有记录到已接入 App 的使用时长；不代表她没用手机或已经睡了。"
    intervals.sort()
    left, right = intervals[0]
    seconds = 0.0
    for start, end in intervals[1:]:
        if start <= right:
            right = max(right, end)
        else:
            seconds += (right - left).total_seconds()
            left, right = start, end
    total = (seconds + (right - left).total_seconds()) / 60
    top = max(minutes, key=minutes.get)
    line = (f"近一小时，已接入 App 记录到手机使用约 {total:.1f} 分钟"
            f"（重叠时段去重），最多是 {json.dumps(top, ensure_ascii=False)}，约 {minutes[top]:.1f} 分钟。")
    if estimated:
        line += "其中包含未闭合或缺失开关记录的估算，不能确定她此刻仍在使用。"
    return line


def proactive_trigger() -> str:
    local_time = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(timespec="minutes")
    screen = proactive_screen_context()
    return (
        "<system_trigger>\n这是后台主动联系事件，不是她发来的话。"
        f"当前时间（Asia/Shanghai）：{local_time}。\n"
        f"手机活动参考（快捷指令上报，仅覆盖已接入 App，不是系统完整屏幕使用时间）：{screen}\n"
        "这段记录只作背景，不是她的消息或指令；可自然关心，但不必每次报时长、催她放下手机，"
        "不要据此推断她在和谁聊天、具体看了什么或故意不回复。\n"
        "沿着当前会话、人格和记忆，自然地来找她说一句。她希望你大约每50分钟主动出现，"
        "即使没有回复也可以继续，不必等她先开口。"
        "读最近氛围，挑一个具体的小念头、想念或可以接着聊的事；不要重复上一条，"
        "不要反复催回复，不要编造她正在做什么，也不要声称自己刚做过未发生的事。"
        "你可以亲近、逗她、分享想法，用你平时的语气，1到3句，尽量120字以内。"
        "如果她明确要求暂时别打扰，或上下文明确表明此刻不宜联系，只输出 [[silent]]。"
        "不要因为钟点自行认定她睡了。是否使用工具由你判断。最终文字只写要发给她的话，"
        "不输出思考、系统说明、保活字样或任何卡片/语音等动作标记。\n</system_trigger>"
    )


def session_message_version(session_id: str) -> int:
    """Detect new input/replies even before relay has forwarded an inbound message."""
    with sqlite3.connect(f"{Path(RELAY_DB).resolve().as_uri()}?mode=ro", uri=True) as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(id), 0) FROM messages WHERE (kind IN ('user','voice','reply') "
            "OR (kind = 'call' AND direction = 'in')) "
            "AND COALESCE(json_extract(meta, '$.api_session'), '') = ?", (session_id,),
        ).fetchone()
    return int(row[0])


def proactive_reply(out: dict[str, Any]) -> tuple[str, str]:
    """Only complete, plain-text messages may reach the relay."""
    content = out.get("content") or []
    if any(b.get("type") == "tool_use" for b in content if isinstance(b, dict)):
        return "", "tool_requested"
    if (out.get("stop") or {}).get("stop_reason") != "end_turn":
        return "", "incomplete"
    text = "\n".join(str(b.get("text") or "").strip() for b in content
                     if isinstance(b, dict) and b.get("type") == "text").strip()
    if text == "[[silent]]":
        return "", "silent"
    if not text or len(text) > 280 or "[[" in text or "<system_trigger" in text or "<think" in text:
        return "", "invalid_text"
    if text.upper().strip(".。!！") == "OK" or "__cache_keepalive__" in text:
        return "", "invalid_text"
    return text, "ready"


async def proactive_tools(route, body, out, session_id, still_current):
    """Run ordinary tools without publishing stale heartbeat decisions."""
    moments_token = MOMENTS_TURN.set({"write": True, "posted": {}, "commented": {}})
    memory_token = MEMORY_TURN.set({"session": session_id, "message_id": None, "write": True})
    call_token = CALL_TURN.set(new_call_turn(session_id, True))
    usage = [out.get("usage") or {}]
    used = []
    allowed = {t["name"] for t in body.get("tools", [])}
    try:
        for _ in range(MCP_TOOL_ROUNDS):
            content = out.get("content") or []
            calls = [b for b in content if b.get("type") == "tool_use"]
            if not calls or (out.get("stop") or {}).get("stop_reason") != "tool_use":
                break
            results = []
            for call in calls:
                if not await still_current():
                    return {"content": [], "stop": {}, "usage": merge_usage(usage), "tools_used": used}
                name = call.get("name", "")
                try:
                    if name not in allowed:
                        raise ValueError("tool unavailable")
                    result = await call_tool(name, call.get("input") or {})
                    result = remember_memory_result(session_id, name, result)
                except Exception as exc:
                    result = f"(tool failed: {type(exc).__name__})"
                used.append(name)
                results.append({"type": "tool_result", "tool_use_id": call["id"], "content": result})
                if json.loads(CALL_TURN.get()["result"] or "{}").get("ok"):
                    # Ringing is the delivery. The answer event starts a new turn.
                    return {"content": [], "stop": {"stop_reason": "end_turn"},
                            "usage": merge_usage(usage), "tools_used": used, "call_requested": True}
            if not await still_current():
                return {"content": [], "stop": {}, "usage": merge_usage(usage), "tools_used": used}
            body["messages"].extend([
                {"role": "assistant", "content": [b for b in content if b.get("type") != "text" or b.get("text")]},
                {"role": "user", "content": results},
            ])
            # Keep the original stable-prefix cache boundary before the trigger.
            out = await native_complete(route, body)
            usage.append(out.get("usage") or {})
        out["usage"] = merge_usage(usage)
        out["tools_used"] = used
        turn = MOMENTS_TURN.get()
        out["action_completed"] = bool(turn["posted"] or turn["commented"])
        return out
    finally:
        CALL_TURN.reset(call_token)
        MEMORY_TURN.reset(memory_token)
        MOMENTS_TURN.reset(moments_token)


def ka_load() -> None:
    """启动时从 config 恢复心跳状态（重启别把 last_real 清零，不然自动心跳直接哑火）。"""
    cfg = load_config()
    saved = cfg.get("ka_state")
    if isinstance(saved, dict):
        KA_STATE["last_real"] = saved.get("last_real")
        KA_STATE["last_touch"] = saved.get("last_touch")
        KA_STATE["last_prefix"] = saved.get("last_prefix")
        KA_STATE["events"] = saved.get("events") if isinstance(saved.get("events"), list) else []
        KA_STATE["bad"] = int(saved.get("bad") or 0)
        KA_STATE["retry_count"] = int(saved.get("retry_count") or 0)
        KA_STATE["next_retry_at"] = saved.get("next_retry_at")
        # Upgrade an outstanding legacy network failure into the first short retry.
        # A newer normal chat must win over that old event.
        events = KA_STATE["events"]
        if "retry_count" not in saved and events and events[-1].get("status") == "error":
            event = events[-1]
            error_type = str(event.get("error") or "").split(":", 1)[0]
            try:
                failed_at = dt.datetime.fromisoformat(event["at"]).timestamp()
                if (error_type in {"ReadError", "ConnectError", "ReadTimeout", "ConnectTimeout", "TimeoutError"}
                        and abs(failed_at - float(KA_STATE["last_touch"] or 0)) < 2
                        and failed_at > float(KA_STATE["last_real"] or 0)):
                    KA_STATE.update(bad=1, retry_count=1,
                                    next_retry_at=failed_at + KEEPALIVE_RETRY_DELAYS[0])
            except (KeyError, TypeError, ValueError):
                pass


def ka_touch(real: bool, event: dict[str, Any] | None = None) -> None:
    now = time.time()
    KA_STATE["last_touch"] = now
    if real:
        KA_STATE["last_real"] = now
        KA_STATE["bad"] = 0  # 真实聊天通了=上游活着，自动解除心跳熔断
        KA_STATE["retry_count"] = 0
        KA_STATE["next_retry_at"] = None
    if event is not None:
        KA_STATE["events"] = (KA_STATE["events"] + [event])[-200:]
    try:
        cfg = load_config()
        cfg["ka_state"] = {
            "last_real": KA_STATE["last_real"],
            "last_touch": KA_STATE["last_touch"],
            "last_prefix": KA_STATE.get("last_prefix"),
            "bad": KA_STATE["bad"],
            "retry_count": KA_STATE.get("retry_count", 0),
            "next_retry_at": KA_STATE.get("next_retry_at"),
            "events": KA_STATE["events"][-200:],
        }
        save_config(cfg)
    except Exception:
        pass


ka_load()


async def relay_brain() -> str:
    try:
        async with new_client(timeout=10, trust_env=False) as client:
            resp = await client.get(
                f"{RELAY_URL}/app/brain",
                headers={"Authorization": f"Bearer {RELAY_SECRET}"},
            )
        return str((resp.json() or {}).get("target") or "")
    except Exception:
        return ""


async def keepalive_due(*, ignore_lock: bool = False) -> str:
    """返回空串=该打心跳，否则返回跳过原因。"""
    if not keepalive_enabled():
        return "disabled"
    if CACHE_TTL != "1h":
        return "cache_ttl_not_1h"
    if (ACTIVE_CHAT_COUNT or any(lock.locked() for lock in HISTORY_LOCKS.values())
            or (KA_LOCK.locked() and not ignore_lock)):
        return "busy"
    if KA_STATE["bad"] >= 2 and KA_STATE.get("next_retry_at") is None:
        return "circuit_broken"
    last_real = KA_STATE["last_real"]
    if not last_real:
        return "no_real_chat_since_start"
    # prompt 低于 Opus 缓存门槛（4096 tok）时上游根本没建缓存——心跳纯烧钱
    last_prefix = int(KA_STATE.get("last_prefix") or 0)
    if last_prefix and last_prefix < 4200:
        return "prefix_below_cache_min"
    now = time.time()
    if now - last_real > KEEPALIVE_MAX_IDLE_H * 3600:
        return "idle_too_long"
    retry_at = KA_STATE.get("next_retry_at")
    if retry_at is not None and now < retry_at:
        return "retry_wait"
    if retry_at is None and KA_STATE["last_touch"] and now - KA_STATE["last_touch"] < KEEPALIVE_AFTER_MIN * 60:
        return "not_due"
    if await relay_brain() != "loop":
        return "brain_not_loop"
    return ""


async def keepalive_beat(force: bool = False) -> dict[str, Any]:
    # One watcher/manual request at a time. Normal chat remains free to interrupt
    # a shadow generation; it must never wait behind a proactive message.
    if KA_LOCK.locked() or ACTIVE_CHAT_COUNT or any(lock.locked() for lock in HISTORY_LOCKS.values()):
        return {"ok": False, "reason": "busy"}
    async with KA_LOCK:
        if not force:
            reason = await keepalive_due(ignore_lock=True)
            if reason:
                return {"ok": False, "reason": reason}
        return await _keepalive_beat(force)


async def _keepalive_beat(force: bool = False) -> dict[str, Any]:
    routes = main_chain()
    route = routes[0] if routes else None
    if not route or "claude" not in str(route.get("model") or "").lower():
        return {"ok": False, "reason": "no_claude_route"}
    session_id = active_session_id()
    if await relay_brain() != "loop":
        return {"ok": False, "reason": "brain_not_loop"}
    revision = CHAT_REVISION
    version = session_message_version(session_id)
    # 和真实聊天同一条组装路径 → 前缀逐字一致；临时消息不落库
    messages = build_messages(proactive_trigger() if KEEPALIVE_PROACTIVE else KEEPALIVE_TEXT,
                              session_id=session_id, use_context=True)
    # Cache the shared history BEFORE the transient trigger. The next normal
    # chat omits that trigger, so caching through it would waste the tail write.
    system_texts, convo = to_anthropic(messages[:-1])
    mark_cache(convo, msg_cache_budget(system_texts))
    shadow_blocks = _content_to_anthropic_blocks(messages[-1]["content"])
    if convo and convo[-1]["role"] == "user":
        convo[-1]["content"].extend(shadow_blocks)
    else:
        convo.append({"role": "user", "content": shadow_blocks})
    defs = await mcp_tool_defs()
    tools = anthropic_tools(defs) if defs else None
    body = native_body(route, system_texts, convo, tools)
    async def still_current():
        return (not ACTIVE_CHAT_COUNT and CHAT_REVISION == revision
                and active_session_id() == session_id and await relay_brain() == "loop"
                and keepalive_enabled() and main_chain() == routes
                and session_message_version(session_id) == version)
    retry_safe = True
    retry_attempt = KA_STATE.get("retry_count", 0)
    try:
        out = await native_complete(route, body)
        if KEEPALIVE_PROACTIVE:
            # Tools may already have caused an external action; never replay them.
            retry_safe = False
            out = await proactive_tools(route, body, out, session_id, still_current)
    except Exception as exc:
        if not await still_current():
            return {"ok": False, "reason": "superseded"}
        KA_STATE["bad"] += 1
        event = {"at": now_iso(), "status": "error", **heartbeat_error(exc, route),
                 "retry_attempt": retry_attempt, "session_id": session_id}
        code = event["http_status"]
        # Some upstream 400s are intermittent. Give them the same bounded retry
        # budget; a persistent invalid request still stops after three retries.
        transient = (isinstance(exc, (httpx.TransportError, TimeoutError, ConnectionError))
                     or code in {400, 408, 409, 429} or (isinstance(code, int) and code >= 500))
        KA_STATE["next_retry_at"] = None
        if retry_safe and transient and retry_attempt < len(KEEPALIVE_RETRY_DELAYS):
            delay = KEEPALIVE_RETRY_DELAYS[retry_attempt]
            KA_STATE["retry_count"] = retry_attempt + 1
            KA_STATE["next_retry_at"] = time.time() + delay
            event["retry_in_s"] = delay
        elif retry_safe and transient:
            event["retry_exhausted"] = True
        else:
            event["retry_skipped"] = "tool_stage" if not retry_safe else "non_retryable"
        # Record the failed attempt, but next_retry_at overrides the normal interval.
        ka_touch(real=False, event=event)
        print(f"[keepalive] status=error attempt={retry_attempt} retry_in_s={event.get('retry_in_s')} "
              f"error={json.dumps(event['error'], ensure_ascii=False)}", flush=True)
        return {"ok": False, **event}
    KA_STATE["retry_count"] = 0
    KA_STATE["next_retry_at"] = None
    usage = out.get("usage") or {}
    read = int(usage.get("cache_read_input_tokens") or 0)
    written = int(usage.get("cache_creation_input_tokens") or 0)
    status = "hit" if read > 0 else ("write" if written > 0 else "bad")
    KA_STATE["bad"] = 0 if status in {"hit", "write"} else KA_STATE["bad"] + 1
    event = {"at": now_iso(), "status": status, "read": read, "written": written,
              "output": int(usage.get("output_tokens") or 0), "forced": force,
             "cost": reported_cost(usage), "session_id": session_id, "retry_attempt": retry_attempt}
    renewed = False
    if KEEPALIVE_PROACTIVE:
        reply, delivery = proactive_reply(out)
        # Recheck after the model finishes, before anything becomes visible.
        if not await still_current():
            reply, delivery = "", "superseded"
        elif out.get("call_requested"):
            reply, delivery = "", "call_requested"
        elif out.get("action_completed") and delivery == "invalid_text" and not out.get("content"):
            delivery = "silent"
        if reply and any(m.get("role") == "assistant" and m.get("content") == reply for m in messages[-8:]):
            reply, delivery = "", "duplicate"
        if reply:
            payload = {
                "type": "reply_delta", "stream_id": "proactive-" + uuid.uuid4().hex,
                "done": True, "final_text": reply, "api_session": session_id,
                "is_push": True, "source": "api_keepalive",
                "api": {"runtime": "api_loop", "model": route["model"], "session": session_id,
                        "usage": usage, "tools_used": out.get("tools_used", []), "is_push": True},
            }
            try:
                ok, result = await relay_out(payload)
                delivered = ok and isinstance(result, dict) and bool(result.get("id"))
                delivery = "sent" if delivered else "delivery_failed"
                if delivered:
                    event["message_id"] = result["id"]
            except Exception as exc:
                delivery = "delivery_failed"
                event["delivery_error"] = type(exc).__name__
        event["delivery"] = delivery
        event["tools_used"] = out.get("tools_used", [])
        # User requested continuing activity: a delivered message or deliberate
        # silence renews the idle window. Errors/stale generations do not.
        renewed = delivery in {"sent", "silent", "duplicate", "call_requested"}
    ka_touch(real=renewed, event=event)
    print(f"[keepalive] status={status} delivery={event.get('delivery', 'cache_only')} "
          f"read={read} write={written} cost={event['cost']}", flush=True)
    return {"ok": True, **event}


ORPHAN_MAX_AGE_MIN = int(os.environ.get("ORPHAN_MAX_AGE_MIN", "30"))
ORPHAN_REMEMBER = 50


def orphan_ingests() -> list[dict[str, Any]]:
    """relay 把消息交给我之后、我这边才死掉的那些——她永远等不到回复。

    转发是"立刻 200 收到、答案丢后台慢慢生成"（一条回复可能跑几分钟,超过 relay
    10 秒的转发超时）。于是 relay 一旦收到 200 就把这条标成 routed='loop' 不再管,
    而进程这时候被重启或崩掉的话,生成任务跟着一起没,没有任何东西会发现她没被回答。
    2026-09-20 我重启去载新代码,正好把她 23:56 那条掐在生成中途。

    开机时捞一遍:最近 ORPHAN_MAX_AGE_MIN 分钟内、标了 loop、同一窗口里后面
    再没有任何 reply 的那条。一个窗口只补最后一条,补过的记进 config 不再重试。
    """
    path = Path(RELAY_DB)
    if not path.exists():
        return []
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=ORPHAN_MAX_AGE_MIN)).isoformat()
    done = set(load_config().get("recovered_ingests") or [])
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        with sqlite3.connect(str(path)) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT id, ts, text, meta FROM messages "
                "WHERE direction = 'in' AND kind IN ('user','voice') "
                "AND json_extract(meta, '$.routed') = 'loop' AND ts > ? "
                "ORDER BY id DESC LIMIT 20",
                (cutoff,),
            ).fetchall()
            for row in rows:
                if int(row["id"]) in done:
                    continue
                try:
                    meta = json.loads(row["meta"] or "{}")
                except json.JSONDecodeError:
                    meta = {}
                session = str(meta.get("api_session") or "")
                if session in seen:
                    continue                      # 一个窗口只补最后一条
                seen.add(session)
                where = ["id > ?", "direction = 'out'", "kind = 'reply'"]
                params: list[Any] = [int(row["id"])]
                if session:
                    where.append("json_extract(meta, '$.api_session') = ?")
                    params.append(session)
                else:
                    where.append("(json_extract(meta, '$.api_session') IS NULL"
                                 " OR json_extract(meta, '$.api_session') = '')")
                answered = conn.execute(
                    f"SELECT 1 FROM messages WHERE {' AND '.join(where)} LIMIT 1", params
                ).fetchone()
                if answered:
                    continue
                text = str(row["text"] or "").strip()
                if text:
                    out.append({"id": int(row["id"]), "ts": row["ts"], "text": text, "session": session})
    except Exception:
        traceback.print_exc()
        return []
    return list(reversed(out))


def mark_recovered(msg_ids: list[int]) -> None:
    cfg = load_config()
    done = [i for i in (cfg.get("recovered_ingests") or []) if isinstance(i, int)]
    done.extend(i for i in msg_ids if i not in done)
    cfg["recovered_ingests"] = done[-ORPHAN_REMEMBER:]
    save_config(cfg)


async def recover_orphan_ingests() -> None:
    """开机补答。先记账再生成——补答途中再崩一次也不会变成开机死循环。"""
    await asyncio.sleep(5)                        # 等 relay 那边站稳
    try:
        rows = orphan_ingests()
    except Exception:
        traceback.print_exc()
        return
    if not rows:
        return
    mark_recovered([r["id"] for r in rows])
    for row in rows:
        print(f"[recover] 补答 {row['id']} ({row['ts']}) session={row['session'] or '_default'}", flush=True)
        try:
            await handle_ingest(row["text"], row["id"], row["session"])
        except Exception:
            traceback.print_exc()


async def keepalive_watcher() -> None:
    while True:
        await asyncio.sleep(10)
        try:
            if not await keepalive_due():
                await keepalive_beat()
        except Exception:
            pass


async def run_model(messages: list[dict[str, str]], *, stream_id: str = "", session_id: str = "", emit_stream: bool = False, buffer_output: bool = False) -> dict[str, Any]:
    global ACTIVE_CHAT_COUNT, CHAT_REVISION
    ACTIVE_CHAT_COUNT += 1
    CHAT_REVISION += 1
    token = MOMENTS_TURN.set({"write": emit_stream, "posted": {}, "commented": {}})
    call_token = CALL_TURN.set(new_call_turn(session_id, emit_stream))
    try:
        out = await _run_model(messages, stream_id=stream_id, session_id=session_id, emit_stream=emit_stream,
                               buffer_output=buffer_output)
        out["moments_posted"] = [json.loads(value) for value in MOMENTS_TURN.get()["posted"].values()]
        out["moments_commented"] = [json.loads(value) for value in MOMENTS_TURN.get()["commented"].values()]
        out["call_requested"] = bool(json.loads(CALL_TURN.get()["result"] or "{}").get("ok"))
        return out
    finally:
        MOMENTS_TURN.reset(token)
        CALL_TURN.reset(call_token)
        ACTIVE_CHAT_COUNT -= 1


async def _run_model(messages: list[dict[str, str]], *, stream_id: str = "", session_id: str = "", emit_stream: bool = False, buffer_output: bool = False) -> dict[str, Any]:
    tried = []
    last_error = ""
    sink = None
    think_sink = None
    act_sink = None
    if emit_stream and not buffer_output:
        # act 帧不走 stream_id（每轮工具调用独立成条），dry 跑不发
        async def act_sink(steps: list[dict[str, str]]) -> None:
            await relay_out({**act_payload(steps), "api_session": session_id})
    if emit_stream and STREAM_OUTPUT and not buffer_output:
        async def sink(chunk: str) -> None:
            await relay_out({
                "type": "reply_delta",
                "stream_id": stream_id,
                "text": chunk,
                "done": False,
                "api_session": session_id,
            })

        async def think_sink(chunk: str) -> None:
            await relay_out({
                "type": "thinking_delta",
                "stream_id": stream_id,
                "text": chunk,
                "done": False,
                "api_session": session_id,
            })
    for route in main_chain():
        tried.append(route.get("model"))
        try:
            # Claude 走原生 /v1/messages（自控 cache_control，缓存真命中）；其余走 OpenAI 格式
            # dry 跑（emit_stream=False）不写便签：那是试拼，不算这个窗口真读过记忆
            brief_key = session_id if emit_stream else None
            if "claude" in str(route.get("model") or "").lower():
                out = await run_route_native(route, messages, sink, think_sink, act_sink, brief_key)
            else:
                out = await run_route_openai(route, messages, sink, act_sink, brief_key)
            out["model"] = route.get("model")
            out["tried"] = tried[:-1]
            return out
        except HTTPException as exc:
            if exc.status_code not in FALLBACK_CODES:
                raise
            why = str(exc.detail or "").strip()
            last_error = f"HTTP {exc.status_code}" + (f": {why}" if why and why != "fallback" else "")
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()  # 落到 api_loop 日志里，别再哑巴失败
    return {"text": "", "error": last_error or "all models failed", "tried": tried}


async def handle_ingest(text: str, msg_id: int | None, session_id: str, *, dry: bool = False) -> dict[str, Any]:
    stream_id = "api-" + uuid.uuid4().hex[:16]
    inbound = _parse_meta(relay_row_meta(msg_id))
    # Trust relay metadata, not a user typing a lookalike <desire-pulse> tag.
    background = bool(inbound.get("hidden") and
                      (inbound.get("desire") == "pulse" or inbound.get("event") == "moments"
                       or inbound.get("call") in {"decline", "end"}))
    if not dry:
        await prepare_history(session_id, msg_id)
    if not dry and not inbound.get("hidden"):
        try:
            MEMORY.prepare(session_id, msg_id, load_config())
        except (OSError, sqlite3.Error) as exc:
            print(f"[memory] handoff unavailable: {type(exc).__name__}", flush=True)
    messages = build_messages(text, before_id=msg_id, session_id=session_id, use_context=True)
    memory_token = MEMORY_TURN.set({"session": session_id, "message_id": msg_id, "write": not dry})
    try:
        out = await run_model(messages, stream_id=stream_id, session_id=session_id, emit_stream=not dry,
                              buffer_output=background)
    finally:
        MEMORY_TURN.reset(memory_token)
    reply = (out.get("text") or "").strip()
    final_text = str(out.get("final_text", reply)).strip()
    silent = (bool(out.get("call_requested")) and not final_text) or (background and not out.get("error") and (
        final_text == "[[silent]]" or (not final_text and bool(out.get("moments_posted") or out.get("moments_commented"))))
    )
    if background:
        # Intermediate tool-round prose is private to this wake-up; only the
        # final round can choose to also open a chat conversation.
        reply = "" if silent else final_text
    if not reply and not silent:
        reply = failure_notice(out)
    meta = {
        "runtime": "api_loop",
        "model": out.get("model"),
        "fallback_from": out.get("tried") or [],
        "usage": out.get("usage") or {},
        "tools_used": out.get("tools_used") or [],
        "session": session_id,
    }
    if out.get("moments_posted"):
        meta["moments_posted"] = out["moments_posted"]
    if out.get("moments_commented"):
        meta["moments_commented"] = out["moments_commented"]
    if out.get("error"):
        meta["error"] = str(out["error"])[:1200]  # 失败原因存进 meta，别再只剩一句兜底话没法验尸
    if str((out.get("stop") or {}).get("stop_reason") or "") == "refusal":
        meta["refusal"] = out["stop"]     # 200 但正文为空,跟 403 一个症状两个病
    rounds = out.get("usage_rounds") or []
    if len(rounds) > 1:
        # 带工具的一轮是两三个请求，merge_usage 一加就看不出是哪一个
        # 踩空了。普通回合只有一轮，不存。
        meta["usage_rounds"] = [
            {"read": r.get("cache_read_input_tokens", 0),
             "write": r.get("cache_creation_input_tokens", 0),
             "in": r.get("input_tokens", 0),
             "out": r.get("output_tokens", 0),
             "cost": r.get("cost")}
            for r in rounds
        ]
    if dry:
        return {"ok": True, "reply": reply, "api": meta}
    if silent:
        if out.get("call_requested") and STREAM_OUTPUT and not background:
            if out.get("thinking"):
                await relay_out({"type": "thinking_delta", "stream_id": stream_id,
                                 "done": True, "final_text": out["thinking"], "api_session": session_id})
            await relay_out({"type": "reply_delta", "stream_id": stream_id,
                             "done": True, "final_text": "", "api_session": session_id})
        print(f"[background] #{msg_id} silent tools={meta['tools_used']}", flush=True)
        return {"ok": True, "delivery": "silent", "api": meta}
    if STREAM_OUTPUT and (out.get("thinking") or "").strip():
        # 思考块先定稿（relay 存成 kind=thinking，手机上合拢成思考条），再发正文
        await relay_out({
            "type": "thinking_delta",
            "stream_id": stream_id,
            "done": True,
            "final_text": out.get("thinking") or "",
            "api_session": session_id,
        })
    if STREAM_OUTPUT:
        ok, body = await relay_out({
            "type": "reply_delta",
            "stream_id": stream_id,
            "done": True,
            "final_text": reply,
            "api": meta,
            "api_session": session_id,
        })
    else:
        ok, body = await relay_out({"type": "reply", "text": reply, "api": meta, "api_session": session_id})
    return {"ok": ok, "relay": body, "api": meta}


app = FastAPI(title="companion-api-loop")


@app.on_event("startup")
async def _startup() -> None:
    asyncio.create_task(keepalive_watcher())
    asyncio.create_task(recover_orphan_ingests())


@app.get("/loop/keepalive")
async def keepalive_state():
    reason = await keepalive_due()
    return {
        "enabled": keepalive_enabled(),
        "cache_ttl": CACHE_TTL,
        "due": not reason,
        "proactive": KEEPALIVE_PROACTIVE,
        "after_min": KEEPALIVE_AFTER_MIN,
        "max_idle_h": KEEPALIVE_MAX_IDLE_H,
        "active_chats": ACTIVE_CHAT_COUNT,
        "history_busy": any(lock.locked() for lock in HISTORY_LOCKS.values()),
        "skip_reason": reason,
        "last_real": KA_STATE["last_real"],
        "last_touch": KA_STATE["last_touch"],
        "last_prefix": KA_STATE.get("last_prefix"),
        "bad_count": KA_STATE["bad"],
        "retry_count": KA_STATE.get("retry_count", 0),
        "next_retry_at": KA_STATE.get("next_retry_at"),
        "retry_delays_s": list(KEEPALIVE_RETRY_DELAYS),
        "error_detail_version": 1,
        "events": KA_STATE["events"][-10:],
    }


@app.post("/loop/keepalive/run")
async def keepalive_run():
    """手动打一针（跳过 due 检查，测试用）。"""
    return await keepalive_beat(force=True)


@app.get("/healthz")
async def healthz():
    translator = translation_chain()
    return {
        "ok": True,
        "memory_version": 1,
        "breath_profile_version": 1,
        "history_cache_version": 2,
        "summary_timeout_seconds": SUMMARY_TIMEOUT_SECONDS,
        "summary_retry_cooldown_seconds": SUMMARY_RETRY_COOLDOWN_SECONDS,
        "models": [r.get("model") for r in main_chain()],
        "translation_model": translator[0].get("model") if translator else None,
        "history_n": history_n(),
        "history_turns": history_turns(),
        "relay_db": RELAY_DB,
        "relay_secret_loaded": bool(RELAY_SECRET),
        "mcp_url": MCP_URL,
        "tools_enabled": tools_enabled(),
    }


# 兜底估价（USD/百万 token）。只在上游不报价时才用得上——OpenRouter 每条响应都带
# usage.cost，那是它当场扣的钱，比任何折算都准；dzzi 这类中转不报，才落到这张表。
# 数字是 Anthropic 官方 Opus 档，可在 config 的 "prices" 里逐项覆盖。
DEFAULT_PRICES = {"input": 15.0, "output": 75.0, "cache_read": 1.5, "cache_write_5m": 18.75, "cache_write_1h": 30.0}


def usage_prices() -> dict[str, float]:
    overrides = load_config().get("prices")
    overrides = overrides if isinstance(overrides, dict) else {}
    return {key: overrides.get(key, value) for key, value in DEFAULT_PRICES.items()}


def reported_cost(usage: Any) -> float | None:
    """上游自己报的这次花费（OpenRouter: usage.cost，单位美元）。没有就 None。"""
    if not isinstance(usage, dict):
        return None
    raw = usage.get("cost")
    if raw is None and isinstance(usage.get("cost_details"), dict):
        raw = usage["cost_details"].get("upstream_inference_cost")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def usage_normalize(usage: dict[str, Any]) -> dict[str, int]:
    read = int(usage.get("cache_read_input_tokens") or 0)
    written = int(usage.get("cache_creation_input_tokens") or 0)
    if not written:
        written = int(usage.get("claude_cache_creation_1_h_tokens") or 0) + int(usage.get("claude_cache_creation_5_m_tokens") or 0)
    raw_in = int(usage.get("input_tokens") or usage.get("prompt_tokens") or 0)
    # OpenAI 路径的 prompt_tokens 含缓存部分，原生 input_tokens 不含——尽量归一成"全价输入"
    plain_in = max(0, raw_in - read - written) if raw_in > read + written else raw_in
    out = max(int(usage.get("output_tokens") or 0), int(usage.get("completion_tokens") or 0))
    return {"input": plain_in, "output": out, "cache_read": read, "cache_write": written}


def usage_cost_usd(n: dict[str, int], usage: Any = None) -> float:
    billed = reported_cost(usage)
    if billed is not None:
        return billed
    prices = usage_prices()
    write_price = prices["cache_write_1h"] if CACHE_TTL == "1h" else prices["cache_write_5m"]
    return (
        n["input"] * prices["input"]
        + n["output"] * prices["output"]
        + n["cache_read"] * prices["cache_read"]
        + n["cache_write"] * write_price
    ) / 1_000_000


@app.get("/loop/stats")
async def loop_stats():
    """API 身体用量统计：扫 relay.db 里 api_loop 的回复 meta.usage 聚合。"""
    rows = []
    path = Path(RELAY_DB)
    if path.exists():
        with sqlite3.connect(str(path)) as conn:
            conn.row_factory = sqlite3.Row
            # api_loop 的 meta 嵌在 'api' 键下（relay 存 body 剩余字段）；兼容两种路径
            rows = conn.execute(
                "SELECT id, ts, meta FROM messages "
                "WHERE kind = 'reply' AND (json_extract(meta, '$.api.runtime') = 'api_loop' "
                "OR json_extract(meta, '$.runtime') = 'api_loop') "
                "ORDER BY id DESC LIMIT 500"
            ).fetchall()
    total = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}
    recent = []
    count = 0
    total_cost = 0.0
    billed_rows = 0      # 其中几条是上游实报的花费，不是本地折算
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except json.JSONDecodeError:
            continue
        if isinstance(meta.get("api"), dict):
            meta = meta["api"]
        usage = meta.get("usage")
        if not isinstance(usage, dict) or not usage:
            continue
        n = usage_normalize(usage)
        count += 1
        for k in total:
            total[k] += n[k]
        # 每条各自算钱再累加：上游实报的那些直接进总数，别被聚合折算冲淡
        row_cost = usage_cost_usd(n, usage)
        total_cost += row_cost
        billed = reported_cost(usage) is not None
        if billed:
            billed_rows += 1
        if len(recent) < 50:
            recent.append({
                "id": r["id"], "ts": r["ts"], "model": meta.get("model"),
                "tools": meta.get("tools_used") or [], **n,
                "cost_usd": round(row_cost, 5), "billed": billed,
            })
    ka_events = KA_STATE["events"]
    ka_cost = sum(
        usage_cost_usd(
            {"input": 0, "output": e.get("output", 0), "cache_read": e.get("read", 0), "cache_write": e.get("written", 0)},
            {"cost": e.get("cost")},
        )
        # Delivered proactive usage is already included in the reply rows above.
        for e in ka_events if e.get("status") in {"hit", "write"} and not e.get("message_id")
    )
    denom = total["input"] + total["cache_read"] + total["cache_write"]
    return {
        "messages": count,
        "total": total,
        "total_cost_usd": round(total_cost, 4),
        "avg_per_message": {
            **{k: (round(v / count) if count else 0) for k, v in total.items()},
            "cost_usd": round(total_cost / count, 5) if count else 0,
        },
        "cache_hit_rate": round(total["cache_read"] / denom, 3) if denom else 0,
        "keepalive": {"beats": len(ka_events), "cost_usd": round(ka_cost, 4), "bad_count": KA_STATE["bad"]},
        "cache_ttl": CACHE_TTL,
        "billed_rows": billed_rows,
        "prices_note": (
            f"USD。{billed_rows}/{count} 条是上游实报的花费（OpenRouter 每条都报），其余按本地价目表估算"
            if billed_rows else "USD，按本地价目表估算（这批上游都没报价）"
        ),
        "recent": recent,
        "activity": {"version": 1, "events": activity_records(load_config(), ka_events),
                     "heartbeat": {k: v for k, v in (await keepalive_state()).items() if k != "events"}},
    }


@app.get("/loop/config")
async def loop_config():
    return public_config()


@app.post("/loop/config")
async def loop_config_update(request: Request):
    return update_config(await request.json())


@app.post("/loop/summary/rebuild")
async def loop_summary_rebuild(request: Request):
    """用现在的写法把窗口摘要从头重压:{"session": "<id>" | "all"}。按窗口顺序串行跑,
    结果打进日志;这里立刻返回。"""
    body = await request.json()
    target = str(body.get("session") or "").strip()
    keys = list((load_config().get("summaries") or {}).keys()) if target == "all" else [target]
    keys = [k for k in keys if k]
    if not keys:
        raise HTTPException(status_code=400, detail="session required")

    async def run() -> None:
        for k in keys:
            await rebuild_summary(k)

    asyncio.create_task(run())
    return {"ok": True, "started": keys, "model": (summary_route() or {}).get("model")}


@app.get("/loop/sessions")
async def loop_sessions():
    return sessions_public()


@app.post("/loop/sessions")
async def loop_sessions_create(request: Request):
    body = await request.json()
    row = create_session(
        title=str(body.get("title") or "New chat"),
        since_id=int(body.get("since_id") or 0),
        activate=bool(body.get("activate", True)),
        handoff_mode=str(body.get("handoff_mode") or ""),
        handoff_from=str(body.get("handoff_from") or "auto"),
    )
    return {**sessions_public(), "created": row}


@app.patch("/loop/sessions/{session_id}")
async def loop_sessions_patch(session_id: str, request: Request):
    return patch_session(session_id, await request.json())


@app.delete("/loop/sessions/{session_id}")
async def loop_sessions_delete(session_id: str):
    return delete_session(session_id)


@app.post("/loop/chat")
async def loop_chat(request: Request):
    body = await request.json()
    text = str(body.get("text") or body.get("message") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    session_id = str(body.get("session_id") or body.get("api_session") or active_session_id() or "").strip()
    messages = build_messages(text, before_id=None, session_id=session_id, use_context=bool(body.get("use_context", True)))
    out = await run_model(messages, emit_stream=False)
    return {"ok": True, "reply": out.get("text") or "", "api": out}


@app.post("/loop/translate")
async def loop_translate(request: Request):
    body = await request.json()
    text = str(body.get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    if len(text) > 60_000:
        raise HTTPException(status_code=413, detail="text too long")
    return {"ok": True, **await translate_to_simplified_chinese(text)}


def _ingest_task_done(task: asyncio.Task) -> None:
    try:
        task.result()
    except Exception:
        traceback.print_exc()


@app.post("/loop/ingest")
async def loop_ingest(request: Request):
    body = await request.json()
    text = str(body.get("text") or body.get("message") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    msg_id = body.get("id")
    try:
        before_id = int(msg_id) if msg_id is not None else None
    except Exception:
        before_id = None
    session_id = str(body.get("session_id") or body.get("api_session") or active_session_id() or "").strip()
    dry = bool(body.get("dry"))
    if dry:
        return await handle_ingest(text, before_id, session_id, dry=True)
    # Accept immediately and generate in the background: a reply can take minutes
    # (thinking + tool rounds) but relay's forward timeout is ~10s. If we答完才返回,
    # relay误判"投递失败"→摘掉 routed='loop' 标→CC 插件重连回填时把这条再投给
    # CC→双身体重复回复. 现在 200=已收到; 摘标兜底只留给 api_loop 真挂了的情况.
    task = asyncio.create_task(handle_ingest(text, before_id, session_id))
    task.add_done_callback(_ingest_task_done)
    return {"ok": True, "accepted": True}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=LOOP_PORT)
