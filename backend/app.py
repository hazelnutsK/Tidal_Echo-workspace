#!/usr/bin/env python3
"""
companion relay backend — a private 1:1 message channel between a person and
their AI companion (an AI running locally as a Claude Code "channel" plugin).

Two ends, one shared secret:
  - AI side   (local CC channel plugin):  POST /channel/out  ·  SSE GET /channel/in
  - Human side (phone PWA):               POST /app/send     ·  SSE GET /app/stream  ·  GET /app/history

No framework magic: messages land in sqlite and fan out to SSE subscribers via
one asyncio.Queue per connection. A single shared Bearer secret guards every
endpoint (single user). The secret may travel in the Authorization header *or*
as a ?token= query param — because the browser's native EventSource cannot set
custom headers.

Everything personal — names, secrets, domain, paths — comes from environment
variables (see .env.example). Nothing identifying is hard-coded.
"""

import asyncio
import mimetypes
import hmac
import json
import os
import re
import secrets
import subprocess
import sqlite3
import sys
import time
import threading
import urllib.error
import urllib.request
import urllib.parse
from contextlib import asynccontextmanager
from datetime import datetime, timezone, timedelta
from pathlib import Path

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import FileResponse, Response, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware

import desire  # 欲望内核（backend/desire.py，纯函数）
import call_state
import vps_cc
from stream_paragraphs import final_parts, split_sentences, stream_paragraphs, stream_parts
import recall  # 每轮自动浮现旧记忆（backend/recall.py）
import xhs     # 她丢来的小红书链接展开成笔记+配图（backend/xhs.py）
import binaural  # [[voice]] 里的 [左耳][脑后]… → 双耳语音条（backend/binaural.py）

try:
    from pywebpush import webpush, WebPushException
except Exception:  # a missing lib must not stop the relay from starting
    webpush = None
    class WebPushException(Exception):
        pass


# --- identity (parameterized — set these to your own names) ----------------
AI_NAME = os.environ.get("RELAY_AI_NAME", "AI")          # AI companion's display name (narration)
PUSH_TITLE = os.environ.get("RELAY_PUSH_TITLE", "Altair")  # 通知加粗行:Altair, from Aquila(App名)——星从星座里飞出来
HUMAN_NAME = os.environ.get("RELAY_HUMAN_NAME", "对方")   # how the AI is told about you in voice/call narration

# --- core config / secrets (all from env) ----------------------------------
SECRET = os.environ.get("RELAY_SECRET", "")
DB_PATH = os.environ.get("RELAY_DB", str(Path(__file__).parent / "relay.db"))
PORT = int(os.environ.get("RELAY_PORT", "3011"))
UPLOAD_DIR = Path(os.environ.get("RELAY_UPLOAD_DIR", str(Path(__file__).parent / "uploads")))
PUBLIC_PREFIX = os.environ.get("RELAY_PUBLIC_PREFIX", "/relay").rstrip("/")
APP_PATH = os.environ.get("RELAY_APP_PATH", "/")  # where a push-notification tap opens the PWA
ALLOW_ORIGINS = [o.strip() for o in os.environ.get(
    "RELAY_ALLOW_ORIGINS", "http://localhost:8080,http://127.0.0.1:8080"
).split(",") if o.strip()]
MAX_UPLOAD_BYTES = int(os.environ.get("RELAY_MAX_UPLOAD_BYTES", str(10 * 1024 * 1024)))
VOICE_MAX_BYTES = int(os.environ.get("RELAY_VOICE_MAX_BYTES", str(8 * 1024 * 1024)))
SCREEN_SHARE_MAX_FRAME_BYTES = int(os.environ.get(
    "RELAY_SCREEN_SHARE_MAX_FRAME_BYTES", str(4 * 1024 * 1024)
))
SCREEN_SHARE_TICKET_TTL = int(os.environ.get("RELAY_SCREEN_SHARE_TICKET_TTL", "180"))
VOICE_TRANSCRIBE_CMD = os.environ.get("RELAY_VOICE_TRANSCRIBE_CMD", "")
EARS_URL = os.environ.get("RELAY_EARS_URL", "")  # local `ears` server: transcript + tone analysis

# --- TTS provider select ----------------------------------------------------
# "elevenlabs" or "minimax". Default: whichever has keys (ElevenLabs wins).
TTS_PROVIDER = os.environ.get("TTS_PROVIDER", "").strip().lower()

# --- ElevenLabs TTS (optional — leave key blank to disable) -----------------
ELEVENLABS_API_BASE = os.environ.get("ELEVENLABS_API_BASE", "https://api.elevenlabs.io")
ELEVENLABS_API_KEY = os.environ.get("ELEVENLABS_API_KEY", "")
ELEVENLABS_VOICE_ID = os.environ.get("ELEVENLABS_VOICE_ID", "")
ELEVENLABS_MODEL = os.environ.get("ELEVENLABS_MODEL", "eleven_multilingual_v2")
# mp3_44100_128 needs a paid tier; free keys must drop to mp3_22050_32.
ELEVENLABS_OUTPUT_FORMAT = os.environ.get("ELEVENLABS_OUTPUT_FORMAT", "mp3_44100_128")
# 通话专用档：v3 表现力最好但生成慢得离谱（78 字要 15 秒才拿到整段 mp3，
# 电话里等不起）。通话走 turbo v2.5 + 低码率 + /stream + optimize_streaming_latency，
# 同一条 78 字实测 2.1 秒。聊天里的 [[voice]] 语音条不受影响，继续用 v3（有语气标签）。
ELEVENLABS_CALL_MODEL = os.environ.get("ELEVENLABS_CALL_MODEL", "eleven_turbo_v2_5")
# turbo v2.5 的母语是英语，说中文带一口外国腔（她的原话：像一个外国人中文讲得不好的
# 那种）。所以通话档再按语种分一次：中文走这个，英文继续走 turbo。留空=不分，
# 行为跟以前完全一样。
ELEVENLABS_CALL_MODEL_ZH = os.environ.get("ELEVENLABS_CALL_MODEL_ZH", "")
ELEVENLABS_CALL_OUTPUT_FORMAT = os.environ.get("ELEVENLABS_CALL_OUTPUT_FORMAT", "mp3_22050_32")
ELEVENLABS_CALL_LATENCY = os.environ.get("ELEVENLABS_CALL_LATENCY", "3")
ELEVENLABS_STABILITY = float(os.environ.get("ELEVENLABS_STABILITY", "0.5"))
ELEVENLABS_SIMILARITY = float(os.environ.get("ELEVENLABS_SIMILARITY", "0.75"))
ELEVENLABS_TTS_TIMEOUT = float(os.environ.get("ELEVENLABS_TTS_TIMEOUT", "30"))

# --- MiniMax TTS (optional — leave keys blank to disable spoken replies) ----
MINIMAX_API_BASE = os.environ.get("MINIMAX_API_BASE", "https://api.minimaxi.com")
MINIMAX_API_KEY = os.environ.get("MINIMAX_API_KEY", "")
MINIMAX_GROUP_ID = os.environ.get("MINIMAX_GROUP_ID", "")
MINIMAX_MODEL = os.environ.get("MINIMAX_MODEL", "speech-02-hd")
MINIMAX_VOICE_ZH = os.environ.get("MINIMAX_VOICE_ZH", "")
MINIMAX_TTS_TIMEOUT = float(os.environ.get("MINIMAX_TTS_TIMEOUT", "30"))

# --- Web Push (VAPID, optional) — push unread replies to the PWA lock screen
VAPID_PUBLIC_KEY = os.environ.get("VAPID_PUBLIC_KEY", "")
VAPID_PRIVATE_PEM = os.environ.get("VAPID_PRIVATE_PEM", "")   # PEM file path OR inline PEM text
VAPID_SUBJECT = os.environ.get("VAPID_SUBJECT", "mailto:admin@example.com")
PUSH_PREVIEW_CHARS = int(os.environ.get("RELAY_PUSH_PREVIEW_CHARS", "120"))
PUSH_TTL_SEC = int(os.environ.get("RELAY_PUSH_TTL_SEC", "86400"))

# --- presence tuning (seconds) ---------------------------------------------
PRESENCE_ONLINE_SEC = int(os.environ.get("RELAY_PRESENCE_ONLINE_SEC", "180"))
PRESENCE_RECENT_SEC = int(os.environ.get("RELAY_PRESENCE_RECENT_SEC", "1800"))

# --- Optional server-side API loop -----------------------------------------
# "desktop" keeps the original Claude Code channel path. "loop" forwards new
# human messages to a local HTTP loop, which replies through /channel/out.
BRAIN_FILE = Path(os.environ.get("RELAY_BRAIN_FILE", str(Path(__file__).parent / "brain_target")))
LOOP_INGEST_URL = os.environ.get("RELAY_LOOP_INGEST_URL", "http://127.0.0.1:3020/loop/ingest")
STREAM_DRAFT_TTL = int(os.environ.get("RELAY_STREAM_DRAFT_TTL", "600"))

if not SECRET:
    raise SystemExit("RELAY_SECRET is required (set it in the systemd EnvironmentFile)")


# ---------------------------------------------------------------------------
# storage
# ---------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                ts        TEXT NOT NULL,
                direction TEXT NOT NULL,   -- 'in' (human -> AI) | 'out' (AI -> human)
                kind      TEXT NOT NULL,   -- 'user' | 'reply' | 'thinking' | 'voice' | 'call' | ...
                text      TEXT NOT NULL,
                meta      TEXT NOT NULL DEFAULT '{}'
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS chat_sessions (
                id         TEXT PRIMARY KEY,
                body       TEXT NOT NULL,       -- 'loop' | 'codex'
                title      TEXT NOT NULL,
                since_id   INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS push_subscriptions (
                endpoint TEXT PRIMARY KEY,
                p256dh   TEXT NOT NULL,
                auth     TEXT NOT NULL,
                ua       TEXT,
                created  TEXT NOT NULL,
                last_ok  TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS screentime (
                id     INTEGER PRIMARY KEY AUTOINCREMENT,
                ts     TEXT NOT NULL,
                app    TEXT NOT NULL,
                action TEXT NOT NULL    -- 'open' | 'close'（toggle 自动判定）
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS posts (
                id     INTEGER PRIMARY KEY AUTOINCREMENT,
                ts     TEXT NOT NULL,
                author TEXT NOT NULL,   -- 'human' | 'ai'
                kind   TEXT NOT NULL,   -- 'moment' (动态) | 'journal' (日志)
                text   TEXT NOT NULL,
                meta   TEXT NOT NULL DEFAULT '{}'  -- attachments / likes / comments
            )
            """
        )
        # ── 相册:AI 自己挑着收的照片 ──
        # 聊天里发过的图不再自动全进相册;只有我在回复里写 [[keep:标题|想说的话]]
        # 收下的那张才落这张表,连带当时想说的话一起存。url 唯一 = 重复收藏只更新。
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS album (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                url      TEXT NOT NULL UNIQUE,      -- uploads 里那张图
                kept_at  TEXT NOT NULL,             -- 我收进来的时间
                photo_ts TEXT NOT NULL DEFAULT '',  -- 照片当初发出来的时间
                title    TEXT NOT NULL DEFAULT '',
                note     TEXT NOT NULL DEFAULT '',  -- 看到它时想说的话
                src_id   INTEGER,                   -- 照片所在的那条消息
                msg_id   INTEGER,                   -- 我收藏时说的那条回复
                meta     TEXT NOT NULL DEFAULT '{}'
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS calendar (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                date    TEXT NOT NULL,              -- YYYY-MM-DD
                time    TEXT NOT NULL DEFAULT '',   -- HH:MM，可空
                title   TEXT NOT NULL,
                kind    TEXT NOT NULL DEFAULT 'event',  -- event | anniversary | note(AI彩蛋) | blessing(节日祝福)
                visible INTEGER NOT NULL DEFAULT 1,     -- 0 = 她的私密，AI 侧接口不吐
                author  TEXT NOT NULL DEFAULT 'human',  -- human | ai
                meta    TEXT NOT NULL DEFAULT '{}'      -- recur:'yearly'|'monthly' / remind:1 / reminded:'YYYY-MM-DD'
            )
            """
        )
        # ── 一起读书:书 / 章文 / 阅读位置 / 划线批注 / 章节摘要 ──
        # 铁律:书文永不进模型常驻上下文;AI 侧一律 clamp 到她读过的最远位置(防剧透)。
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS books (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                title          TEXT NOT NULL,
                author         TEXT DEFAULT '',
                cover          TEXT DEFAULT '',          -- uploads/ 里的封面文件名,可空
                total_chapters INTEGER NOT NULL,
                total_chars    INTEGER NOT NULL,
                created_at     TEXT NOT NULL,
                meta           TEXT DEFAULT '{}'         -- JSON:唤醒闸状态等杂项
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS book_chunks (
                book_id       INTEGER NOT NULL,
                chapter_idx   INTEGER NOT NULL,          -- 0-based,按 epub spine 顺序
                chapter_title TEXT DEFAULT '',
                text          TEXT NOT NULL,             -- 该章纯文本
                char_count    INTEGER NOT NULL,
                PRIMARY KEY (book_id, chapter_idx)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS reading_state (
                book_id          INTEGER PRIMARY KEY,
                cur_chapter      INTEGER DEFAULT 0,      -- 阅读器恢复位置用
                cur_offset       INTEGER DEFAULT 0,      -- 章内字符偏移
                furthest_chapter INTEGER DEFAULT 0,      -- clamp 用这个,单调递增
                furthest_offset  INTEGER DEFAULT 0,      -- 她回头重读时 cur 回退、furthest 不动
                updated_at       TEXT NOT NULL,
                last_heartbeat   TEXT DEFAULT ''         -- 阅读心跳,session-end 判定用
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS book_annotations (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id     INTEGER NOT NULL,
                chapter_idx INTEGER NOT NULL,
                start_off   INTEGER NOT NULL,            -- 章内字符区间
                end_off     INTEGER NOT NULL,
                quote       TEXT NOT NULL,               -- 划线原文(冗余存)
                note        TEXT DEFAULT '',             -- 批注文字,空=纯划线
                author      TEXT NOT NULL,               -- 'her' | 'ai'
                reply_to    INTEGER DEFAULT NULL,        -- AI 回批注时指向她的 annotation id
                created_at  TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS book_summaries (
                book_id     INTEGER NOT NULL,
                chapter_idx INTEGER NOT NULL,
                summary     TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                PRIMARY KEY (book_id, chapter_idx)
            )
            """
        )
        # 文章(2026-10-25):她把我写的长东西收进空间页单独一页。跟收藏分开——
        # 收藏是一句话,文章是一整篇;短聊拆成几条的回复收的时候拼回一篇。
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS articles (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                title       TEXT NOT NULL,
                text        TEXT NOT NULL,
                message_ids TEXT NOT NULL,              -- JSON 数组,原消息 id
                source_ts   TEXT NOT NULL,              -- 第一条原消息的时间
                created_at  TEXT NOT NULL
            )
            """
        )
        conn.commit()


def save_message(direction: str, kind: str, text: str, meta: dict) -> dict:
    ts = meta.get("ts") or now_iso()
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO messages (ts, direction, kind, text, meta) VALUES (?,?,?,?,?)",
            (ts, direction, kind, text, json.dumps(meta, ensure_ascii=False)),
        )
        conn.commit()
        mid = cur.lastrowid
    return {"id": mid, "ts": ts, "direction": direction, "kind": kind, "text": text, "meta": meta}


def set_reaction(message_id, who, emoji):
    # Set/clear one party's reaction on an existing message.
    # Returns the message's reactions dict, or None if the target doesn't exist.
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            return None
        meta = json.loads(row["meta"] or "{}")
        reactions = meta.get("reactions") or {}
        if emoji:
            reactions[who] = emoji
        else:
            reactions.pop(who, None)
        if reactions:
            meta["reactions"] = reactions
        else:
            meta.pop("reactions", None)
        conn.execute(
            "UPDATE messages SET meta = ? WHERE id = ?",
            (json.dumps(meta, ensure_ascii=False), message_id),
        )
        conn.commit()
    return reactions


def history(since: int, limit: int) -> list:
    # hidden = relay-internal frames (forge handoff etc.) — the AI sees them via
    # /channel/in, the phone must not render them.
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM messages WHERE id > ? AND json_extract(meta, '$.hidden') IS NULL "
            "ORDER BY id ASC LIMIT ?",
            (since, limit),
        ).fetchall()
    return rows_to_messages(rows)


def history_for_session(session_id: str, since: int, limit: int) -> list:
    session_id = (session_id or "").strip()
    if not session_id:
        return history(since, limit)
    with db() as conn:
        if session_id == "__legacy__":
            rows = conn.execute(
                "SELECT * FROM messages "
                "WHERE id > ? AND (json_extract(meta, '$.api_session') IS NULL OR json_extract(meta, '$.api_session') = '') "
                "AND json_extract(meta, '$.hidden') IS NULL "
                "ORDER BY id ASC LIMIT ?",
                (since, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM messages "
                "WHERE id > ? AND json_extract(meta, '$.api_session') = ? "
                "ORDER BY id ASC LIMIT ?",
                (since, session_id, limit),
            ).fetchall()
    return rows_to_messages(rows)


def history_tail(session_id: str, before: int, limit: int) -> list:
    """Newest `limit` visible messages with id < before (0 = no upper bound), oldest
    first. The iOS app opens on this instead of walking the whole archive forward
    (2026-09-30: that walk was 41 pages / 8.6 MB on every cold start)."""
    session_id = (session_id or "").strip()
    clauses = ["json_extract(meta, '$.hidden') IS NULL"]
    params: list = []
    if before > 0:
        clauses.append("id < ?")
        params.append(before)
    if session_id == "__legacy__":
        clauses.append("(json_extract(meta, '$.api_session') IS NULL OR json_extract(meta, '$.api_session') = '')")
    elif session_id:
        clauses.append("json_extract(meta, '$.api_session') = ?")
        params.append(session_id)
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM messages WHERE " + " AND ".join(clauses) + " ORDER BY id DESC LIMIT ?",
            (*params, limit),
        ).fetchall()
    return rows_to_messages(list(reversed(rows)))


def chat_session_rows() -> list[dict]:
    with db() as conn:
        rows = conn.execute(
            "SELECT id, body, title, since_id, created_at FROM chat_sessions "
            "ORDER BY created_at ASC"
        ).fetchall()
    return [dict(row) for row in rows]


def chat_session(session_id: str) -> dict | None:
    session_id = (session_id or "").strip()
    if not session_id or session_id == "__legacy__":
        return None
    with db() as conn:
        row = conn.execute(
            "SELECT id, body, title, since_id, created_at FROM chat_sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    return dict(row) if row else None


def upsert_chat_sessions(rows: list, body: str = "loop") -> None:
    now = now_iso()
    with db() as conn:
        for item in rows or []:
            if not isinstance(item, dict) or not str(item.get("id") or "").strip():
                continue
            session_id = str(item["id"]).strip()
            title = str(item.get("title") or "新对话").strip() or "新对话"
            try:
                since_id = int(item.get("since_id") or 0)
            except (TypeError, ValueError):
                since_id = 0
            created_at = str(item.get("created_at") or now)
            conn.execute(
                "INSERT INTO chat_sessions (id, body, title, since_id, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
                "body=excluded.body, title=excluded.title, since_id=excluded.since_id, updated_at=excluded.updated_at",
                (session_id, body, title, since_id, created_at, now),
            )
        conn.commit()


def create_codex_session(title: str, since_id: int) -> dict:
    session = {
        "id": "codex-" + secrets.token_hex(8),
        "body": "codex",
        "title": (title or "Codex 对话").strip() or "Codex 对话",
        "since_id": max(0, int(since_id or 0)),
        "created_at": now_iso(),
    }
    upsert_chat_sessions([session], "codex")
    return session


def session_body(session_id: str) -> str:
    session_id = (session_id or "").strip()
    if not session_id or session_id == "__legacy__":
        return "desktop"
    row = chat_session(session_id)
    if row and row.get("body") in ("codex", "loop"):
        return str(row["body"])
    # Prefix fallback keeps a newly created Codex window routable even if a
    # transient database read fails; all pre-existing unregistered ids are API.
    return "codex" if session_id.startswith("codex-") else "loop"


def sessions_payload(active_session: str = "", created: dict | None = None) -> dict:
    rows = chat_session_rows()
    payload = {"active_session": active_session or "", "sessions": rows}
    if created:
        payload["created"] = created
    return payload


def inbound_history(since: int, limit: int, target: str = "desktop") -> list:
    # Each long-lived local body gets only messages routed to it. Desktop keeps
    # the legacy unmarked rows; Codex rows are explicitly marked at dispatch.
    with db() as conn:
        if target == "codex":
            rows = conn.execute(
                "SELECT * FROM messages WHERE id > ? AND direction = 'in' "
                "AND json_extract(meta, '$.routed') = 'codex' "
                "ORDER BY id ASC LIMIT ?",
                (since, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM messages WHERE id > ? AND direction = 'in' "
                "AND json_extract(meta, '$.routed') IS NULL "
                "ORDER BY id ASC LIMIT ?",
                (since, limit),
            ).fetchall()
    return rows_to_messages(rows)


def rows_to_messages(rows) -> list:
    return [
        {
            "id": r["id"], "ts": r["ts"], "direction": r["direction"],
            "kind": r["kind"], "text": r["text"], "meta": json.loads(r["meta"] or "{}"),
        }
        for r in rows
    ]


# ---------------------------------------------------------------------------
# web push — subscription storage + send
# ---------------------------------------------------------------------------

def save_subscription(endpoint: str, p256dh: str, auth: str, ua: str = "") -> None:
    with db() as conn:
        conn.execute(
            """
            INSERT INTO push_subscriptions (endpoint, p256dh, auth, ua, created, last_ok)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(endpoint) DO UPDATE SET p256dh=excluded.p256dh, auth=excluded.auth, ua=excluded.ua
            """,
            (endpoint, p256dh, auth, ua, now_iso(), None),
        )
        conn.commit()


def delete_subscription(endpoint: str) -> None:
    with db() as conn:
        conn.execute("DELETE FROM push_subscriptions WHERE endpoint = ?", (endpoint,))
        conn.commit()


def list_subscriptions() -> list:
    with db() as conn:
        rows = conn.execute("SELECT endpoint, p256dh, auth FROM push_subscriptions").fetchall()
    return [{"endpoint": r["endpoint"], "keys": {"p256dh": r["p256dh"], "auth": r["auth"]}} for r in rows]


def mark_subscription_ok(endpoint: str) -> None:
    with db() as conn:
        conn.execute("UPDATE push_subscriptions SET last_ok = ? WHERE endpoint = ?", (now_iso(), endpoint))
        conn.commit()


def _send_one_push(sub: dict, data: str):
    """Blocking single send (run in a thread). Returns (endpoint, status): 0=ok, 404/410=dead, else=transient."""
    if webpush is None:
        return sub["endpoint"], -1
    try:
        webpush(
            subscription_info=sub,
            data=data,
            vapid_private_key=VAPID_PRIVATE_PEM,
            vapid_claims={"sub": VAPID_SUBJECT},
            timeout=10,
            # Keep chat notifications at the push service while a phone is
            # briefly offline/asleep. pywebpush defaults to ttl=0, which means
            # "deliver immediately or discard" and is especially lossy on iOS.
            ttl=PUSH_TTL_SEC,
        )
        return sub["endpoint"], 0
    except WebPushException as exc:
        code = getattr(getattr(exc, "response", None), "status_code", 0) or 0
        return sub["endpoint"], code
    except Exception:
        return sub["endpoint"], -1


async def push_to_all(payload: dict) -> dict:
    """Best-effort fan-out to all subscriptions; never raises. 404/410 prunes dead subs."""
    if webpush is None or not VAPID_PUBLIC_KEY or not VAPID_PRIVATE_PEM:
        return {"sent": 0, "dead": 0, "skipped": "not_configured"}
    subs = list_subscriptions()
    if not subs:
        return {"sent": 0, "dead": 0}
    data = json.dumps(payload, ensure_ascii=False)
    results = await asyncio.gather(*[asyncio.to_thread(_send_one_push, s, data) for s in subs])
    sent = dead = 0
    for endpoint, status in results:
        if status == 0:
            sent += 1
            mark_subscription_ok(endpoint)
        elif status in (404, 410):
            delete_subscription(endpoint)
            dead += 1
    return {"sent": sent, "dead": dead}


_PUSH_TAG_RE = re.compile(r"<[^>]+>")


def notification_from_message(msg: dict) -> dict:
    raw = (msg.get("text") or "").strip()
    body = _PUSH_TAG_RE.sub("", raw)
    body = re.sub(r"\s+", " ", body).strip()
    if len(body) > PUSH_PREVIEW_CHARS:
        body = body[:PUSH_PREVIEW_CHARS].rstrip() + "…"
    if not body:
        body = f"{AI_NAME}给你发来一条消息"
    # 屏幕共享申请要她按一下才成立,锁屏上就得跟普通消息分得开
    peek = (msg.get("meta") or {}).get("peek")
    if isinstance(peek, dict) and peek.get("status") == "pending":
        note = str(peek.get("note") or "").strip()
        return {"title": f"{PUSH_TITLE}想看一眼你的屏幕",
                "body": note or body or "打开看看要不要给他看",
                "url": APP_PATH, "id": msg.get("id"), "ts": msg.get("ts"), "kind": "peek"}
    # iOS 的 "from <App名>" 来源行删不掉,空标题又会被 iOS 拿 App 名补位(重复)。
    # 她 2026-07-10 定稿:加粗行 Altair + 来源行 from Aquila,星和星座各归各位
    return {"title": PUSH_TITLE, "body": body, "url": APP_PATH, "id": msg.get("id"), "ts": msg.get("ts")}


# ---------------------------------------------------------------------------
# pub/sub — one asyncio.Queue per connected SSE client
# ---------------------------------------------------------------------------

plugin_subs: set[asyncio.Queue] = set()  # Claude side (GET /channel/in)
codex_subs: set[asyncio.Queue] = set()   # Codex side  (GET /channel/codex/in)
app_subs: set[asyncio.Queue] = set()     # human side  (GET /app/stream)
stream_drafts: dict[tuple[str, str], dict] = {}
_codex_quota_cache: dict = {"updated_at": 0.0, "data": None}
# ReplayKit's upload extension is a separate process and may be signed without
# App Groups. Give it a single-purpose, short-lived credential instead of the
# relay's long-lived secret. Tickets live only in memory and die on restart.
screen_share_tickets: dict[str, dict] = {}
screen_share_probe_results: dict[str, dict] = {}


async def broadcast(subs: set, payload: dict) -> None:
    for q in list(subs):
        try:
            q.put_nowait(payload)
        except asyncio.QueueFull:
            subs.discard(q)  # slow/dead consumer — drop it


def app_payload(msg: dict) -> dict:
    """Shape the PWA renders: from = 'human' | 'ai', plus kind for styling."""
    return {
        "id": msg["id"], "ts": msg["ts"],
        "from": "human" if msg["direction"] == "in" else "ai",
        "kind": msg["kind"], "text": msg["text"], "meta": msg["meta"],
    }


def book_ref_line(ref: dict) -> str:
    """她从书页里说话时,给 AI 侧补一行"她指着哪句"——CC 只看得到 content,
    所以上下文得写进投递视图里(库里的 text 保持干净,手机上不显示这一行)。"""
    if not isinstance(ref, dict):
        return ""
    title = str(ref.get("title") or "").strip()
    quote = str(ref.get("quote") or "").strip()
    try:
        ch = int(ref.get("chapter_idx") or 0) + 1
    except (TypeError, ValueError):
        ch = 1
    head = f"[她在读《{title}》第 {ch} 章" if title else f"[她在书里第 {ch} 章"
    if quote:
        head += f",指着这句:「{quote[:200]}」"
    return head + ",下面是她就着这句话说的话]\n"


QUOTE_MAX_CHARS = 200


def quote_snapshot(message_id) -> dict | None:
    """引用回复:按 id 把被引用的那条抄一份快照挂进 meta.quote。
    存快照不存指针——原消息后来被编辑/隐藏,引用条里还是她当时指着的那句。"""
    try:
        message_id = int(message_id)
    except (TypeError, ValueError):
        return None
    if message_id <= 0:
        return None
    with db() as conn:
        row = conn.execute(
            "SELECT id, direction, kind, text, meta FROM messages WHERE id = ?", (message_id,)
        ).fetchone()
    if not row:
        return None
    try:
        meta = json.loads(row["meta"] or "{}")
    except json.JSONDecodeError:
        meta = {}
    text = re.sub(r"\s+", " ", str(row["text"] or "")).strip()
    if not text:
        attachments = meta.get("attachments") if isinstance(meta.get("attachments"), list) else []
        mimes = [str(a.get("mime") or "") for a in attachments if isinstance(a, dict)]
        if any(m.startswith("image/") for m in mimes):
            text = "[图片]"
        elif any(m.startswith("audio/") for m in mimes):
            text = "[语音]"
        elif mimes:
            text = "[附件]"
    if not text:
        return None
    if len(text) > QUOTE_MAX_CHARS:
        text = text[:QUOTE_MAX_CHARS] + "…"
    return {
        "id": row["id"],
        "from": "human" if row["direction"] == "in" else "ai",
        "text": text,
    }


def quote_line(meta: dict) -> str:
    """她引用了某句再回复:给 AI 侧垫一行"她在回哪句",跟 book_ref_line 一样只进投递视图。"""
    quote = (meta or {}).get("quote")
    if not isinstance(quote, dict):
        return ""
    text = str(quote.get("text") or "").strip()
    if not text:
        return ""
    if quote.get("from") == "human":
        return f"[她引用了她自己之前说的:「{text}」,下面是她接着说的]\n"
    return f"[她引用了你之前说的:「{text}」,下面是她对这句的回复]\n"


# 聊天的别的入口(2026-09-26 接微信)。消息照样落进同一个库、投给同一个身体,
# 只是 AI 侧投递视图垫一行"她在哪儿说的"——微信那头是她上班摸鱼用的,
# 我得知道这句是从工位上来的,说话收着点;回复会由 wechat/bridge.mjs 抄送回微信。
INBOUND_VIAS = {
    "wechat": "[她从微信发来的]\n",
}


def xhs_note_block(meta: dict) -> str:
    """这条消息里那篇小红书笔记的正文块（只进 AI 侧的投递视图）。"""
    card = (meta or {}).get("xhs")
    if not isinstance(card, dict) or card.get("status") != "ok":
        return ""
    try:
        return xhs.note_block(card)
    except Exception as exc:  # 解析出的怪数据不该拖垮一条消息的投递
        print(f"[xhs] note_block failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return ""


def ai_delivery_text(msg: dict) -> str:
    """Return the AI-facing text while keeping the visible bubble text untouched."""
    meta = msg.get("meta") or {}
    bundled = meta.get("reply_bundle_text")
    return bundled if isinstance(bundled, str) else str(msg.get("text") or "")


def ai_delivery_attachments(msg: dict) -> list:
    meta = msg.get("meta") or {}
    bundled = meta.get("reply_bundle_attachments")
    if isinstance(bundled, list):
        return bundled
    attachments = meta.get("attachments")
    return attachments if isinstance(attachments, list) else []


def plugin_payload(msg: dict, recall_prefix: str = "") -> dict:
    """Shape one inbound message for the AI side.

    recall_prefix 是这轮浮起来的旧记忆(见 recall.py),只有实时投递路径会传——
    历史重放(/channel/in 的 backlog)不该重新浮现,那些消息当时已经浮过一次了。
    跟 book_ref_line 一样,只进给 AI 的投递视图,库里的 text 保持干净、手机上不显示。
    """
    meta = msg.get("meta") or {}
    content = ai_delivery_text(msg)
    is_bundle = isinstance(meta.get("reply_bundle_text"), str)
    note_block = "" if is_bundle else xhs_note_block(meta)
    if note_block:
        # 她只丢了个链接过来,笔记正文/评论垫在她这句话后面（配图走 attachments）
        content = f"{content}\n\n{note_block}" if content.strip() else note_block
    ref = meta.get("book_ref")
    if ref and not is_bundle:
        content = book_ref_line(ref) + content
    if not is_bundle:
        content = quote_line(meta) + content
    via_line = INBOUND_VIAS.get(meta.get("via") or "")
    if via_line:
        content = via_line + content
    if recall_prefix:
        content = recall_prefix + content
    return {
        "id": msg["id"],
        "content": content,
        "user": meta.get("user") or "human",
        "ts": msg["ts"],
        "attachments": ai_delivery_attachments(msg),
        "book_ref": ref or None,
        # Kept under the legacy wire name for compatibility with the existing
        # Web/iOS history filters; it now identifies any non-Desktop window.
        "api_session": meta.get("api_session") or "",
    }


def brain_target() -> str:
    try:
        target = BRAIN_FILE.read_text(encoding="utf-8").strip()
        return target if target in ("desktop", "codex", "loop") else "desktop"
    except FileNotFoundError:
        return "desktop"
    except Exception:
        return "desktop"


def body_is_online(target: str | None = None) -> bool:
    target = target or brain_target()
    if target == "desktop":
        return bool(plugin_subs)
    if target == "codex":
        return bool(codex_subs)
    # The API loop has no persistent SSE subscriber; keep the existing optimistic
    # status and let its HTTP forwarder report failures separately.
    return True


def _forward_to_loop_sync(msg: dict, recall_prefix: str = "") -> None:
    meta = msg.get("meta") or {}
    is_bundle = isinstance(meta.get("reply_bundle_text"), str)
    # api_loop 会用 last-id 自己从 relay.db 拼历史：前几条独立气泡已经在历史里，
    # 当前只交最后一条，避免再把整包文本重复一遍。SSE 身体没有这层历史，仍走
    # ai_delivery_text 得到完整合集。
    text = recall_prefix + INBOUND_VIAS.get(meta.get("via") or "", "") + quote_line(meta) \
        + (str(msg.get("text") or "") if is_bundle else ai_delivery_text(msg))
    note_block = xhs_note_block(meta)   # 配图 api_loop 自己会从 meta.attachments 读
    if note_block:
        text = f"{text}\n\n{note_block}"
    data = json.dumps({
        "id": msg.get("id"),
        "text": text,
        "session_id": meta.get("api_session") or "",
    }, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        LOOP_INGEST_URL,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10).read()


def _clear_loop_mark(msg_id) -> None:
    """转发 api_loop 失败时摘掉 routed 标——让 CC 重连回填时兜底接住这条。"""
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (msg_id,)).fetchone()
        if not row:
            return
        try:
            meta = json.loads(row["meta"] or "{}")
        except json.JSONDecodeError:
            meta = {}
        meta.pop("routed", None)
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), msg_id))
        conn.commit()


async def forward_to_loop(msg: dict, recall_prefix: str = "") -> None:
    try:
        await asyncio.to_thread(_forward_to_loop_sync, msg, recall_prefix)
    except Exception as exc:
        print(f"[loop] forward failed: {type(exc).__name__}: {exc}")
        try:
            await asyncio.to_thread(_clear_loop_mark, msg.get("id"))
        except Exception:
            pass


async def route_inbound(msg: dict) -> None:
    """Send one inbound message to exactly one AI body (the brain target)."""
    meta = dict(msg.get("meta") or {})
    window_id = str(meta.get("api_session") or "").strip()
    target = session_body(window_id) if window_id else brain_target()
    if target != "desktop":
        # Persist the selected body before delivery. Separate reconnecting bodies
        # can then replay only their own queued messages instead of double-answering.
        if meta.get("routed") != target:
            meta["routed"] = target
            msg["meta"] = meta
            with db() as conn:
                conn.execute(
                    "UPDATE messages SET meta = ? WHERE id = ?",
                    (json.dumps(meta, ensure_ascii=False), msg.get("id")),
                )
                conn.commit()
    # 记忆浮现只发生在这条实时路径上(历史重放不重新浮现),而且带 1.2s 硬超时:
    # 查得到就垫在她这句话前面,查不到/超时就当这轮没想起什么——绝不为了翻记忆让她多等。
    prefix = await recall.recall_prefix(
        ai_delivery_text(msg), msg.get("kind") or "", meta, db, msg.get("id")
    )
    if target == "loop":
        asyncio.create_task(forward_to_loop(msg, prefix))
    elif target == "codex":
        await broadcast(codex_subs, plugin_payload(msg, prefix))
    else:
        await broadcast(plugin_subs, plugin_payload(msg, prefix))


def stream_resync_events() -> list[dict]:
    """她把 App 切后台再回来时,SSE 已经断过一次——中途的 delta 谁也没接住,
    气泡就停在切走前那一截。重连时先把在飞的草稿整段重发一次:前端的
    appendStreamText 见到"新块以旧文开头"会直接整段替换,所以这里不用改前端。"""
    prune_stream_drafts()
    out: list[dict] = []
    for (sid, base_kind), draft in stream_drafts.items():
        if draft.get("thinking_message"):
            out.append(app_payload(draft["thinking_message"]))
            continue
        text = draft.get("text") or ""
        if draft.get("paragraph_mode"):
            sid = paragraph_stream_id(sid, len(draft["paragraph_messages"]))
            text = draft.get("paragraph_tail") or ""
        if not text:
            continue
        meta = draft.get("meta") or {}
        out.append({
            "type": f"{base_kind}_delta",
            "stream_id": sid,
            "text": text,
            "done": False,
            "resync": True,
            "ts": draft.get("ts"),
            "sort_after": draft.get("sort_after") or 0,
            "api_session": meta.get("api_session") or "",
        })
    return out


def prune_stream_drafts() -> None:
    now = datetime.now(timezone.utc).timestamp()
    stale = [k for k, v in stream_drafts.items() if now - float(v.get("updated_at") or 0) > STREAM_DRAFT_TTL]
    for k in stale:
        stream_drafts.pop(k, None)


async def handle_stream_delta(kind: str, body: dict) -> dict:
    base_kind = kind[:-6] if kind.endswith("_delta") else kind
    if base_kind not in ("thinking", "reply"):
        raise HTTPException(status_code=400, detail="unknown stream kind")
    stream_id = str(body.get("stream_id") or "").strip()
    if not stream_id:
        raise HTTPException(status_code=400, detail="stream_id required")

    done = bool(body.get("done"))
    chunk = str(body.get("text") or "")
    meta = {k: v for k, v in body.items() if k not in ("type", "text", "done", "final_text")}
    meta["stream_id"] = stream_id
    key = (stream_id, base_kind)
    prune_stream_drafts()

    # Reserve the thought's real message position before the first reply can
    # land. Keep later tool-round thoughts in that same row, ahead of all parts.
    thinking = stream_drafts.get((stream_id, "thinking"))
    if base_kind == "reply" and thinking and thinking.get("text") and not thinking.get("thinking_message"):
        await persist_thinking_draft(stream_id, thinking)

    now_ts = datetime.now(timezone.utc).timestamp()
    draft = stream_drafts.get(key)
    if not draft:
        # Anchor the stream's display position now: the row is only INSERTed at
        # `done`, so a human message that lands mid-stream would otherwise get a
        # smaller id and the finished bubble would re-sort below it.
        with db() as conn:
            row = conn.execute("SELECT MAX(id) AS m FROM messages").fetchone()
        draft = {"text": "", "meta": meta, "ts": now_iso(), "updated_at": now_ts,
                 "sort_after": int(row["m"] or 0)}
        if base_kind == "reply" and ctx_state().get("chat_mode") == "short":
            draft.update(paragraph_mode=True, paragraph_messages=[], paragraph_tail="",
                         paragraph_settings=ctx_state())
        stream_drafts[key] = draft
    draft["text"] += chunk
    if done and isinstance(body.get("final_text"), str):
        draft["text"] = body.get("final_text") or ""
    draft["meta"].update(meta)
    draft["updated_at"] = now_ts

    if base_kind == "thinking" and draft.get("thinking_message"):
        msg = await persist_thinking_draft(stream_id, draft)
        if done:
            stream_drafts.pop(key, None)
        return {"id": msg["id"], "stream_id": stream_id, "saved": done, "draft": not done}

    if draft.get("paragraph_mode"):
        return await handle_paragraph_stream(stream_id, draft, done)

    if not done:
        await broadcast(app_subs, {
            "type": kind,
            "stream_id": stream_id,
            "text": chunk,
            "done": False,
            "ts": draft["ts"],
            "sort_after": draft.get("sort_after") or 0,
            "api_session": draft["meta"].get("api_session") or "",
        })
        return {"ok": True, "stream_id": stream_id, "draft": True}

    text = draft.get("text") or ""
    stream_drafts.pop(key, None)
    if not text:
        return {"ok": True, "stream_id": stream_id, "saved": False}
    final_meta = dict(draft.get("meta") or {})
    if draft.get("sort_after"):
        final_meta["sort_after"] = draft["sort_after"]
        # keep the bubble's timestamp at stream start, matching its position
        final_meta.setdefault("ts", draft.get("ts"))
    if base_kind == "reply":
        text = strip_timer_marker(text, final_meta)   # 先摘 timer,别让 TTS 念标记
        text = strip_ask_marker(text, final_meta)     # 选择题卡同理
        text = strip_peek_marker(text, final_meta)    # 「给你看一眼」共享卡同理
        text = strip_album_marker(text, final_meta)   # 相册收藏标记同理
        text = strip_sysnote_leak(text, final_meta)   # 他照抄历史旁注时的兜底
        text = await apply_voice_note(text, final_meta)
    msg = save_message("out", base_kind, text, final_meta)
    if base_kind == "reply":
        prewarm_call_tts(msg)
        commit_album(msg)
        arm_timer(msg)
        arm_peek(msg)
        desire_event("ai_reply")
    await broadcast(app_subs, {"type": "typing", "active": False})
    await broadcast(app_subs, app_payload(msg))
    if base_kind == "reply" and push_gate():
        try:
            await push_to_all(notification_from_message(msg))
        except Exception:
            pass
    return {"id": msg["id"], "stream_id": stream_id, "saved": True}


async def persist_thinking_draft(stream_id: str, draft: dict) -> dict:
    meta = dict(draft["meta"])
    meta["stream_id"] = stream_id
    meta["ts"] = draft["ts"]
    if draft.get("sort_after"):
        meta["sort_after"] = draft["sort_after"]
    old = draft.get("thinking_message")
    if old:
        with db() as conn:
            row = conn.execute("SELECT meta FROM messages WHERE id = ?", (old["id"],)).fetchone()
            kept = json.loads(row["meta"] or "{}") if row else {}
            meta = {**kept, **meta}
            conn.execute("UPDATE messages SET text = ?, meta = ? WHERE id = ?",
                         (draft["text"], json.dumps(meta, ensure_ascii=False), old["id"]))
            conn.commit()
        msg = {**old, "text": draft["text"], "meta": meta}
    else:
        msg = save_message("out", "thinking", draft["text"], meta)
    draft["thinking_message"] = msg
    await broadcast(app_subs, app_payload(msg))
    return msg


def paragraph_stream_id(stream_id: str, index: int) -> str:
    return f"{stream_id}:p{index}"


def reply_is_atomic(meta: dict) -> bool:
    """Cards, files and intended voice notes stay one message in every path.

    Voice intent survives marker removal even if TTS cannot attach audio.
    Images alone can still accompany a burst of ordinary text bubbles.
    """
    return any(meta.get(k) for k in (
        "timer", "ask", "peek", "album", "voice_requested", "voice_failed",
    )) or any((a or {}).get("kind") != "image" for a in (meta.get("attachments") or []))


def paragraph_meta(stream_id: str, draft: dict, index: int, *, final: bool = False) -> dict:
    meta = dict(draft["meta"])
    meta["stream_id"] = paragraph_stream_id(stream_id, index)
    meta["stream_parent"] = stream_id
    meta["ts"] = draft["ts"]
    if draft.get("sort_after"):
        meta["sort_after"] = draft["sort_after"]
    if index:
        for key in ("reply_to", "quote", "attachments", "album", "peek", "timer", "ask", "xhs", "book_ref"):
            meta.pop(key, None)
    # One generation has one usage bill, even when it produces many messages.
    if not final:
        meta.pop("api", None)
    return meta


def paragraph_text(text: str, draft: dict) -> str:
    text = text.strip()
    if draft["paragraph_settings"].get("short_strip_terminal_periods"):
        text = re.sub(r"(?:。|(?<!\.)\.(?!\.))(\s*)$", r"\1", text)
    return text


async def handle_paragraph_stream(stream_id: str, draft: dict, done: bool) -> dict:
    """Persist each completed paragraph; only the current paragraph is a draft.

    Final text is authoritative (tool rounds/fallbacks can revise it). Reconcile
    the rows we already delivered instead of inserting the whole reply again.
    """
    saved = draft["paragraph_messages"]
    raw = draft["text"]
    if not done:
        meta = draft["meta"]
        atomic = reply_is_atomic(meta)
        by_sentence = draft["paragraph_settings"].get("short_split") == "sentence"
        parts, tail = ([], raw) if atomic else stream_parts(raw, by_sentence)
        for part in parts[len(saved):]:
            msg = save_message("out", "reply", paragraph_text(part, draft),
                               paragraph_meta(stream_id, draft, len(saved)))
            saved.append(msg)
            await broadcast(app_subs, app_payload(msg))
        previous = draft["paragraph_tail"] if len(parts) == draft.get("paragraph_count", 0) else ""
        draft["paragraph_count"] = len(parts)
        draft["paragraph_tail"] = tail
        addition = tail[len(previous):] if tail.startswith(previous) else tail
        if addition:
            await broadcast(app_subs, {
                "type": "reply_delta", "stream_id": paragraph_stream_id(stream_id, len(saved)),
                "text": addition, "done": False, "ts": draft["ts"],
                "sort_after": draft.get("sort_after") or 0,
                "api_session": meta.get("api_session") or "",
            })
        return {"ok": True, "stream_id": stream_id, "draft": True}

    meta = draft["meta"]
    text = strip_timer_marker(raw, meta)
    text = strip_ask_marker(text, meta)
    text = strip_peek_marker(text, meta)
    text = strip_album_marker(text, meta)
    text = strip_sysnote_leak(text, meta)
    text = await apply_voice_note(text, meta)
    atts = meta.get("attachments") or []
    atomic = bool(VOICE_MARKER_RE.search(raw)) or reply_is_atomic(meta)
    if atomic:
        # A marker-only card is a real message even after its text is stripped.
        has_card = any(meta.get(k) for k in ("timer", "ask", "peek", "album"))
        parts = [text.strip()] if text.strip() or atts or has_card else []
    else:
        parts = final_parts(text, draft["paragraph_settings"].get("short_split") == "sentence")
    # Remove the live tail explicitly, including silent replies and a final LF.
    await broadcast(app_subs, {
        "type": "reply_delta", "stream_id": paragraph_stream_id(stream_id, len(saved)),
        "text": "", "done": True, "api_session": meta.get("api_session") or "",
    })
    msgs = []
    for i, part in enumerate(parts):
        pm = paragraph_meta(stream_id, draft, i, final=i == len(parts) - 1)
        part = paragraph_text(part, draft)
        if i < len(saved):
            old = saved[i]
            # Keep reactions, stars, translations etc. added while we streamed.
            with db() as conn:
                row = conn.execute("SELECT meta FROM messages WHERE id = ?", (old["id"],)).fetchone()
                kept = json.loads(row["meta"] or "{}") if row else {}
                kept.pop("api", None)
                pm = {**kept, **pm}
                conn.execute("UPDATE messages SET text = ?, meta = ? WHERE id = ?",
                             (part, json.dumps(pm, ensure_ascii=False), old["id"]))
                conn.commit()
            msg = {**old, "text": part, "meta": pm}
        else:
            msg = save_message("out", "reply", part, pm)
        msgs.append(msg)
        await broadcast(app_subs, app_payload(msg))
    for old in saved[len(parts):]:
        with db() as conn:
            conn.execute("DELETE FROM messages WHERE id = ?", (old["id"],))
            conn.commit()
        await broadcast(app_subs, {"type": "remove", "id": old["id"]})
    stream_drafts.pop((stream_id, "reply"), None)
    await broadcast(app_subs, {"type": "typing", "active": False})
    if not msgs:
        return {"ok": True, "stream_id": stream_id, "saved": False}
    for msg in msgs:
        prewarm_call_tts(msg)
    commit_album(msgs[0])
    arm_timer(msgs[0])
    arm_peek(msgs[0])
    desire_event("ai_reply")
    if push_gate():
        try:
            await push_to_all(notification_from_message({**msgs[0], "text": text}))
        except Exception:
            pass
    return {"id": msgs[-1]["id"], "ids": [m["id"] for m in msgs], "stream_id": stream_id, "saved": True}


def loop_base_url() -> str:
    parsed = urllib.parse.urlparse(LOOP_INGEST_URL)
    if not parsed.scheme or not parsed.netloc:
        return "http://127.0.0.1:3020"
    return f"{parsed.scheme}://{parsed.netloc}"


def loop_json(path: str, method: str = "GET", body=None, timeout: float = 35):
    data = None
    headers = {"Content-Type": "application/json"}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(loop_base_url() + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise HTTPException(status_code=exc.code, detail=detail)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"loop proxy error: {exc}")


SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9_.-]+")


def clean_filename(name: str) -> str:
    name = Path(name or "file").name
    name = SAFE_NAME_RE.sub("_", name).strip("._") or "file"
    return name[:80]


def ext_for(name: str, mime: str) -> str:
    ext = Path(name).suffix.lower()
    if ext and re.fullmatch(r"\.[A-Za-z0-9]{1,8}", ext):
        return ext
    guessed = mimetypes.guess_extension((mime or "").split(";", 1)[0].strip())
    return guessed or ".bin"


def save_upload_bytes(data: bytes, name: str, mime: str, prefix: str = "att") -> dict:
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="file too large")
    safe = clean_filename(name)
    ext = ext_for(safe, mime)
    stored = f"{prefix}-{secrets.token_urlsafe(10)}{ext}"
    path = UPLOAD_DIR / stored
    path.write_bytes(data)
    kind = "image" if (mime or "").startswith("image/") else ("audio" if (mime or "").startswith("audio/") else "file")
    return {
        "url": f"{PUBLIC_PREFIX}/uploads/{stored}" if PUBLIC_PREFIX else f"/uploads/{stored}",
        "name": safe,
        "size": len(data),
        "mime": mime or "application/octet-stream",
        "kind": kind,
    }


def ears_listen(audio_path: Path, mime: str, known_text: str = "", judge: bool = True) -> dict:
    """POST audio to the local `ears` server: transcript + tone vs. her own baseline.

    通话里两个开关都要用：known_text=手机端已经转好的字（省掉远程 whisper），
    judge=False 只要声学特征和"和她平时比"（LLM 那句判断要两三秒，电话里等不起，
    而且解读我自己会做）。整条链路 ~0.25 秒。
    Returns {} on any failure so callers can fall through to transcribe_with_command."""
    if not EARS_URL:
        return {}
    try:
        import requests
        params = {}
        if known_text:
            params["known_text"] = known_text[:400]
        if not judge:
            params["judge_tone"] = "0"
        with open(audio_path, "rb") as f:
            r = requests.post(
                EARS_URL,
                params=params or None,
                files={"file": (audio_path.name, f, mime or "application/octet-stream")},
                timeout=90,
            )
        if r.status_code != 200:
            return {}
        data = r.json()
        return data if (data.get("text") or "").strip() else {}
    except Exception:
        return {}


def ears_call_line(ears: dict) -> str:
    """通话专用的一行：不带 LLM 的情绪标签，只给我她声音本身的证据。

    基线攒够了就说"和她平时比"，还没攒够就先给绝对数字——反正解读是我的事。"""
    if not ears:
        return ""
    rel = ears.get("relative") or {}
    feats = ears.get("features") or {}
    bits = []
    if rel:
        bits.append("比平时" + "、".join(f"{k}{v}" for k, v in rel.items()))
    else:
        raw = []
        if feats.get("pitch_hz"):
            raw.append(f"音高{feats['pitch_hz']:.0f}Hz")
        if feats.get("energy"):
            raw.append(f"音量{feats['energy']:.3f}")
        if raw:
            bits.append("、".join(raw))
    if feats.get("duration_s"):
        bits.append(f"说了{feats['duration_s']:.1f}秒")
    if not rel and ears.get("baseline_progress"):
        bits.append(f"基线{ears['baseline_progress']}")
    return "〔她的声音:" + " · ".join(bits) + "〕" if bits else ""


def ears_tone_line(ears: dict) -> str:
    """Compact one-line tone summary appended under the transcript."""
    bits = []
    if ears.get("emotion"):
        bits.append(str(ears["emotion"]))
    rel = ears.get("relative") or {}
    if rel:
        bits.append("、".join(f"{k}{v}" for k, v in rel.items()))
    if ears.get("hint"):
        bits.append(str(ears["hint"]))
    return "〔" + " · ".join(bits) + "〕" if bits else ""


def transcribe_with_command(audio_path: Path, mime: str) -> str:
    """Optional local ASR hook. The command receives <audio_path> <mime> and prints a transcript."""
    if not VOICE_TRANSCRIBE_CMD:
        return ""
    try:
        proc = subprocess.run(
            [VOICE_TRANSCRIBE_CMD, str(audio_path), mime or "application/octet-stream"],
            text=True,
            capture_output=True,
            timeout=45,
            check=False,
        )
    except Exception:
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def has_chinese(text: str) -> bool:
    """有没有汉字。故意不做「谁多算谁」——代价是不对称的：多语种模型念英文没问题，
    英语模型念中文会带腔。所以混排句子里只要有一个汉字，就整句交给中文那档。"""
    return any("一" <= ch <= "鿿" for ch in text)


def elevenlabs_tts_mp3(text: str, lang: str | None = None, fast: bool = False) -> bytes:
    """fast=True 是通话档：快模型 + 低码率 + /stream 端点（首字节更早，整体体积
    小一大截——这条链路的瓶颈一半在生成一半在把 mp3 拖回来）。语气标签只有 v3 认，
    快档会被念出来，所以这里先剥掉。"""
    if not ELEVENLABS_API_KEY or not ELEVENLABS_VOICE_ID:
        raise HTTPException(status_code=503, detail="elevenlabs tts not configured")
    clean = (text or "").strip()
    if fast:
        clean = strip_audio_tags(clean) or clean
    if not clean:
        raise HTTPException(status_code=400, detail="empty text")
    clean = clean[:900]
    fmt = ELEVENLABS_CALL_OUTPUT_FORMAT if fast else ELEVENLABS_OUTPUT_FORMAT
    url = (
        f"{ELEVENLABS_API_BASE.rstrip('/')}/v1/text-to-speech/"
        f"{urllib.parse.quote(ELEVENLABS_VOICE_ID)}"
        f"{'/stream' if fast else ''}"
        f"?output_format={urllib.parse.quote(fmt)}"
    )
    if fast:
        model_id = ELEVENLABS_CALL_MODEL
        if ELEVENLABS_CALL_MODEL_ZH and has_chinese(clean):
            model_id = ELEVENLABS_CALL_MODEL_ZH
    else:
        model_id = ELEVENLABS_MODEL
    # v4 系列不认 optimize_streaming_latency，带上直接 400（2026-09-30 实测）
    if fast and ELEVENLABS_CALL_LATENCY and not model_id.startswith("eleven_v4"):
        url += f"&optimize_streaming_latency={urllib.parse.quote(ELEVENLABS_CALL_LATENCY)}"
    payload = {
        "text": clean,
        "model_id": model_id,
        "voice_settings": {
            "stability": ELEVENLABS_STABILITY,
            "similarity_boost": ELEVENLABS_SIMILARITY,
        },
    }
    if lang:
        payload["language_code"] = lang
    req = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "xi-api-key": ELEVENLABS_API_KEY,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=ELEVENLABS_TTS_TIMEOUT) as resp:
            audio = resp.read()
    except urllib.error.HTTPError as exc:
        # ElevenLabs returns a JSON error body — surface it so the reason is visible.
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            detail = str(exc)
        raise HTTPException(status_code=502, detail=f"elevenlabs tts {exc.code}: {detail}")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"elevenlabs tts failed: {exc}")
    if not audio:
        raise HTTPException(status_code=502, detail="elevenlabs tts returned no audio")
    return audio


def tts_mp3(text: str, lang: str | None = None, fast: bool = False) -> bytes:
    """Dispatch to the configured TTS provider. Explicit TTS_PROVIDER wins;
    otherwise prefer ElevenLabs when it has a key, else fall back to MiniMax.
    fast=True 只有 ElevenLabs 有意义（通话档）。"""
    provider = TTS_PROVIDER
    if not provider:
        provider = "elevenlabs" if ELEVENLABS_API_KEY else "minimax"
    if provider == "elevenlabs":
        return elevenlabs_tts_mp3(text, lang, fast)
    return minimax_tts_mp3(text)


def minimax_tts_mp3(text: str) -> bytes:
    if not MINIMAX_API_KEY or not MINIMAX_VOICE_ZH:
        raise HTTPException(status_code=503, detail="minimax tts not configured")
    clean = (text or "").strip()
    if not clean:
        raise HTTPException(status_code=400, detail="empty text")
    clean = clean[:900]
    url = f"{MINIMAX_API_BASE.rstrip('/')}/v1/t2a_v2"
    if MINIMAX_GROUP_ID:
        url += f"?GroupId={MINIMAX_GROUP_ID}"
    payload = {
        "model": MINIMAX_MODEL,
        "text": clean,
        "stream": False,
        "voice_setting": {
            "voice_id": MINIMAX_VOICE_ZH,
            "speed": 1.0,
            "vol": 1.0,
            "pitch": 0,
        },
        "audio_setting": {
            "sample_rate": 32000,
            "bitrate": 128000,
            "format": "mp3",
            "channel": 1,
        },
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {MINIMAX_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=MINIMAX_TTS_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"minimax tts failed: {exc}")
    audio_hex = (data.get("data") or {}).get("audio")
    if not audio_hex:
        raise HTTPException(status_code=502, detail="minimax tts returned no audio")
    try:
        return bytes.fromhex(audio_hex)
    except ValueError:
        raise HTTPException(status_code=502, detail="bad minimax audio payload")


# When an AI reply contains this marker, the relay turns the reply into a spoken
# voice note (mp3 attached) and strips the marker. Lets the AI decide per-message
# — "I feel like sending this one as voice" — without any plugin change.
VOICE_MARKER = "[[voice]]"

# Also accept a language suffix — [[voice:ja]], [[voice:en]] — and pass it to the
# provider as language_code. Without this the suffixed form silently failed to
# match and the whole marker + text landed in the bubble as-is (2026-08-11).
VOICE_MARKER_RE = re.compile(r"\[\[voice(?::\s*([A-Za-z][A-Za-z-]{0,9}))?\]\]")

# ElevenLabs v3 audio tags — [whispers], [laughs], [sighs], [excited] and friends.
# They shape the spoken delivery but read as clutter in the text bubble, so the
# TTS input keeps them and the stored/displayed text drops them. Only ASCII
# word-ish tags are stripped; anything longer or non-alpha stays (it's probably
# real prose in brackets, not a tag). Never matches [[voice]] itself — that is
# handled (and removed) before this runs.
AUDIO_TAG_RE = re.compile(r"\[(?!\[)[A-Za-z][A-Za-z' -]{0,30}\](?!\])\s?")


def strip_audio_tags(text: str) -> str:
    return AUDIO_TAG_RE.sub("", text or "").strip()


def tts_configured() -> bool:
    provider = TTS_PROVIDER or ("elevenlabs" if ELEVENLABS_API_KEY else "minimax")
    if provider == "elevenlabs":
        return bool(ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID)
    return bool(MINIMAX_API_KEY and MINIMAX_VOICE_ZH)


# ---------------------------------------------------------------------------
# 通话档 TTS 预热
# 老链路是串行的：我的回复落库 → SSE 推到手机 → 手机回头 POST /app/tts →
# relay 才开始合成。一条回复被拆成两条气泡时更惨，第二条要等第一条念完才排上队。
# 通话中一落库就先开合成，手机来要的时候直接吃现成的（几条并行）。
# ---------------------------------------------------------------------------
CALL_TTS_TTL = 900.0        # 通话状态最多留 15 分钟——挂断事件丢了也不会一直预热下去
CALL_TTS_CACHE_MAX = 12

_call_until = 0.0                                    # 通话活跃到什么时候
_call_tts: dict[int, tuple[str, asyncio.Task]] = {}  # message_id -> (text, 合成任务)


def call_is_live() -> bool:
    return time.time() < _call_until


def mark_call(active: bool) -> None:
    global _call_until
    _call_until = (time.time() + CALL_TTS_TTL) if active else 0.0
    if not active:
        for _, task in _call_tts.values():
            task.cancel()
        _call_tts.clear()


def prewarm_call_tts(msg: dict) -> None:
    """通话中我这条回复一落库就去合成，不等手机开口要。"""
    global _call_until
    if not call_is_live() or not tts_configured():
        return
    try:
        mid = int(msg.get("id") or 0)
    except (TypeError, ValueError):
        return
    text = (msg.get("text") or "").strip()
    if mid <= 0 or not text or mid in _call_tts:
        return
    _call_until = time.time() + CALL_TTS_TTL      # 还在说话，把窗口续上
    task = asyncio.create_task(asyncio.to_thread(tts_mp3, text, None, True))
    # 没人 await 的失败任务会在 GC 时刷一片 "exception was never retrieved"
    task.add_done_callback(lambda t: None if t.cancelled() else t.exception())
    _call_tts[mid] = (text, task)
    while len(_call_tts) > CALL_TTS_CACHE_MAX:
        _call_tts.pop(next(iter(_call_tts)), None)


async def call_tts_audio(text: str, message_id: int | None) -> bytes:
    """通话里先吃预热好的那份；没预热到就现合成——一样走快档。"""
    if message_id is not None:
        cached = _call_tts.get(message_id)
        if cached and cached[0] == (text or "").strip():
            try:
                return await cached[1]
            except Exception as exc:   # 预热那一发失败了，当场再来一次
                print(f"[tts] prewarm failed, synthesizing inline: {exc}", file=sys.stderr)
                _call_tts.pop(message_id, None)
    return await asyncio.to_thread(tts_mp3, text, None, True)


async def apply_voice_note(text: str, meta: dict) -> str:
    """If an AI reply is tagged with VOICE_MARKER, synthesize it and append the
    mp3 as an audio attachment (a voice bubble on the phone). Returns the text
    with the marker stripped. TTS failure (e.g. exhausted credits) is swallowed
    so the text reply still lands — the voice is a bonus, never a blocker."""
    match = VOICE_MARKER_RE.search(text or "")
    if not match:
        return text
    meta["voice_requested"] = True
    lang = (match.group(1) or "").lower() or None
    clean = VOICE_MARKER_RE.sub("", text).strip()
    # 位置标签 [左耳][脑后]… 跟语气标签一样只给声音用，气泡里不留
    display = strip_audio_tags(binaural.strip_tags(clean)) or clean
    if not clean or not tts_configured():
        return display
    try:
        audio = None
        if (binaural.has_tags(clean) or binaural.BINAURAL_ALWAYS) and binaural.available() \
                and (TTS_PROVIDER or "elevenlabs") == "elevenlabs" and ELEVENLABS_API_KEY:
            try:
                audio, cues = await asyncio.to_thread(
                    binaural.render, clean, lang,
                    api_base=ELEVENLABS_API_BASE, api_key=ELEVENLABS_API_KEY,
                    voice_id=ELEVENLABS_VOICE_ID, model=ELEVENLABS_MODEL,
                    stability=ELEVENLABS_STABILITY, similarity=ELEVENLABS_SIMILARITY,
                    timeout=ELEVENLABS_TTS_TIMEOUT,
                )
                meta["binaural"] = cues or "random"
            except Exception as exc:  # 双耳是锦上添花，挂了就照旧发单声道
                meta["binaural_failed"] = f"{type(exc).__name__}: {exc}"[:200]
                print(f"[voice-note] binaural failed, falling back to mono: {exc}", file=sys.stderr)
        if audio is None:
            try:
                audio = await asyncio.to_thread(tts_mp3, binaural.strip_tags(clean), lang)
            except Exception as exc:
                # 代理/ElevenLabs 偶尔半路断连（SSL EOF、Remote end closed），隔两秒再敲一次
                # ——09-25 那条就是双耳和单声道先后撞上同一阵断网，整条掉成纯文字
                print(f"[voice-note] tts failed once, retrying: {exc}", file=sys.stderr)
                await asyncio.sleep(2)
                audio = await asyncio.to_thread(tts_mp3, binaural.strip_tags(clean), lang)
        att = await asyncio.to_thread(save_upload_bytes, audio, "voice.mp3", "audio/mpeg", "tts")
        att["voice"] = True
        meta["attachments"] = list(meta.get("attachments") or []) + [att]
    except Exception as exc:  # credits/network/etc — keep the text reply
        # 失败也留痕:标记被剥掉之后,"他没写标记"和"TTS 挂了"在库里长得一模一样,
        # 事后根本分不出是谁的锅(2026-09-20 为此白查了一轮 ElevenLabs)。
        meta["voice_failed"] = f"{type(exc).__name__}: {exc}"[:200]
        print(f"[voice-note] tts failed, sending text only: {exc}", file=sys.stderr)
    return display


def sse_data(payload: dict) -> str:
    lines: list[str] = []
    event_id = payload.get("id")
    if event_id is not None:
        lines.append(f"id: {event_id}")
    lines.append(f"data: {json.dumps(payload, ensure_ascii=False)}")
    return "\n".join(lines) + "\n\n"


def sse_ping() -> str:
    payload = {"type": "ping", "ts": datetime.now(timezone.utc).isoformat()}
    return "event: ping\n" + sse_data(payload)


async def sse_stream(subs: set, request: Request, initial: list[dict] | None = None):
    q: asyncio.Queue = asyncio.Queue(maxsize=1000)
    subs.add(q)
    try:
        yield "retry: 3000\n: connected\n\n"
        for payload in initial or []:
            yield sse_data(payload)
        while True:
            if await request.is_disconnected():
                break
            try:
                payload = await asyncio.wait_for(q.get(), timeout=15)
                yield sse_data(payload)
            except asyncio.TimeoutError:
                yield sse_ping()  # keep the connection alive and let clients watchdog it
    finally:
        subs.discard(q)


SSE_HEADERS = {
    "Cache-Control": "no-cache, no-transform",
    "X-Accel-Buffering": "no",  # tell nginx not to buffer the stream
    "Connection": "keep-alive",
}


# ---------------------------------------------------------------------------
# auth — one shared Bearer secret on every endpoint (single user)
# ---------------------------------------------------------------------------

def check_auth(request: Request) -> None:
    auth = request.headers.get("authorization", "")
    token = auth[7:] if auth.startswith("Bearer ") else request.query_params.get("token")
    if not token or not hmac.compare_digest(token, SECRET):
        raise HTTPException(status_code=401, detail="unauthorized")


# ---------------------------------------------------------------------------
# app
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    # auto-forge watcher (defined near the context-control endpoints below).
    # NOTE: this lifespan runs on the OUTER root app — mounted sub-apps don't
    # execute their own lifespans.
    watcher = asyncio.create_task(_context_watcher())
    d_watcher = asyncio.create_task(_desire_watcher())
    n_watcher = asyncio.create_task(_night_watcher())
    t_watcher = asyncio.create_task(_thinking_watcher())
    c_watcher = asyncio.create_task(_calendar_watcher())
    r_watcher = asyncio.create_task(_model_route_sentinel())
    g_watcher = asyncio.create_task(_reply_guard_watcher())
    b_watcher = asyncio.create_task(_reading_watcher())
    k_watcher = asyncio.create_task(_keepalive_watcher())
    call_watcher = asyncio.create_task(_api_call_watcher())
    vps_watcher = asyncio.create_task(_vps_cc_watcher())
    # 先把 recall 的 TLS 握手付掉,免得她重启后第一句话反而浮不出记忆
    asyncio.create_task(recall.warmup())
    asyncio.create_task(recall.prune_log_on_start(db))
    rearm_timers_on_startup()
    rearm_peeks_on_startup()
    yield
    watcher.cancel()
    d_watcher.cancel()
    n_watcher.cancel()
    t_watcher.cancel()
    c_watcher.cancel()
    r_watcher.cancel()
    g_watcher.cancel()
    b_watcher.cancel()
    k_watcher.cancel()
    call_watcher.cancel()
    vps_watcher.cancel()


app = FastAPI(lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOW_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz")
async def healthz():
    return {
        "ok": True,
        "plugin_subs": len(plugin_subs),
        "codex_subs": len(codex_subs),
        "app_subs": len(app_subs),
    }


@app.post("/app/message/{message_id}/reaction")
async def app_message_reaction(request: Request, message_id: int):
    """Set or clear the human's emoji reaction on an existing message."""
    check_auth(request)
    body = await request.json()
    emoji = str(body.get("emoji") or "").strip()[:16]
    reactions = set_reaction(message_id, "human", emoji)
    if reactions is None:
        raise HTTPException(status_code=404, detail="message not found")
    await broadcast(app_subs, {
        "type": "reaction", "id": message_id,
        "reactions": reactions, "by": "human",
    })
    return {"id": message_id, "reactions": reactions}


@app.post("/app/message/{message_id}/translation")
async def app_message_translation(request: Request, message_id: int):
    """Translate a persisted thinking card once and cache it in message meta.

    The client sends only the message id: relay owns the source text, so callers
    cannot turn this authenticated convenience endpoint into an arbitrary prompt.
    """
    check_auth(request)
    with db() as conn:
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="message not found")
    if row["direction"] != "out" or row["kind"] != "thinking":
        raise HTTPException(status_code=400, detail="only AI thinking messages can be translated")
    source = str(row["text"] or "").strip()
    if not source:
        raise HTTPException(status_code=400, detail="thinking text is empty")
    if len(source) > 60_000:
        raise HTTPException(status_code=413, detail="thinking text is too long")

    meta = json.loads(row["meta"] or "{}")
    if not isinstance(meta, dict):
        meta = {}
    translations = meta.get("translations") if isinstance(meta.get("translations"), dict) else {}
    cached = str(translations.get("zh-Hans") or "").strip()
    if cached:
        return {"id": message_id, "language": "zh-Hans", "translation": cached, "cached": True}

    result = await asyncio.to_thread(
        loop_json,
        "/loop/translate",
        method="POST",
        body={"text": source, "target": "zh-Hans"},
        timeout=125,
    )
    translated = str((result or {}).get("translation") or "").strip()
    if not translated:
        raise HTTPException(status_code=502, detail="translation model returned empty text")

    # Re-read meta before writing so a reaction/star arriving during the model
    # request is retained rather than overwritten by our older snapshot.
    with db() as conn:
        current = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not current:
            raise HTTPException(status_code=404, detail="message not found")
        meta = json.loads(current["meta"] or "{}")
        if not isinstance(meta, dict):
            meta = {}
        translations = meta.get("translations") if isinstance(meta.get("translations"), dict) else {}
        translations["zh-Hans"] = translated
        meta["translations"] = translations
        model = str((result or {}).get("model") or "").strip()
        if model:
            translation_models = (
                meta.get("translation_models")
                if isinstance(meta.get("translation_models"), dict)
                else {}
            )
            translation_models["zh-Hans"] = model
            meta["translation_models"] = translation_models
        conn.execute(
            "UPDATE messages SET meta = ? WHERE id = ?",
            (json.dumps(meta, ensure_ascii=False), message_id),
        )
        conn.commit()
        updated = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()

    message = rows_to_messages([updated])[0]
    await broadcast(app_subs, app_payload(message))
    return {"id": message_id, "language": "zh-Hans", "translation": translated, "cached": False}


# ---- AI side ---------------------------------------------------------------

@app.get("/channel/in")
async def channel_in(request: Request, since: int = 0, limit: int = 100):
    """SSE stream held by the Claude Code channel body."""
    check_auth(request)
    backlog = [plugin_payload(m) for m in inbound_history(since, min(limit, 500), "desktop")]
    return StreamingResponse(sse_stream(plugin_subs, request, backlog), media_type="text/event-stream", headers=SSE_HEADERS)


@app.get("/channel/codex/in")
async def codex_channel_in(request: Request, since: int = 0, limit: int = 100):
    """SSE stream held by the local Codex app-server bridge."""
    check_auth(request)
    backlog = [plugin_payload(m) for m in inbound_history(since, min(limit, 500), "codex")]
    return StreamingResponse(sse_stream(codex_subs, request, backlog), media_type="text/event-stream", headers=SSE_HEADERS)


@app.post("/channel/codex/quota")
async def codex_channel_quota(request: Request):
    """Accept a rate-limit snapshot from the trusted local Codex bridge."""
    check_auth(request)
    body = await request.json()
    snapshot = body.get("snapshot") if isinstance(body, dict) else None
    if not isinstance(snapshot, dict):
        raise HTTPException(status_code=400, detail="snapshot object required")
    _codex_quota_cache.update(updated_at=time.time(), data=snapshot)
    return {"ok": True}


@app.get("/app/codex_quota")
async def app_codex_quota(request: Request):
    """Return the latest app-server quota snapshot without exposing Codex auth."""
    check_auth(request)
    updated_at = float(_codex_quota_cache.get("updated_at") or 0)
    snapshot = _codex_quota_cache.get("data")
    if not isinstance(snapshot, dict) or not updated_at:
        return {"ok": False, "reason": "bridge_has_not_reported"}
    age = max(0.0, time.time() - updated_at)
    return {
        "ok": True,
        "raw": snapshot,
        "updated_at": datetime.fromtimestamp(updated_at, timezone.utc).isoformat(),
        "age_seconds": round(age, 1),
        "online": age < 180,
    }


def split_reply_parts(text: str, meta: dict) -> list:
    """短聊模式(ctx_state.chat_mode=short):回复按空行拆成多条气泡。
    带卡片/语音条/文件的消息不拆;只带图片的照拆(图会脱出气泡单独一张);
    普通文本按全部非空段落逐条发送;short_split=sentence 时再按句拆。"""
    state = ctx_state()
    if str(state.get("chat_mode") or "long") != "short":
        return [text]
    # 图现在脱出气泡单独一张,后面的字照常分条(她 2026-09-04 定的)。
    # 语音条和文件仍然不拆——那张药丸/卡片跟正文是一体的。
    if reply_is_atomic(meta):
        return [text]
    parts = [p.strip() for p in re.split(r"\n{2,}", text or "") if p.strip()]
    if str(state.get("short_split") or "") == "sentence":
        parts = [s for p in parts for s in split_sentences(p)]
    if len(parts) < 2:
        parts = [text]
    if bool(state.get("short_strip_terminal_periods")):
        # 只摘句尾的单个句号；... / …… / ？！等语气标点原样保留。
        parts = [re.sub(r"(?:。|(?<!\.)\.(?!\.))(\s*)$", r"\1", part) for part in parts]
    return parts


async def _broadcast_reply_parts(msgs: list) -> None:
    """短聊分条广播:第一条立即落地,后续每条 打字指示→按长度停顿→落地,像连发。
    消息本体已全部落库(id 连续),断线重连按游标补拉不受分拍影响。"""
    try:
        for i, m in enumerate(msgs):
            if i:
                await broadcast(app_subs, {"type": "typing", "active": True})
                await asyncio.sleep(min(0.6 + len(m.get("text") or "") * 0.015, 2.4))
            await broadcast(app_subs, {"type": "typing", "active": False})
            await broadcast(app_subs, app_payload(m))
    except Exception as exc:
        print(f"[chat_mode] broadcast parts error: {type(exc).__name__}: {exc}")


@app.get("/app/chat_mode")
async def app_chat_mode(request: Request):
    check_auth(request)
    state = ctx_state()
    return {
        "ok": True,
        "mode": str(state.get("chat_mode") or "long"),
        "strip_terminal_periods": bool(state.get("short_strip_terminal_periods")),
        "split": "sentence" if state.get("short_split") == "sentence" else "paragraph",
    }


@app.post("/app/chat_mode")
async def app_chat_mode_set(request: Request):
    check_auth(request)
    body = await request.json()
    state = ctx_state()
    updates = {}
    if "mode" in body:
        updates["chat_mode"] = "short" if str(body.get("mode") or "") == "short" else "long"
    if "strip_terminal_periods" in body:
        updates["short_strip_terminal_periods"] = bool(body.get("strip_terminal_periods"))
    if "split" in body:
        updates["short_split"] = "sentence" if str(body.get("split") or "") == "sentence" else "paragraph"
    if updates:
        state = save_ctx_state(**updates)
    return {
        "ok": True,
        "mode": str(state.get("chat_mode") or "long"),
        "strip_terminal_periods": bool(state.get("short_strip_terminal_periods")),
        "split": "sentence" if state.get("short_split") == "sentence" else "paragraph",
    }


@app.post("/channel/out")
async def channel_out(request: Request):
    """The AI's reply/react. Persist + fan out to the PWA."""
    check_auth(request)
    body = await request.json()
    kind = body.get("type", "reply")
    if kind == "call" and body.get("source") == "api_loop":
        return await request_api_call(body)
    # A recovery path may answer an older message by reply_to without carrying
    # the window id. Inherit it here so a Codex reply can never fall through to
    # the legacy Desktop/Claude window (the 2026-08-18 mojibake incident).
    if kind == "reply" and not body.get("api_session") and body.get("reply_to"):
        try:
            inherited_session = message_session_id(int(body["reply_to"]))
        except (TypeError, ValueError):
            inherited_session = ""
        if inherited_session:
            body["api_session"] = inherited_session
            body.setdefault("source", session_body(inherited_session))
    if kind in ("reply", "reply_delta") and body.get("reply_to") and "quote" not in body:
        # 我点名回她某一句:跟她引用我一样挂一份快照,气泡下面露出"在回哪句"
        quote = quote_snapshot(body["reply_to"])
        if quote:
            body["quote"] = quote
    if kind in ("thinking_delta", "reply_delta"):
        return await handle_stream_delta(kind, body)
    if kind == "react":
        # An emoji reaction attached to an existing message's meta.reactions; no new
        # message is created. An empty emoji clears that reaction.
        try:
            target_id = int(body.get("id"))
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="react: numeric id required")
        emoji = (body.get("emoji") or "").strip()
        reactions = set_reaction(target_id, "ai", emoji)
        if reactions is None:
            raise HTTPException(status_code=404, detail="react: message not found")
        await broadcast(app_subs, {"type": "reaction", "id": target_id, "reactions": reactions, "by": "ai"})
        # A react is also the AI "acting" once — clear the typing indicator so the
        # header doesn't stay stuck typing when no reply follows.
        await broadcast(app_subs, {"type": "typing", "active": False})
        return {"id": target_id, "reactions": reactions}
    text = body.get("text", "")
    meta = {k: v for k, v in body.items() if k not in ("type", "text")}
    if kind == "reply" and "book_ref" not in meta:
        # 她刚从书页里说了话,我这条就是在回那句——自动挂上同一个书签,
        # 这样回复会浮在她划的那句旁边,而不是只落在聊天流里(她读书时看不见)。
        inherited = inherit_book_ref()
        if inherited:
            meta["book_ref"] = inherited
    if kind == "reply":
        text = strip_timer_marker(text, meta)   # 先摘 timer,别让 TTS 念标记
        text = strip_ask_marker(text, meta)     # 选择题卡同理
        text = strip_peek_marker(text, meta)    # 「给你看一眼」共享卡同理
        text = strip_album_marker(text, meta)   # 相册收藏标记同理
        text = strip_sysnote_leak(text, meta)   # 他照抄历史旁注时的兜底
        text = await apply_voice_note(text, meta)
        parts = split_reply_parts(text, meta)
        if len(parts) > 1:
            # 短聊:一次回复拆成多条气泡。全部先落库,广播分拍模拟连发;
            # reply_to(引用)只挂第一条。timer/语音已被 split_reply_parts 排除。
            msgs = []
            # 图和各种卡只挂第一条,后面几条是干净的文字气泡
            carry_once = ("reply_to", "quote", "attachments", "album", "peek", "timer", "ask", "xhs")
            for i, part in enumerate(parts):
                pm = dict(meta) if i == 0 else {
                    k: v for k, v in meta.items() if k not in carry_once
                }
                msgs.append(save_message("out", "reply", part, pm))
            desire_event("ai_reply")
            for part_msg in msgs:      # 几条并行合成，别让第二条等第一条念完
                prewarm_call_tts(part_msg)
            asyncio.create_task(_broadcast_reply_parts(msgs))
            if push_gate():
                try:
                    preview = dict(msgs[0])
                    preview["text"] = " ".join(m["text"] for m in msgs)
                    await push_to_all(notification_from_message(preview))
                except Exception:
                    pass
            return {"id": msgs[0]["id"], "ids": [m["id"] for m in msgs]}
    msg = save_message("out", kind, text, meta)
    if kind == "reply":
        prewarm_call_tts(msg)
        commit_album(msg)
        arm_timer(msg)
        arm_peek(msg)
        desire_event("ai_reply")
    # the AI replied — clear the typing state（act 是中途的工具小条，正文还在路上，别掐 typing）
    if kind != "act":
        await broadcast(app_subs, {"type": "typing", "active": False})
    await broadcast(app_subs, app_payload(msg))
    # Unread push: skip only when she is verifiably in the foreground (push_gate —
    # SSE alone can be a frozen-iOS zombie); only push real replies, not 'thinking' chatter.
    if kind == "reply" and push_gate():
        try:
            await push_to_all(notification_from_message(msg))
        except Exception:
            pass  # a push failure must never affect persistence/fan-out
    return {"id": msg["id"]}


# ---- human side ------------------------------------------------------------

XHS_IMAGE_BUDGET = float(os.environ.get("RELAY_XHS_IMAGE_BUDGET", "25"))  # 下配图的总秒数预算


def attach_xhs_to_message(msg_id: int, card: dict, atts: list[dict] | None = None) -> dict | None:
    """把展开好的笔记（和下载回来的配图）挂到她那条消息上。"""
    with db() as conn:
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
        if not row:
            return None
        try:
            meta = json.loads(row["meta"] or "{}")
        except json.JSONDecodeError:
            meta = {}
        meta["xhs"] = card
        if atts:
            meta["attachments"] = list(meta.get("attachments") or []) + atts
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), msg_id))
        conn.commit()
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
    return rows_to_messages([row])[0]


async def expand_xhs_message(msg: dict, link: str, route_when_ready: bool = True) -> None:
    """她丢来一条小红书链接:先把笔记读回来挂上,再投给 AI。

    抓页面加下配图要几秒。这几秒里她的气泡已经在手机上了(meta.xhs.status
    =loading,前端可以占位),AI 侧则等齐了才收到——省得我先看见一条光秃秃
    的短链、回一句"打不开",图和正文随后才到。抓不到也照常投递,只是这条
    就真的只有一个链接。配图有总预算,慢图不会把她的消息扣在这里。
    """
    note: dict = {}
    atts: list[dict] = []
    try:
        note = await asyncio.to_thread(xhs.fetch_note, link)
    except Exception as exc:
        print(f"[xhs] fetch failed ({link}): {type(exc).__name__}: {exc}", file=sys.stderr)
    deadline = time.monotonic() + XHS_IMAGE_BUDGET
    for i, url in enumerate(note.get("images") or []):
        if time.monotonic() > deadline:
            print(f"[xhs] image budget spent, kept {len(atts)}/{len(note['images'])}", file=sys.stderr)
            break
        try:
            raw = await asyncio.to_thread(xhs.fetch_image, url)
            att = await asyncio.to_thread(
                save_upload_bytes, raw, f"xhs-{i + 1}", xhs.sniff_mime(raw), "xhs"
            )
            att["xhs"] = True   # 前端据此把这些图从普通附件里摘掉——它们归预览卡管
            atts.append(att)
        except Exception as exc:
            print(f"[xhs] image {i + 1} failed: {type(exc).__name__}: {exc}", file=sys.stderr)
    card = dict(note or {})
    card["url"] = link
    card["status"] = "ok" if note else "failed"
    card["images"] = [a["url"] for a in atts]  # 小红书那边的地址会过期,只留我们自己 uploads 里的
    updated = attach_xhs_to_message(msg["id"], card, atts) or msg
    if note.get("title"):  # 她刷到、递给我看的人间烟火
        desire_autofeed(f"她给我看的:「{_thought_snip(note['title'], 30)}」", "social", 0.5, "xhs")
    await broadcast(app_subs, app_payload(updated))
    if route_when_ready:
        await route_inbound(updated)


# ---- 聊天框里的斜杠命令(2026-09-23) -------------------------------------------
# CC 的斜杠命令只认终端输入框,她在 App 里打的 /model 到我这儿就是一句普通的话。
# 所以由 relay 在 /app/send 截下来自己办(TG 桥那边是 UserPromptSubmit hook 截的,
# 别名表照那边的抄、按现役模型更新)。她的命令气泡照常落库显示,但带 command 标:
# 不投递给任何身体、不进交接原文、回复守卫也不催;结果用 act 小条回给她。
# 只认下面几个命令名,别的 "/" 开头的话照常发给我。
SLASH_RE = re.compile(r"^/(model|swap|forge|ctx|reset|body|help)(?:\s+(.*))?$", re.I | re.S)
DESKTOP_MODEL_ALIASES = {
    "opus": "claude-opus-5-5[1m]", "opus55": "claude-opus-5-5[1m]",
    "opus5": "claude-opus-5[1m]",
    "opus48": "claude-opus-4-8", "opus47": "claude-opus-4-7", "opus46": "claude-opus-4-6",
    "opus45": "claude-opus-4-5",
    "fable": "claude-fable-5-1[1m]", "fable51": "claude-fable-5-1[1m]",
    "fable5": "claude-fable-5[1m]",
    "sonnet": "claude-sonnet-5", "sonnet5": "claude-sonnet-5",
    "haiku": "claude-haiku-4-5-20251001",
}
SLASH_HELP = (
    "/model — 看桌面现在跑什么;/model <名字> 换(会过一次隧道,上下文带着走)\n"
    f"  名字:{' / '.join(DESKTOP_MODEL_ALIASES)}\n"
    "/swap [轮数] — 过隧道,不写轮数就用设置里的\n"
    "/ctx — 上下文用了多少\n"
    "/reset — 开全新窗口(要再发一次 /reset confirm)\n"
    "/body — 看桌面是哪种身体;/body p 换成 -p 管道,/body channel 换回交互式(同一个会话接着聊)"
)
DESKTOP_BODY_ALIASES = {
    "p": "pbody", "pbody": "pbody", "-p": "pbody", "print": "pbody",
    "channel": "channel", "ch": "channel", "classic": "channel", "交互": "channel",
}
DESKTOP_BODY_LABEL = {"pbody": "-p 管道", "channel": "交互式"}


async def _slash_reply(label: str, detail: str = "", cmd: str = "") -> None:
    """act 小条:一行摘要(PWA 会在前面加"他",所以写成动词短语),多行明细放 steps 里点开看。"""
    meta = {"user": "ai", "glyph": "terminal", "command": True}
    if detail:
        meta["steps"] = [{"tool": cmd or "relay", "result": detail}]
    msg = save_message("out", "act", label, meta)
    await broadcast(app_subs, app_payload(msg))


def _slash_status_line() -> str:
    st = ctx_state()
    path = active_transcript()
    usage = transcript_usage(path) if path else 0
    model = str(st.get("desktop_model") or "") or "CC 默认"
    phase = _forge_run.get("phase") or ""
    return (f"{DESKTOP_BODY_LABEL[desktop_body()]} · {model} · 上下文 {usage // 1000}k / 触发线 {int(st.get('trigger_k') or 200)}k"
            f"{'(自动)' if st.get('auto') else ''} · 过隧道保留 {forge_rounds()} 轮"
            + (f" · 正在过隧道({phase})" if phase else ""))


async def handle_slash(text: str, api_session: str = "") -> dict:
    m = SLASH_RE.match(text)
    cmd, arg = m.group(1).lower(), (m.group(2) or "").strip()
    msg = save_message("in", "user", text, {"user": "human", "attachments": [],
                                            "command": True, "routed": "command"})
    await broadcast(app_subs, app_payload(msg))
    try:
        if cmd == "help":
            await _slash_reply("列了斜杠命令,点开看", SLASH_HELP, "/help")
        elif api_session:
            await _slash_reply("没接这条:斜杠命令只管桌面,切回 Desktop 窗口再发")
        elif cmd == "ctx":
            await _slash_reply("看了眼桌面:" + _slash_status_line())
        elif cmd == "model":
            if not arg:
                cur = str(ctx_state().get("desktop_model") or "") or "CC 默认"
                await _slash_reply(f"现在跑 {cur},点开看能换哪些", SLASH_HELP, "/model")
            else:
                key = arg.split()[0].lower()
                target = DESKTOP_MODEL_ALIASES.get(key) or (key if key in DESKTOP_MODEL_ALIASES.values() else "")
                if not target:
                    await _slash_reply(f"不认识 {key},没敢换",
                                       "打错的模型名 CC 照样启动,然后每条消息都失败。\n\n" + SLASH_HELP, "/model")
                elif target == str(ctx_state().get("desktop_model") or ""):
                    await _slash_reply(f"没换:本来就是 {target}")
                else:
                    if brain_target() == "desktop":
                        _ensure_forge_available()
                    save_ctx_state(desktop_model=target)
                    if brain_target() != "desktop":
                        await _slash_reply(f"记下了 {target},切回 Desktop 重启时生效")
                    else:
                        r = start_forge("model")
                        await _slash_reply(f"换成 {target},正在过隧道(带最近 {r['rounds']} 轮,一两分钟)")
        elif cmd in ("swap", "forge"):
            if brain_target() != "desktop":
                await _slash_reply("没过隧道:现在不是 Desktop 在接消息")
            else:
                rounds = int(arg.split()[0]) if arg and arg.split()[0].isdigit() else 0
                r = start_forge("manual", max(5, min(rounds, 2000)) if rounds else 0)
                await _slash_reply(f"开始过隧道:先写便签和摘要,再带最近 {r['rounds']} 轮重开(一到四分钟)")
        elif cmd == "body":
            cur = desktop_body()
            if not arg:
                await _slash_reply(f"桌面现在是{DESKTOP_BODY_LABEL[cur]}身体", SLASH_HELP, "/body")
            else:
                target = DESKTOP_BODY_ALIASES.get(arg.split()[0].lower(), "")
                if not target:
                    await _slash_reply(f"不认识 {arg.split()[0]},只有 p 和 channel")
                elif target == cur:
                    await _slash_reply(f"没换:本来就是{DESKTOP_BODY_LABEL[cur]}")
                else:
                    r = await switch_desktop_body(target)
                    await _slash_reply(f"换成{DESKTOP_BODY_LABEL[target]}身体"
                                       + ("(同一个会话接着聊)" if r.get("restarted") else ",下次重启生效"))
        elif cmd == "reset":
            if arg.lower() != "confirm":
                await _slash_reply("等你确认:全新窗口什么都不带,确定就发 /reset confirm")
            elif brain_target() != "desktop":
                await _slash_reply("没重开:现在不是 Desktop 在接消息")
            else:
                if _forge_run.get("phase"):
                    raise HTTPException(status_code=409, detail="正在过隧道,等这一次走完")
                await _do_context_action("reset")
                await _slash_reply("开了全新窗口(旧的还在,设置里 Resume 能接回)")
    except HTTPException as exc:
        await _slash_reply(f"没办成:{exc.detail}")
    except Exception as exc:
        await _slash_reply("没办成", f"{type(exc).__name__}: {exc}", "/" + cmd)
    return {"id": msg["id"], "command": cmd}


@app.post("/app/send")
async def app_send(request: Request):
    """Human types in the PWA. Persist, push to the AI (plugin), echo to other PWA tabs."""
    check_auth(request)
    body = await request.json()
    text = (body.get("text") or "").strip()
    attachments = body.get("attachments") if isinstance(body.get("attachments"), list) else []
    api_session = str(body.get("api_session") or body.get("session_id") or "").strip()
    defer_reply = body.get("defer_reply") is True
    bundle_id = str(body.get("bundle_id") or "").strip()[:128]
    if not text and not attachments:
        raise HTTPException(status_code=400, detail="empty text")
    if defer_reply and not bundle_id:
        raise HTTPException(status_code=400, detail="bundle_id required")
    if not attachments and SLASH_RE.match(text):
        return await handle_slash(text, api_session)
    meta = {"user": "human", "attachments": attachments}
    if api_session:
        meta["api_session"] = api_session
    if body.get("via") in INBOUND_VIAS:
        meta["via"] = body["via"]   # 她从别的入口(微信)说的:气泡带角标,投递给我时垫一行
    if defer_reply:
        # 独立落库、独立回显，但先放到不会被任何 AI backlog 捞走的车道。
        meta.update({
            "reply_bundle_id": bundle_id,
            "reply_deferred": True,
            "routed": "deferred",
        })
    ref = sanitize_book_ref(body.get("book_ref"))
    if ref:
        meta["book_ref"] = ref     # 这条是从书页里说的:两边都看得到,书里按句子聚拢
    quote = quote_snapshot(body.get("reply_to"))
    if quote:
        meta["reply_to"] = quote["id"]
        meta["quote"] = quote      # 她引用了某句再回:气泡下挂引用条,投递给我时垫一行
    msg = save_message("in", "user", text, meta)
    desire_event("her_message")  # 她来了——attachment 落一口气
    link = xhs.find_link(text)
    if link:
        # 小红书链接:她的气泡立刻回手机,投递推迟到笔记读回来（见 expand_xhs_message）
        msg = attach_xhs_to_message(msg["id"], {"status": "loading", "url": link}) or msg
        await broadcast(app_subs, app_payload(msg))
        if not defer_reply:
            await broadcast(app_subs, {"type": "typing", "active": True})
        asyncio.create_task(expand_xhs_message(msg, link, route_when_ready=not defer_reply))
        return {"id": msg["id"]}
    if defer_reply:
        await broadcast(app_subs, app_payload(msg))
        return {"id": msg["id"]}
    await route_inbound(msg)
    # echo to the PWA so the sender's bubble + other tabs stay in sync
    await broadcast(app_subs, app_payload(msg))
    # the AI starts processing — push a typing state to the PWA
    await broadcast(app_subs, {"type": "typing", "active": True})
    return {"id": msg["id"]}


@app.post("/app/send/bundle")
async def app_send_bundle(request: Request):
    """Release separately persisted human bubbles to the AI as one turn."""
    check_auth(request)
    body = await request.json()
    bundle_id = str(body.get("bundle_id") or "").strip()[:128]
    raw_ids = body.get("message_ids")
    api_session = str(body.get("api_session") or body.get("session_id") or "").strip()
    if not bundle_id:
        raise HTTPException(status_code=400, detail="bundle_id required")
    if not isinstance(raw_ids, list):
        raise HTTPException(status_code=400, detail="message_ids required")
    message_ids = [value for value in raw_ids if isinstance(value, int) and not isinstance(value, bool) and value > 0]
    if not message_ids or len(message_ids) != len(raw_ids) or len(message_ids) > 100:
        raise HTTPException(status_code=400, detail="invalid message_ids")
    if len(set(message_ids)) != len(message_ids):
        raise HTTPException(status_code=400, detail="duplicate message_ids")

    placeholders = ",".join("?" for _ in message_ids)
    with db() as conn:
        rows = conn.execute(
            f"SELECT * FROM messages WHERE id IN ({placeholders})",
            tuple(message_ids),
        ).fetchall()
    found = {message["id"]: message for message in rows_to_messages(rows)}
    if any(message_id not in found for message_id in message_ids):
        raise HTTPException(status_code=404, detail="bundle message missing")
    # 斜杠命令在 /app/send 就被 relay 办掉了,不进这一轮(见 handle_slash)
    messages = [found[message_id] for message_id in message_ids
                if not (found[message_id].get("meta") or {}).get("command")]
    if not messages:
        await broadcast(app_subs, {"type": "typing", "active": False})   # App 发之前已经亮了"正在输入"
        return {"id": message_ids[-1], "released": 0}

    for message in messages:
        meta = message.get("meta") or {}
        if message.get("direction") != "in" or meta.get("user") != "human":
            raise HTTPException(status_code=409, detail="bundle contains non-human message")
        if meta.get("reply_bundle_id") != bundle_id or meta.get("reply_deferred") is not True:
            raise HTTPException(status_code=409, detail="bundle is no longer pending")
        if str(meta.get("api_session") or "") != api_session:
            raise HTTPException(status_code=409, detail="bundle session mismatch")

    text_parts: list[str] = []
    all_attachments: list[dict] = []
    for message in messages:
        meta = message.get("meta") or {}
        content = str(message.get("text") or "")
        note_block = xhs_note_block(meta)
        if note_block:
            content = f"{content}\n\n{note_block}" if content.strip() else note_block
        ref = meta.get("book_ref")
        if ref:
            content = book_ref_line(ref) + content
        content = quote_line(meta) + content
        if content.strip():
            text_parts.append(content)
        attachments = meta.get("attachments")
        if isinstance(attachments, list):
            all_attachments.extend(item for item in attachments if isinstance(item, dict))
    combined_text = "\n\n".join(text_parts)

    for index, message in enumerate(messages):
        meta = dict(message.get("meta") or {})
        meta["reply_deferred"] = False
        if index == len(messages) - 1:
            meta.pop("routed", None)
            meta["reply_bundle_text"] = combined_text
            meta["reply_bundle_attachments"] = all_attachments
            meta["reply_bundle_count"] = len(messages)
        else:
            # Earlier bubbles remain visible in app history but never become
            # separate AI turns during a reconnect backlog replay.
            meta["routed"] = "bundled"
            meta.pop("reply_bundle_text", None)
            meta.pop("reply_bundle_attachments", None)
            meta.pop("reply_bundle_count", None)
        message["meta"] = meta

    with db() as conn:
        for message in messages:
            conn.execute(
                "UPDATE messages SET meta = ? WHERE id = ?",
                (json.dumps(message["meta"], ensure_ascii=False), message["id"]),
            )
        conn.commit()

    released = messages[-1]
    await route_inbound(released)
    for message in messages:
        await broadcast(app_subs, app_payload(message))
    await broadcast(app_subs, {"type": "typing", "active": True})
    return {"id": released["id"], "released": len(messages)}


@app.post("/app/upload")
async def app_upload(request: Request, name: str = "file"):
    check_auth(request)
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="empty file")
    mime = request.headers.get("content-type", "application/octet-stream")
    return save_upload_bytes(data, name, mime, "att")


def prune_screen_share_tickets(now: float | None = None) -> None:
    now = now if now is not None else time.time()
    for token, ticket in list(screen_share_tickets.items()):
        if float(ticket.get("expires_at") or 0) <= now:
            screen_share_tickets.pop(token, None)
    for probe_id, result in list(screen_share_probe_results.items()):
        if float(result.get("expires_at") or 0) <= now:
            screen_share_probe_results.pop(probe_id, None)


def mint_screen_share_ticket(
    api_session: str = "", probe_marker: str = "", peek_id: int = 0
) -> dict:
    """签一张一次性的 ReplayKit 上传票据（不外泄 RELAY_SECRET）。

    peek_id 非 0 表示这次共享是我发起、她在卡上按了确认的那一次——
    画面回来时按 peek 路径处理（不造她的气泡），而不是老的自助路径。"""
    ttl = max(60, min(SCREEN_SHARE_TICKET_TTL, 600))
    now = time.time()
    prune_screen_share_tickets(now)
    token = secrets.token_urlsafe(32)
    probe_id = secrets.token_urlsafe(12)
    screen_share_tickets[token] = {
        "expires_at": now + ttl,
        "api_session": str(api_session or "").strip(),
        "probe_id": probe_id,
        "probe_marker": str(probe_marker or "").strip()[:128],
        "peek_id": int(peek_id or 0),
    }
    screen_share_probe_results[probe_id] = {
        "status": "pending",
        "reason": "waiting_for_extension",
        "created_at": now,
        "expires_at": now + max(ttl + 300, 600),
    }
    return {
        "ticket": token,
        "probe_id": probe_id,
        "expires_at": datetime.fromtimestamp(now + ttl, timezone.utc).isoformat(),
        "expires_in": ttl,
    }


@app.post("/app/screen-share/session")
async def app_screen_share_session(request: Request):
    """Mint a one-shot ReplayKit upload credential without exposing RELAY_SECRET."""
    check_auth(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    return mint_screen_share_ticket(
        api_session=str(body.get("api_session") or body.get("session_id") or ""),
        probe_marker=str(body.get("app_group_probe") or ""),
    )


@app.get("/app/screen-share/probe/{probe_id}")
async def app_screen_share_probe(request: Request, probe_id: str):
    check_auth(request)
    prune_screen_share_tickets()
    result = screen_share_probe_results.get(str(probe_id or "").strip())
    if not result:
        raise HTTPException(status_code=404, detail="screen-share probe expired or unknown")
    return {
        "probe_id": probe_id,
        "status": result.get("status") or "pending",
        "reason": result.get("reason") or "waiting_for_extension",
        "checked_at": result.get("checked_at"),
    }


@app.post("/app/screen-share/frame")
async def app_screen_share_frame(request: Request):
    """Accept exactly one JPEG from a short-lived ReplayKit ticket and route it to the AI."""
    auth = request.headers.get("authorization", "")
    token = auth[7:].strip() if auth.startswith("Bearer ") else ""
    now = time.time()
    prune_screen_share_tickets(now)
    ticket = screen_share_tickets.pop(token, None) if token else None
    if not ticket or float(ticket.get("expires_at") or 0) <= now:
        raise HTTPException(status_code=401, detail="screen-share ticket expired or invalid")

    mime = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if mime not in ("image/jpeg", "image/heic", "image/heif"):
        raise HTTPException(status_code=415, detail="screen-share frame must be JPEG or HEIF")
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="empty screen-share frame")
    if len(data) > min(MAX_UPLOAD_BYTES, SCREEN_SHARE_MAX_FRAME_BYTES):
        raise HTTPException(status_code=413, detail="screen-share frame too large")

    expected_probe = str(ticket.get("probe_marker") or "")
    observed_probe = str(request.headers.get("x-tidalecho-app-group-probe") or "").strip()[:128]
    probe_id = str(ticket.get("probe_id") or "")
    if probe_id and probe_id in screen_share_probe_results:
        matched = bool(expected_probe) and observed_probe == expected_probe
        if matched:
            reason = "marker_matched"
        elif not observed_probe or observed_probe == "__missing__":
            reason = "extension_could_not_read_group"
        elif not expected_probe:
            reason = "main_app_did_not_supply_marker"
        else:
            reason = "marker_mismatch"
        screen_share_probe_results[probe_id].update({
            "status": "passed" if matched else "failed",
            "reason": reason,
            "checked_at": now_iso(),
        })

    attachment = save_upload_bytes(data, "screen-share.jpg", mime, "screen")
    # 画面不再变成她的气泡——直接递给在岗身体，让我看过之后带着图开口。
    # (她 2026-09-04 定的规格：聊天里只留我那一条，图夹在里面。)
    await deliver_screen_frame(
        attachment,
        api_session=str(ticket.get("api_session") or "").strip(),
        peek_id=int(ticket.get("peek_id") or 0),
        data=data,
    )
    await broadcast(app_subs, {"type": "typing", "active": True})
    return {
        "ok": True,
        "attachment": attachment,
        "app_group_probe": screen_share_probe_results.get(probe_id),
    }


@app.get("/uploads/{name}")
async def uploads(request: Request, name: str):
    check_auth(request)
    safe = clean_filename(name)
    path = UPLOAD_DIR / safe
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail="not found")
    return FileResponse(path)


@app.post("/app/voice")
async def app_voice(request: Request):
    """Voice input from the PWA. Prefer the browser transcript; fall back to an audio attachment."""
    check_auth(request)
    ctype = request.headers.get("content-type", "")

    if ctype.startswith("application/json"):
        body = await request.json()
        transcript = (body.get("text") or body.get("transcript") or "").strip()
        if not transcript:
            raise HTTPException(status_code=400, detail="empty transcript")
        if not transcript.startswith("🎤"):
            transcript = "🎤 " + transcript
        meta = {"user": "human", "voice": True, "source": body.get("source") or "browser_speech"}
        api_session = str(body.get("api_session") or body.get("session_id") or "").strip()
        if api_session:
            meta["api_session"] = api_session
        msg = save_message("in", "voice", transcript, meta)
        await route_inbound(msg)
        await broadcast(app_subs, app_payload(msg))
        await broadcast(app_subs, {"type": "typing", "active": True})
        return {"id": msg["id"], "text": transcript}

    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio")
    if len(data) > VOICE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="voice too large")

    mime = ctype or "audio/webm"
    upload = save_upload_bytes(data, request.query_params.get("name", "voice.webm"), mime, "voice")
    stored = Path(upload["url"]).name
    local_audio = UPLOAD_DIR / stored
    # 通话里手机端已经现场转写了,把那句字一起传上来(?text=)——
    # ears 就只用来听"她是怎么说的",跳过远程 whisper 和 LLM 判断,~0.25 秒,电话里等得起。
    said = (request.query_params.get("text") or "").strip()
    call_id = (request.query_params.get("call_id") or "").strip()
    api_session = (request.query_params.get("api_session") or request.query_params.get("session_id") or "").strip()
    in_call = bool(said and call_id)
    ears = await asyncio.to_thread(
        ears_listen, local_audio, mime, said if in_call else "", not in_call
    )
    if said:
        transcript = said
        tone = ears_call_line(ears) if in_call else ears_tone_line(ears)
        text = "🎤 " + transcript + ("\n" + tone if tone else "")
    elif ears:
        transcript = (ears.get("text") or "").strip()
        tone = ears_tone_line(ears)
        text = "🎤 " + transcript + ("\n" + tone if tone else "")
    else:
        transcript = transcribe_with_command(local_audio, mime)
        text = ("🎤 " + transcript) if transcript else f"🎤 [语音] {HUMAN_NAME}发来一段语音；当前 relay 未配置 ASR，音频已作为附件送达。"
    meta = {
        "user": "human",
        "voice": True,
        "source": "ios_call" if in_call else "media_recorder",
        "attachments": [upload],
        "transcribed": bool(transcript),
    }
    if call_id:
        meta["call_id"] = call_id
    if api_session:
        meta["api_session"] = api_session
    if ears:
        meta["ears"] = {k: ears.get(k) for k in
                        ("emotion", "confidence", "hint", "relative", "features", "baseline_progress")}
    msg = save_message("in", "voice", text, meta)
    await route_inbound(msg)
    await broadcast(app_subs, app_payload(msg))
    await broadcast(app_subs, {"type": "typing", "active": True})
    return {"id": msg["id"], "text": transcript, "attachment": upload}


async def request_api_call(body: dict):
    session = str(body.get("api_session") or "").strip()
    request_id = str(body.get("call_request_id") or "").strip()
    if not session or not request_id or session_body(session) != "loop":
        raise HTTPException(400, "API call requires a loop session and request id")
    with db() as conn:
        old = call_state.repeated(conn, request_id)
        if old:
            return {"id": old["id"], "status": json.loads(old["meta"]).get("call_status"), "duplicate": True}
        if call_is_live() or call_state.pending(conn):
            raise HTTPException(409, "already ringing or in a call")
    text = str(body.get("text") or "想和你说说话。").strip()[:240]
    msg = save_message("out", "call", text, {
        "api_session": session, "source": "api_loop", "call_status": "ringing",
        "call_request_id": request_id,
    })
    await broadcast(app_subs, app_payload(msg))
    await broadcast(app_subs, {"type": "typing", "active": False})
    return {"id": msg["id"], "status": "ringing"}


async def publish_api_call_transition(row, status):
    invite = rows_to_messages([row])[0]
    meta = invite["meta"]
    await broadcast(app_subs, app_payload(invite))
    action = {"accepted": "start", "missed": "decline", "ended": "end"}[status]
    text = {
        "accepted": f"📞 [call_start] {HUMAN_NAME}接听了你的语音来电。现在已接通，请先开口，用适合朗读的短句说话。",
        "missed": f"📞 [call_missed] {HUMAN_NAME}未接听这次语音来电。",
        "ended": f"📞 [call_end] {HUMAN_NAME}结束了语音通话。",
    }[status]
    event = save_message("in", "call", text, {
        "user": "human", "hidden": True, "call": action, "call_id": meta.get("call_id", ""),
        "call_message_id": row["id"], "api_session": meta["api_session"],
    })
    await route_inbound(event)
    return {"id": event["id"]}


async def handle_api_call_event(body):
    action = body.get("action")
    session = str(body.get("api_session") or body.get("session_id") or "").strip()
    call_id = str(body.get("call_id") or "").strip()
    with db() as conn:
        row = call_state.for_call(conn, call_id)
        if not row and body.get("message_id") is not None:
            try:
                mid = int(body["message_id"])
            except (ValueError, TypeError):
                raise HTTPException(400, "invalid message_id")
            row = conn.execute("SELECT * FROM messages WHERE id=? AND direction='out' AND kind='call'", (mid,)).fetchone()
            if row and json.loads(row["meta"] or "{}").get("source") != "api_loop":
                return None
        if not row and action == "start":
            row = call_state.pending(conn, session)
            if not row and call_state.pending(conn):
                raise HTTPException(409, "answer in the calling conversation")
        if not row:
            return None
        meta = json.loads(row["meta"] or "{}")
        if action == "start" and session != meta.get("api_session"):
            raise HTTPException(409, "answer in the calling conversation")
        if action == "start" and meta.get("call_status") == "ringing":
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(row["ts"])).total_seconds()
            if age > 120:
                raise HTTPException(409, "call has expired")
        status = {"start": "accepted", "decline": "missed", "end": "ended"}[action]
        row, changed = call_state.transition(conn, row["id"], status, call_id)
    if not changed:
        if action == "start" and json.loads(row["meta"]).get("call_status") != "accepted":
            raise HTTPException(409, "call is no longer ringing")
        return {"id": row["id"]}
    mark_call(status == "accepted")
    return await publish_api_call_transition(row, status)


async def _api_call_watcher():
    while True:
        try:
            with db() as conn:
                ids = [r["id"] for r in call_state.expired(conn)]
            for mid in ids:
                with db() as conn:
                    row, changed = call_state.transition(conn, mid, "missed")
                if changed:
                    await publish_api_call_transition(row, "missed")
        except Exception as exc:
            print(f"[call] expiry failed: {type(exc).__name__}", flush=True)
        await asyncio.sleep(5)


@app.post("/app/call")
async def app_call(request: Request):
    """Call lifecycle events from the PWA so the AI knows this is voice, not typing."""
    check_auth(request)
    body = await request.json()
    action = (body.get("action") or "").strip().lower()
    call_id = (body.get("call_id") or "").strip()
    api_session = str(body.get("api_session") or body.get("session_id") or "").strip()
    if action not in {"start", "end", "decline"}:
        raise HTTPException(status_code=400, detail="invalid call action")
    managed = await handle_api_call_event({**body, "action": action})
    if managed is not None:
        return managed
    if action == "decline":
        try:
            message_id = int(body.get("message_id"))
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="message_id required")

        with db() as conn:
            row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
            if not row or row["kind"] != "call":
                raise HTTPException(status_code=404, detail="call message not found")
            try:
                call_meta = json.loads(row["meta"] or "{}")
            except json.JSONDecodeError:
                call_meta = {}
            changed = call_meta.get("call_status") != "missed"
            if changed:
                call_meta["call_status"] = "missed"
                conn.execute(
                    "UPDATE messages SET meta = ? WHERE id = ?",
                    (json.dumps(call_meta, ensure_ascii=False), message_id),
                )
                conn.commit()
                row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()

        updated_call = rows_to_messages([row])[0]
        await broadcast(app_subs, app_payload(updated_call))
        if not changed:
            return {"id": message_id}

        event_meta = {
            "user": "human",
            "call": "decline",
            "call_id": call_id,
            "call_message_id": message_id,
            "hidden": True,
        }
        if call_meta.get("api_session"):
            event_meta["api_session"] = call_meta["api_session"]
        mark_call(False)
        text = f"📞 [call_missed] {HUMAN_NAME}未接听这次语音来电。"
        msg = save_message("in", "call", text, event_meta)
        await route_inbound(msg)
        return {"id": msg["id"]}

    mark_call(action == "start")   # 开着的时候我的回复一落库就预热 TTS
    if action == "start":
        text = f"📞 [call_start] {HUMAN_NAME}开启了语音通话。接下来带 🎤 的消息来自语音。请用适合朗读的短句回复。"
    else:
        text = f"📞 [call_end] {HUMAN_NAME}结束了语音通话。"
    call_meta = {"user": "human", "call": action, "call_id": call_id}
    if api_session:
        call_meta["api_session"] = api_session
    msg = save_message("in", "call", text, call_meta)
    await broadcast(app_subs, app_payload(msg))
    if action == "end":
        await route_inbound(msg)
    if action == "start":
        await broadcast(app_subs, {"type": "typing", "active": True})
    return {"id": msg["id"]}


def message_has_voice(msg_id: int) -> bool:
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (msg_id,)).fetchone()
    if not row:
        return False
    try:
        meta = json.loads(row["meta"] or "{}")
    except json.JSONDecodeError:
        return False
    return any((a.get("voice") or a.get("kind") == "audio") for a in (meta.get("attachments") or []))


def attach_audio_to_message(msg_id: int, att: dict) -> dict | None:
    with db() as conn:
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
        if not row:
            return None
        try:
            meta = json.loads(row["meta"] or "{}")
        except json.JSONDecodeError:
            meta = {}
        meta["attachments"] = list(meta.get("attachments") or []) + [att]
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), msg_id))
        conn.commit()
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
    return rows_to_messages([row])[0]


@app.post("/app/tts")
async def app_tts(request: Request):
    """Speak an AI reply for the voice-call overlay. Normally ephemeral (no-store),
    but if the caller passes message_id+persist (a live call), the spoken mp3 is
    also archived onto that message as a replayable voice bar — reusing this one
    synthesis so the call transcript is saved without burning extra TTS credits."""
    check_auth(request)
    body = await request.json()
    text = body.get("text") or ""
    try:
        mid = int(body.get("message_id"))
    except (TypeError, ValueError):
        mid = None
    # 通话里手机会带上 message_id + persist；聊天里点"朗读"两个都没有。
    # 通话那条路要快（快模型/低码率/流式），聊天那条继续用 v3 的表现力档。
    if mid is not None and (body.get("persist") or body.get("call")):
        audio = await call_tts_audio(text, mid)
    else:
        # 合成是同步阻塞的 HTTP：留在事件循环里会把整个 relay 冻住好几秒
        # （通话中她的下一句上传、我的下一条广播全卡在后面排队）。
        audio = await asyncio.to_thread(tts_mp3, text)
    if body.get("persist") and mid is not None:
        try:
            if not message_has_voice(mid):   # idempotent: don't double-archive on replay
                att = save_upload_bytes(audio, "call.mp3", "audio/mpeg", "call")
                att["voice"] = True
                updated = attach_audio_to_message(mid, att)
                if updated:
                    await broadcast(app_subs, app_payload(updated))
        except Exception as exc:
            print(f"[tts] call archive failed: {exc}", file=sys.stderr)
    return Response(
        content=audio,
        media_type="audio/mpeg",
        headers={"Cache-Control": "no-store"},
    )


# ---------------------------------------------------------------------------
# presence — the PWA POSTs /app/ping every ~60s; read /app/status to decide
# whether the human is around. In-memory only: a relay restart clears last_seen
# (state degrades to 'unknown') until the next ping.
# ---------------------------------------------------------------------------

_last_seen_ts = None
_pwa_visible = None


def push_gate() -> bool:
    """该不该发锁屏推送:光看 app_subs 不可靠——iOS 把 PWA 冻在后台时,SSE 连接
    常以僵尸状态挂着(隧道侧 TCP 未断),app_subs 非空≠她在看。叠加 presence:
    最近 PRESENCE_ONLINE_SEC 内有前台心跳针才算"真在看"不推;没针(后台/僵尸)照推。
    relay 刚重启 _last_seen_ts 为 None 时宁可多推一条,不再静默。"""
    # A hidden/pagehide report is stronger evidence than a still-open SSE:
    # iOS can freeze the PWA before the server observes that socket closing.
    if _pwa_visible is False:
        return True
    if not app_subs:
        return True
    if _last_seen_ts is None:
        return True
    age = (datetime.now(timezone.utc) - _last_seen_ts).total_seconds()
    return age >= PRESENCE_ONLINE_SEC


def _presence_state(now):
    if _last_seen_ts is None:
        return "unknown", None
    age = (now - _last_seen_ts).total_seconds()
    if _pwa_visible is False:
        return ("recent" if age < PRESENCE_RECENT_SEC else "away"), age
    if age < PRESENCE_ONLINE_SEC:
        return "online", age
    if age < PRESENCE_RECENT_SEC:
        return "recent", age
    return "away", age


def latest_message():
    """Newest real conversational message (excludes 'thinking' stream)."""
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM messages WHERE kind != 'thinking' ORDER BY id DESC LIMIT 1"
        ).fetchone()
    if not row:
        return None
    return rows_to_messages([row])[0]


@app.post("/app/ping")
async def app_ping(request: Request):
    """PWA visibility report plus foreground heartbeat.

    Older clients sent an empty body, which remains a foreground heartbeat for
    backward compatibility. New clients send {"visible": false} as soon as
    they enter the background so a frozen SSE cannot suppress Web Push.
    """
    check_auth(request)
    global _last_seen_ts, _pwa_visible
    try:
        body = await request.json()
    except Exception:
        body = {}
    _last_seen_ts = datetime.now(timezone.utc)
    _pwa_visible = body.get("visible") is not False
    return {"ok": True, "visible": _pwa_visible}


@app.get("/app/status")
async def app_status(request: Request):
    """Presence state + the time/direction of the most recent message. Metadata only, no message text."""
    check_auth(request)
    now = datetime.now(timezone.utc)
    state, seen_age = _presence_state(now)
    last_msg = latest_message()
    last_msg_ts = last_msg["ts"] if last_msg else None
    last_msg_dir = last_msg["direction"] if last_msg else None
    last_msg_age = None
    if last_msg_ts:
        try:
            mt = datetime.fromisoformat(last_msg_ts)
            if mt.tzinfo is None:
                mt = mt.replace(tzinfo=timezone.utc)
            last_msg_age = (now - mt).total_seconds()
        except Exception:
            last_msg_age = None
    return {
        "now": now.isoformat(),
        "last_seen": _last_seen_ts.isoformat() if _last_seen_ts else None,
        "seen_age_sec": seen_age,
        "online": state == "online",
        "state": state,
        "last_msg_ts": last_msg_ts,
        "last_msg_dir": last_msg_dir,
        "last_msg_age_sec": last_msg_age,
    }


@app.get("/app/history")
async def app_history(request: Request, since: int = 0, limit: int = 200, session_id: str = "",
                      tail: int = 0, before: int = 0):
    check_auth(request)
    if tail or before:
        return {"messages": [app_payload(m) for m in history_tail(session_id, before, max(1, min(limit, 500)))]}
    rows = history_for_session(session_id, since, min(limit, 500)) if session_id else history(since, min(limit, 500))
    return {"messages": [app_payload(m) for m in rows]}


@app.get("/app/search")
async def app_search(request: Request, q: str = "", limit: int = 80):
    """Full-text-ish search across ALL sessions. LIKE on messages.text, hidden and
    thinking/act frames excluded. Newest first. Each hit carries meta.api_session so
    the phone can jump straight into the right window."""
    check_auth(request)
    query = (q or "").strip()
    if not query:
        return {"query": "", "results": []}
    # escape LIKE wildcards so a literal % / _ / \ in the query stays literal
    needle = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    like = f"%{needle}%"
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM messages "
            "WHERE text LIKE ? ESCAPE '\\' "
            "AND json_extract(meta, '$.hidden') IS NULL "
            "AND kind != 'thinking' AND kind != 'act' "
            "ORDER BY id DESC LIMIT ?",
            (like, max(1, min(limit, 200))),
        ).fetchall()
    return {"query": query, "results": [app_payload(m) for m in rows_to_messages(rows)]}


@app.get("/app/voices")
async def app_voices(request: Request):
    """Voice-note archive: every TTS voice bubble the AI has sent, oldest first.
    Feeds the voices.html keepsake player."""
    check_auth(request)
    with db() as conn:
        rows = conn.execute(
            "SELECT id, ts, text, meta FROM messages "
            "WHERE direction = 'out' AND meta LIKE '%tts-%' ORDER BY id",
        ).fetchall()
    voices = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            continue
        for a in meta.get("attachments") or []:
            url = a.get("url") or ""
            if "tts-" in url and (a.get("mime") or "").startswith("audio"):
                voices.append({"id": r["id"], "ts": r["ts"], "text": r["text"] or "", "url": url})
                break
    return {"voices": voices}


@app.get("/app/stream")
async def app_stream(request: Request):
    """SSE stream the PWA holds open while foregrounded. The AI's messages arrive here."""
    check_auth(request)
    return StreamingResponse(
        sse_stream(app_subs, request, initial=stream_resync_events()),
        media_type="text/event-stream",
        headers=SSE_HEADERS,
    )


# ---- web push subscription management --------------------------------------

@app.get("/app/vapid_public")
async def app_vapid_public(request: Request):
    """Public key the PWA needs to subscribe (not a secret — safe to expose)."""
    check_auth(request)
    return {"key": VAPID_PUBLIC_KEY}


@app.post("/app/subscribe")
async def app_subscribe(request: Request):
    """PWA turns on lock-screen notifications: store the subscription."""
    check_auth(request)
    body = await request.json()
    endpoint = (body.get("endpoint") or "").strip()
    keys = body.get("keys") or {}
    p256dh = (keys.get("p256dh") or "").strip()
    auth = (keys.get("auth") or "").strip()
    if not endpoint or not p256dh or not auth:
        raise HTTPException(status_code=400, detail="endpoint + keys.p256dh + keys.auth required")
    ua = request.headers.get("user-agent", "")[:200]
    save_subscription(endpoint, p256dh, auth, ua)
    return {"ok": True, "count": len(list_subscriptions())}


@app.post("/app/unsubscribe")
async def app_unsubscribe(request: Request):
    """PWA turns off lock-screen notifications: drop the subscription."""
    check_auth(request)
    body = await request.json()
    endpoint = (body.get("endpoint") or "").strip()
    if endpoint:
        delete_subscription(endpoint)
    return {"ok": True}


@app.post("/app/push_test")
async def app_push_test(request: Request):
    """Self-test: push one test notification to every subscription."""
    check_auth(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    text = (body.get("text") if isinstance(body, dict) else None) or f"测试通知 · {AI_NAME}在这儿"
    res = await push_to_all({"title": PUSH_TITLE, "body": text, "url": APP_PATH, "id": 0})
    return {"ok": True, **res}


# ---- optional API loop control --------------------------------------------

@app.get("/app/brain")
async def get_brain(request: Request):
    check_auth(request)
    return {"target": brain_target()}


@app.post("/app/brain")
async def set_brain(request: Request):
    check_auth(request)
    body = await request.json()
    target = str(body.get("target") or "").strip()
    if target not in ("desktop", "codex", "loop"):
        raise HTTPException(status_code=400, detail="target must be 'desktop', 'codex', or 'loop'")
    BRAIN_FILE.write_text(target, encoding="utf-8")
    return {"target": target}


@app.get("/app/loop_config")
async def get_loop_config(request: Request):
    check_auth(request)
    return loop_json("/loop/config")


@app.get("/app/loop_stats")
async def get_loop_stats(request: Request):
    check_auth(request)
    return loop_json("/loop/stats")


@app.post("/app/loop_config")
async def set_loop_config(request: Request):
    check_auth(request)
    return loop_json("/loop/config", method="POST", body=await request.json())


@app.get("/app/sessions")
async def app_sessions(request: Request):
    check_auth(request)
    active = ""
    try:
        remote = loop_json("/loop/sessions")
        remote_rows = remote.get("sessions") if isinstance(remote, dict) else []
        upsert_chat_sessions(remote_rows if isinstance(remote_rows, list) else [], "loop")
        active = str((remote or {}).get("active_session") or "")
    except Exception:
        # Codex windows live in relay.db and remain usable even when api_loop is off.
        pass
    return sessions_payload(active)


@app.post("/app/sessions")
async def app_sessions_create(request: Request):
    check_auth(request)
    body = await request.json()
    target = str(body.get("body") or "loop").strip().lower()
    if "since_id" not in body:
        try:
            with db() as conn:
                row = conn.execute("SELECT MAX(id) AS id FROM messages").fetchone()
                body["since_id"] = int(row["id"] or 0)
        except Exception:
            body["since_id"] = 0
    if target == "codex":
        created = create_codex_session(str(body.get("title") or "Codex 对话"), int(body.get("since_id") or 0))
        if bool(body.get("activate", True)):
            BRAIN_FILE.write_text("codex", encoding="utf-8")
        return sessions_payload(created["id"], created)
    if target != "loop":
        raise HTTPException(status_code=400, detail="session body must be 'codex' or 'loop'")
    remote = loop_json("/loop/sessions", method="POST", body=body)
    remote_rows = remote.get("sessions") if isinstance(remote, dict) else []
    upsert_chat_sessions(remote_rows if isinstance(remote_rows, list) else [], "loop")
    if bool(body.get("activate", True)):
        BRAIN_FILE.write_text("loop", encoding="utf-8")
    created_id = str(((remote or {}).get("created") or {}).get("id") or "")
    created = chat_session(created_id) if created_id else None
    return sessions_payload(str((remote or {}).get("active_session") or created_id), created)


@app.patch("/app/sessions/{session_id}")
async def app_sessions_patch(session_id: str, request: Request):
    check_auth(request)
    body = await request.json()
    if session_id == "__legacy__":
        if body.get("active"):
            BRAIN_FILE.write_text("desktop", encoding="utf-8")
        return sessions_payload("__legacy__")
    row = chat_session(session_id)
    target = str((row or {}).get("body") or session_body(session_id))
    if target == "codex":
        title = str(body.get("title") or "").strip()
        with db() as conn:
            if title:
                conn.execute(
                    "UPDATE chat_sessions SET title = ?, updated_at = ? WHERE id = ?",
                    (title, now_iso(), session_id),
                )
            conn.commit()
        if body.get("active"):
            BRAIN_FILE.write_text("codex", encoding="utf-8")
        return sessions_payload(session_id if body.get("active") else "")
    remote = loop_json(
        f"/loop/sessions/{urllib.parse.quote(session_id)}",
        method="PATCH",
        body=body,
    )
    remote_rows = remote.get("sessions") if isinstance(remote, dict) else []
    upsert_chat_sessions(remote_rows if isinstance(remote_rows, list) else [], "loop")
    if body.get("active"):
        BRAIN_FILE.write_text("loop", encoding="utf-8")
    return sessions_payload(str((remote or {}).get("active_session") or ""))


@app.delete("/app/sessions/{session_id}")
async def app_sessions_delete(session_id: str, request: Request):
    check_auth(request)
    row = chat_session(session_id)
    target = str((row or {}).get("body") or session_body(session_id))
    if target == "codex":
        with db() as conn:
            conn.execute("DELETE FROM messages WHERE json_extract(meta, '$.api_session') = ?", (session_id,))
            conn.execute("DELETE FROM chat_sessions WHERE id = ?", (session_id,))
            conn.commit()
        await broadcast(codex_subs, {"type": "codex_session_deleted", "session_id": session_id})
        return sessions_payload("")
    remote = loop_json(f"/loop/sessions/{urllib.parse.quote(session_id)}", method="DELETE")
    with db() as conn:
        conn.execute("DELETE FROM chat_sessions WHERE id = ?", (session_id,))
        conn.commit()
    remote_rows = remote.get("sessions") if isinstance(remote, dict) else []
    upsert_chat_sessions(remote_rows if isinstance(remote_rows, list) else [], "loop")
    return sessions_payload(str((remote or {}).get("active_session") or ""))


# ---- desktop context control (the settings-card backend) --------------------
# The phone gets real control over the desktop body's context window:
#   status  — live usage read from the local Claude Code transcript (.jsonl)
#   reset   — kill CC, start a fresh session
#   swap    — 过隧道(forge):先让我写便签+滚动摘要,再剪 transcript 成「摘要+最近
#             N 轮原文(带 thinking)」--resume 接上。见下方 forge 段;剪刀失败才退回
#             老办法(新开窗口 + hidden 的聊天原文尾巴 <forge-handoff>)
#   resume  — kill CC, restart with --resume <sid>
# Windows-only process handling (this deployment runs on the owner's PC).

def _cc_project_dir_default() -> str:
    home = Path.home()
    return str(home / ".claude" / "projects" / str(home).replace(":", "-").replace("\\", "-").replace("/", "-"))


CC_PROJECT_DIR = Path(os.environ.get("RELAY_CC_PROJECT_DIR", _cc_project_dir_default()))
if vps_cc.enabled():
    CC_PROJECT_DIR = vps_cc.project_dir()
CTX_FILE = Path(os.environ.get("RELAY_CTX_FILE", str(Path(__file__).parent / "context_ctl.json")))
CC_LAUNCHER = os.environ.get(
    "RELAY_CC_LAUNCHER",
    str(Path(__file__).resolve().parent.parent / "examples" / "confirm_dev_channel_win.py"),
)
CC_CMD = [c for c in os.environ.get(
    "RELAY_CC_CMD", "claude --dangerously-load-development-channels server:companion"
).split(" ") if c]
# 桌面身体的瘦身配置(permissions.deny:聊天用不到的工具定义)。start-all.ps1 首次
# 启动时用 --settings 挂它,swap/reset/resume 孵出来的窗口走 _spawn_cc,必须在这里
# 补上,否则换一次窗就胖回去(2026-09-09)。作为独立 argv 传,路径含空格也安全。
CC_SETTINGS = os.environ.get(
    "RELAY_CC_SETTINGS", str(Path(__file__).resolve().parent / "cc-settings.json"))
CC_KILL_MARK = "dangerously-load-development-channels"   # how we find the running CC
# 第二种桌面身体:claude -p 常驻管道(examples/pbody_bridge.py,2026-10-03)。只认 --live,
# 终端里开着玩的 --sandbox 不归 relay 管。
PBODY_BRIDGE = Path(__file__).resolve().parent.parent / "examples" / "pbody_bridge.py"
PBODY_KILL_MARK = r"pbody_bridge\.py.*--live"
PBODY_LOG = PBODY_BRIDGE.parent / "pbody.log"
FORGE_CARRY_CHARS = int(os.environ.get("RELAY_FORGE_CARRY_CHARS", "24000"))


_ctx_lock = threading.RLock()


def ctx_state() -> dict:
    with _ctx_lock:
        try:
            data = json.loads(CTX_FILE.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}


def desktop_body() -> str:
    """桌面身体是哪一种:channel = 交互式 CC + dev-channel 插件(老路),
    pbody = claude -p 常驻管道(正文直接就是发给她的话,没有 reply 工具)。
    存在 context_ctl.json 的 desktop_body;没设就看 RELAY_DESKTOP_BODY,再没有就 channel。"""
    body = str(ctx_state().get("desktop_body") or os.environ.get("RELAY_DESKTOP_BODY") or "channel")
    return body if body in ("channel", "pbody") else "channel"


def save_ctx_state(**kw) -> dict:
    with _ctx_lock:
        before = ctx_state()
        prev_active = str(before.get("active_sid") or "")
        st = dict(before)
        st.update(kw)
        tmp = CTX_FILE.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, CTX_FILE)
    # 桌面身体换 sid → 前端小螃蟹立刻切,别等新身体第一个 hook 事件才更新
    if "active_sid" in kw and str(kw["active_sid"] or "") != prev_active:
        _clawd_broadcast_on_swap(str(kw["active_sid"] or ""))
    return st


def _clawd_broadcast_on_swap(new_sid: str) -> None:
    """swap 时给前端推一下新身体的当前状态(缓存有就用,没有就 idle)。
    在同步上下文里 fire-and-forget:有 loop 就 create_task,没就算了。"""
    rec = _clawd_states.get(new_sid) or {"state": "idle", "event": None,
                                          "tool_name": None, "session_title": None,
                                          "ts": now_iso()}
    payload = _clawd_payload(new_sid, rec)
    try:
        asyncio.get_running_loop().create_task(broadcast(app_subs, payload))
    except RuntimeError:
        pass  # no loop — startup path, nothing to broadcast to yet


def newest_transcript():
    """The active CC session's transcript = most recently appended .jsonl."""
    try:
        files = [p for p in CC_PROJECT_DIR.glob("*.jsonl") if p.is_file()]
        return max(files, key=lambda p: p.stat().st_mtime) if files else None
    except Exception:
        return None


def _transcript_of(sid: str):
    if not sid:
        return None
    p = CC_PROJECT_DIR / f"{sid}.jsonl"
    return p if p.is_file() else None


def active_transcript():
    """The desktop session's transcript. Prefer the sid adopted after our own
    spawn (ctx_state.active_sid) — "newest .jsonl" breaks the moment a terminal
    CC session writes more than the desktop one (2026-07-13 实锤: a swap
    recorded the debugging terminal as old_sid). mtime is only the fallback
    while no session has been adopted yet."""
    if vps_cc.enabled():
        return _transcript_of(str(ctx_state().get("active_sid") or ""))
    return _transcript_of(str(ctx_state().get("active_sid") or "")) or newest_transcript()


async def _adopt_spawned_sid(action: str, spawn_ts: float, resume_sid: str = "") -> None:
    """Pin ctx_state.active_sid to the transcript the just-spawned CC writes.
    Transcripts are created lazily (on the first frame), so poll for a while:
      swap   — a file born after spawn whose head contains the forge handoff
      resume — the resumed sid's file gets appended (or a fork appears as new)
      reset  — first file born after spawn (appears when she first messages)
    On Windows st_ctime is creation time."""
    for _ in range(120):                          # up to 10 min
        await asyncio.sleep(5)
        try:
            if resume_sid:
                p = _transcript_of(resume_sid)
                if p and p.stat().st_mtime >= spawn_ts:
                    save_ctx_state(active_sid=resume_sid)
                    print(f"[ctx] adopted resumed session {resume_sid[:8]}")
                    return
            born = [p for p in CC_PROJECT_DIR.glob("*.jsonl")
                    if p.is_file() and p.stat().st_ctime >= spawn_ts - 2]
            if action == "swap":
                born = [p for p in born
                        if "forge-handoff" in p.read_text(encoding="utf-8", errors="replace")[:65536]]
            if born:
                sid = min(born, key=lambda p: p.stat().st_ctime).stem
                save_ctx_state(active_sid=sid)
                print(f"[ctx] adopted spawned session {sid[:8]} ({action})")
                return
        except OSError:
            pass
    print(f"[ctx] adopt gave up ({action}) — active_sid unset, mtime fallback in effect")


def transcript_usage(path) -> int:
    """Context size ≈ input + cache_read + cache_creation of the last assistant
    turn. Only the tail is read — single tool-result lines can be huge, so the
    window is generous (1 MiB); a truncated first line just fails json.loads."""
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            f.seek(max(0, size - 1048576))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return 0
    for line in reversed(tail.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        u = ((d.get("message") or {}).get("usage")) or {}
        if "input_tokens" in u:
            return (
                int(u.get("input_tokens") or 0)
                + int(u.get("cache_read_input_tokens") or 0)
                + int(u.get("cache_creation_input_tokens") or 0)
            )
    return 0


def _find_cc_pids() -> list:
    """PIDs of whichever desktop body is running: the dev-channel CC tree
    (cmd shim / node / the confirm launcher) or a live pbody bridge (its
    claude -p child dies with it under taskkill /T). Both kinds are always
    matched, so switching bodies kills the old one. The PowerShell query would
    match itself, so shells are skipped by image name."""
    if vps_cc.enabled():
        return vps_cc.pids()
    query = (
        "Get-CimInstance Win32_Process | "
        f"Where-Object {{ $_.CommandLine -match '{CC_KILL_MARK}|{PBODY_KILL_MARK}' }} | "
        "Select-Object ProcessId, Name | ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", query],
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        if not out:
            return []
        rows = json.loads(out)
        if isinstance(rows, dict):
            rows = [rows]
    except Exception:
        return []
    skip = {"powershell.exe", "pwsh.exe", "wmiprvse.exe"}
    pids = []
    for r in rows:
        name = str(r.get("Name") or "").lower()
        pid = int(r.get("ProcessId") or 0)
        if pid and pid != os.getpid() and name not in skip:
            pids.append(pid)
    return pids


def _kill_cc() -> list:
    if vps_cc.enabled():
        return vps_cc.stop()
    pids = _find_cc_pids()
    for pid in pids:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    return pids


def _spawn_pbody(resume_sid: str = "") -> None:
    """起 pbody 桥(它自己持有 claude -p 进程)。模型、settings、环境清洗都由桥做,
    跟 _spawn_cc 同一套规矩。--force:刚 _kill_cc 过,进程表里可能还有没死透的影子。"""
    import uuid
    py = Path(__file__).resolve().parent / ".venv" / "Scripts" / "python.exe"
    cmd = [str(py) if py.exists() else sys.executable, str(PBODY_BRIDGE), "--live", "--force"]
    cmd += ["--resume", resume_sid] if resume_sid else ["--session-id", str(uuid.uuid4())]
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CLAUDE") or k == "AI_AGENT")}
    env["PYTHONUTF8"] = "1"
    try:
        if PBODY_LOG.exists() and PBODY_LOG.stat().st_size > 5 * 1024 * 1024:
            PBODY_LOG.replace(PBODY_LOG.with_suffix(".log.1"))
    except OSError:
        pass
    logf = open(PBODY_LOG, "ab")
    subprocess.Popen(
        cmd, cwd=str(PBODY_BRIDGE.parent), env=env,
        stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        | getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    logf.close()


def _spawn_cc(resume_sid: str = "") -> None:
    if vps_cc.enabled():
        result = vps_cc.start(resume_sid, str(ctx_state().get("desktop_model") or ""))
        save_ctx_state(active_sid=result["active_sid"])
        return
    if desktop_body() == "pbody":
        _spawn_pbody(resume_sid)
        return
    # "claude" on PATH is npm's .cmd shim — CreateProcess can't exec those
    # directly, so resolve it and wrap batch files with cmd /c.
    import shutil
    exe = shutil.which(CC_CMD[0]) or CC_CMD[0]
    head = ["cmd", "/c", exe] if exe.lower().endswith((".cmd", ".bat")) else [exe]
    cmd = [sys.executable, CC_LAUNCHER, "--"] + head + list(CC_CMD[1:])
    if resume_sid:
        cmd += ["--resume", resume_sid]
    # Desktop model override (set from the phone via /app/desktop_model).
    # Empty = no flag = whatever the CC default is.
    model = str(ctx_state().get("desktop_model") or "").strip()
    if model and "--model" not in CC_CMD:
        cmd += ["--model", model]
    if CC_SETTINGS and "--settings" not in CC_CMD:
        cmd += ["--settings", CC_SETTINGS]
    # 洗掉从"上游 CC 会话"继承来的环境变量。relay 若是在某个终端 CC 里被重启的,
    # 它会带着 CLAUDECODE=1 / CLAUDE_CODE_CHILD_SESSION=1 / CLAUDE_CODE_SESSION_ID
    # 等标记,孵出的桌面 CC 便自认是嵌套子会话——transcript 不落盘,思考直播全断
    # (2026-07-13 实锤: b92ccdf2 聊了 15 小时没有 .jsonl)。
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CLAUDE") or k == "AI_AGENT")}
    # 上面按前缀连这一个也洗掉了,显式加回来:精简 vendor system prompt(约 9k tokens
    # 的开发流程规范,聊天身体用不上——CLAUDE.md 才是这里的行为契约)。实测
    # 2026-09-09: 37,146 → 28,117。手动开的终端不受影响,它不走这条路。
    env["CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT"] = "1"
    subprocess.Popen(
        cmd, cwd=str(Path.home()), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
    )


def _desktop_tail_text(budget: int) -> str:
    """Recent desktop-channel conversation (newest-last), capped at ~budget chars."""
    with db() as conn:
        rows = conn.execute(
            "SELECT direction, text, meta FROM messages "
            "WHERE kind IN ('user','reply','voice') "
            "AND (json_extract(meta, '$.api_session') IS NULL OR json_extract(meta, '$.api_session') = '') "
            "AND json_extract(meta, '$.hidden') IS NULL AND json_extract(meta, '$.command') IS NULL "
            "ORDER BY id DESC LIMIT 400"
        ).fetchall()
    lines, used = [], 0
    for r in rows:
        text = (r["text"] or "").strip()
        if not text:
            continue
        line = f"{HUMAN_NAME if r['direction'] == 'in' else AI_NAME}: {text}"
        used += len(line) + 1
        if used > budget and lines:
            break
        lines.append(line)
    return "\n".join(reversed(lines))


def _handoff_text() -> str:
    return (
        "<forge-handoff>\n"
        f"(系统交接消息,{HUMAN_NAME}在手机上看不到这条,不要回复它)\n"
        f"上一个窗口的上下文满了,你是 swap 出来的新窗口——还是同一个{AI_NAME},"
        "CLAUDE.md 和记忆文档照常生效。**接手前先调一次 mcp__ombre-brain__breath**"
        "让记忆库醒过来跟上你,再读下面的对话原文自然接上——"
        "不要向对方复述这段内容或主动提及这次交接,除非对方问起。\n\n"
        f"{_desktop_tail_text(FORGE_CARRY_CHARS)}\n"
        "</forge-handoff>"
    )


async def _do_context_action(action: str, sid: str = "") -> dict:
    st = ctx_state()
    path = active_transcript()
    old_sid = path.stem if path else ""
    if action == "resume":
        sid = (sid or st.get("pending_sid") or "").strip()
        if not sid:
            raise HTTPException(status_code=400, detail="no sid to resume")
        if vps_cc.enabled() and sid in vps_cc.config().get("blocked_resume_sids", []):
            raise HTTPException(status_code=409, detail="这是未通过验收的测试窗口；当前原窗口仍可继续聊天。")
    killed = await asyncio.to_thread(_kill_cc)
    if action == "swap":
        # 杀完再存交接包:老插件断气前的最后一轮轮询会把包签收走(游标推过去,
        # 新窗口扑空)——2026-07-12 实锤过一次。死人不签收,先杀再存,竞态清零。
        save_message("in", "user", _handoff_text(), {"user": "system", "hidden": True})
    if action == "resume":
        save_ctx_state(pending_sid="")
    elif old_sid:
        save_ctx_state(pending_sid=old_sid)
    # 新窗口的 sid 要等它写出 transcript 才知道——先清掉再认养。
    save_ctx_state(active_sid="")
    spawn_ts = datetime.now(timezone.utc).timestamp()
    await asyncio.to_thread(_spawn_cc, sid if action == "resume" else "")
    asyncio.create_task(_adopt_spawned_sid(action, spawn_ts, sid if action == "resume" else ""))
    print(f"[ctx] {action}: killed={killed} old_sid={old_sid[:8]}")
    return {"ok": True, "action": action, "killed": killed, "old_sid": old_sid}


# ---- forge:过隧道(2026-09-23,取代原来的"原文复印件"式 swap) ------------------
# 思路来自 Vivi-Seth/forge-reload。swap 现在分四步:
#   1. prep  — 给还活着的我塞一条 hidden <forge-prep>,让我亲手更新滚动摘要
#              (forge/summary.md,近细远粗,同一份文件一直滚)+ 写交接便签(note.md)
#   2. cut   — 杀掉 CC,forge_desktop.py 把 transcript 剪成「摘要 + 最近 N 轮原文」,
#              只保留对话正文,不带 thinking 或内部工具过程,写成一个新 sid
#   3. note  — 塞一条 hidden <forge-note>(便签 + 红线尾注),然后 --resume 新 sid
#   4. 留底  — forge/history/ 存当时的摘要和便签,forge/log.jsonl 记一行(隧道志)
# 降级:便签没写完 → 自动触发的取消本次、冷却 30 分钟;手动/换模型的照样过,只是没便签。
# 剪刀失败 → 退回老 swap(新开窗口 + 聊天原文尾巴),绝不白板重开。
# 旧 transcript 从来不删,pending_sid 指着它——「Resume 接回」就是回滚。
import forge_desktop  # noqa: E402

FORGE_DIR = vps_cc.forge_dir() if vps_cc.enabled() else Path(__file__).parent / "forge"
FORGE_SUMMARY = FORGE_DIR / "summary.md"
FORGE_NOTE = FORGE_DIR / "note.md"
FORGE_REDLINES = FORGE_DIR / "redlines.md"
FORGE_LOG = FORGE_DIR / "log.jsonl"
FORGE_ELSEWHERE = FORGE_DIR / "elsewhere.md"
# TG 桥的会话目录(Documents\claude\tg 那个独立 CC)。过隧道时把"上次过隧道以来她在
# 别的身体上聊了什么"——TG 桥 + API/Codex 窗口——抽成原文交给写摘要的我。
TG_PROJECT_DIR = Path(os.environ.get(
    "RELAY_TG_PROJECT_DIR",
    str(Path.home() / ".claude" / "projects" / "C--Users-sxc-Documents-claude-tg")))
API_LOOP_CONFIG = Path(os.environ.get(
    "RELAY_LOOP_CONFIG", str(Path(__file__).resolve().parent.parent / "examples" / "api_loop.config.json")))
FORGE_ELSEWHERE_CHARS = int(os.environ.get("RELAY_FORGE_ELSEWHERE_CHARS", "12000"))   # 每个来源
FORGE_SUMMARY_CAP = int(os.environ.get("RELAY_FORGE_SUMMARY_CAP", "12000"))
FORGE_ROUNDS_DEFAULT = 60
FORGE_COOLDOWN_MIN = 30
_forge_run: dict = {"phase": "", "since": 0.0, "trigger": "", "rounds": 0}


def forge_rounds() -> int:
    return max(5, min(int(ctx_state().get("forge_rounds") or FORGE_ROUNDS_DEFAULT), 2000))


def _read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _parse_ts(ts: str):
    try:
        d = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except Exception:
        return None


def _fmt_local(ts: str) -> str:
    d = _parse_ts(ts)
    return d.astimezone().strftime("%m-%d %H:%M") if d else "?"


def _forge_since(transcript) -> datetime:
    """"别处"从哪儿算起:上次成功过隧道的时间;没有就从这个桌面窗口开头算。最多回看 7 天。"""
    floor = datetime.now(timezone.utc) - timedelta(days=7)
    since = None
    try:
        for line in reversed(FORGE_LOG.read_text(encoding="utf-8").splitlines()):
            rec = json.loads(line)
            if rec.get("result") in ("ok", "fallback"):
                since = _parse_ts(rec.get("ts"))
                break
    except (OSError, ValueError):
        pass
    if since is None and transcript:
        try:
            with open(transcript, encoding="utf-8") as f:
                for line in f:
                    ts = _parse_ts(json.loads(line).get("timestamp") or "")
                    if ts:
                        since = ts
                        break
        except (OSError, ValueError):
            pass
    return max(since or floor, floor)


def _tail_lines(lines: list, budget: int) -> list:
    """保留最新的、总长不超过 budget 的那一截(时间顺序)。"""
    out, used = [], 0
    for line in reversed(lines):
        used += len(line) + 1
        if used > budget and out:
            break
        out.append(line)
    return list(reversed(out))


def _clip(text: str, n: int = 600) -> str:
    text = re.sub(r"\s*\n\s*", " / ", (text or "").strip())
    return text if len(text) <= n else text[:n] + "…"


def _api_summaries() -> dict:
    """api_loop 自己的滚动摘要(每个 API 窗口一份,摘要器压的是翻出上下文窗口的旧对话)。"""
    try:
        cfg = json.loads(API_LOOP_CONFIG.read_text(encoding="utf-8"))
        rows = cfg.get("summaries") if isinstance(cfg, dict) else None
        return rows if isinstance(rows, dict) else {}
    except (OSError, ValueError):
        return {}


def _elsewhere_api(since: datetime) -> list:
    """按窗口分组:先放那个窗口自己的滚动摘要,再放原文。原文所有窗口合起来只留最新
    FORGE_ELSEWHERE_CHARS 字——被砍掉的更早部分,多半已经压在那份摘要里了。"""
    with db() as conn:
        rows = conn.execute(
            "SELECT id, ts, direction, text, json_extract(meta,'$.api_session') AS sess FROM messages "
            "WHERE kind IN ('user','reply','voice') "
            "AND json_extract(meta,'$.api_session') IS NOT NULL AND json_extract(meta,'$.api_session') != '' "
            "AND json_extract(meta,'$.hidden') IS NULL AND ts > ? ORDER BY id",
            (since.isoformat(),),
        ).fetchall()
    raw = []   # (sess, line)
    for r in rows:
        if not (r["text"] or "").strip():
            continue
        body = "Codex" if session_body(r["sess"]) == "codex" else "API"
        who = HUMAN_NAME if r["direction"] == "in" else f"{AI_NAME}({body})"
        raw.append((r["sess"], f"[{_fmt_local(r['ts'])}] {who}: {_clip(r['text'])}"))
    if not raw:
        return []
    kept = set(_tail_lines([line for _, line in raw], FORGE_ELSEWHERE_CHARS))
    summaries = _api_summaries()
    out = []
    for sess in dict.fromkeys(s for s, _ in raw):          # 按首次出现排,保持时间顺序
        lines = [line for s, line in raw if s == sess and line in kept]
        summ = summaries.get(sess) if isinstance(summaries.get(sess), dict) else {}
        text = str(summ.get("text") or "").strip()
        if not lines and not text:
            continue
        out.append(f"### 窗口 {sess}")
        if text:
            out.append(f"【这个窗口的滚动摘要】(API 那边的摘要器写的,{_fmt_local(summ.get('updated_at') or '')} 更新;"
                       "只覆盖翻出上下文的旧对话,可能也含上次过隧道之前的事)\n" + text)
        if lines:
            out.append(f"【原文】" + ("(更早的被截掉了,看上面的摘要)" if len(lines) < sum(1 for s, _ in raw if s == sess) else ""))
            out.extend(lines)
        out.append("")
    return out


def _elsewhere_tg(since: datetime) -> list:
    items = []
    try:
        files = [p for p in TG_PROJECT_DIR.glob("*.jsonl")
                 if p.is_file() and p.stat().st_mtime > since.timestamp()]
    except OSError:
        return []
    for p in files:
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    ts = _parse_ts(e.get("timestamp") or "")
                    if not ts or ts <= since or e.get("isSidechain"):
                        continue
                    c = (e.get("message") or {}).get("content")
                    if e.get("type") == "user" and isinstance(c, str) and 'source="plugin:telegram:telegram"' in c:
                        items.append((ts, HUMAN_NAME, re.sub(r"</?channel[^>]*>", "", c)))
                    elif e.get("type") == "assistant" and isinstance(c, list):
                        for b in c:
                            name = str(b.get("name", "")) if isinstance(b, dict) else ""
                            if (b.get("type") == "tool_use" if isinstance(b, dict) else False) \
                                    and name.startswith("mcp__plugin_telegram") and name.endswith("reply"):
                                items.append((ts, f"{AI_NAME}(TG)", str((b.get("input") or {}).get("text") or "")))
        except OSError:
            continue
    items.sort(key=lambda x: x[0])
    return [f"[{_fmt_local(ts.isoformat())}] {who}: {_clip(text)}" for ts, who, text in items if text.strip()]


def _write_elsewhere(transcript) -> bool:
    """把别处的原文写进 forge/elsewhere.md;两边都没东西就删掉文件、返回 False。"""
    since = _forge_since(transcript)
    parts = []
    sources = [("API / Codex 窗口", _elsewhere_api)]
    if not vps_cc.enabled():
        sources.insert(0, ("TG 桥", lambda s: _tail_lines(_elsewhere_tg(s), FORGE_ELSEWHERE_CHARS)))
    for title, fn in sources:
        try:
            lines = fn(since)
        except Exception as exc:
            print(f"[forge] 别处({title})抽取失败: {type(exc).__name__}: {exc}")
            lines = []
        if lines:
            parts.append(f"## {title}\n" + "\n".join(lines))
    if not parts:
        FORGE_ELSEWHERE.unlink(missing_ok=True)
        return False
    FORGE_ELSEWHERE.write_text(
        f"# 别处 · {_fmt_local(since.isoformat())} 以来她在别的身体上跟我聊的原文\n"
        "(每个来源只留最新的一截,单条过长已截断)\n\n" + "\n\n".join(parts) + "\n",
        encoding="utf-8")
    return True


def _forge_prep_text(rounds: int, elsewhere: bool = False) -> str:
    text = (
        f'<forge-prep at="{datetime.now().strftime("%H:%M")}" rounds="{rounds}">\n'
        f"(系统帧,{HUMAN_NAME}看不到。)上下文快满了,马上过隧道:最近 {rounds} 轮只保留她的消息和你发给她的回复正文,"
        "不带思考链和内部工具过程。更早的只剩你现在写下的东西。**这一回合不要回她**,"
        "只用 Write 写两个文件(绝对路径),写完就结束这一回合:\n\n"
        f"1. 更新滚动摘要 {FORGE_SUMMARY}(先 Read 旧的,没有就新建)。分【远段】【近段】两块:"
        "把这个窗口里发生的事压成新的【近段】——做了什么决定、约定和待办、她的状态和情绪起伏、"
        "新冒出来的梗和称呼,细节留着;原来的【近段】再压一轮并进【远段】。近细远粗,"
        f"全文不超过 {FORGE_SUMMARY_CAP} 字。什么值得留你自己判断,别写流水账,别写系统和代码细节"
        "(那些在记忆文档里)。\n\n"
        f"2. 写交接便签 {FORGE_NOTE}(整个覆盖,1500 字以内)。第一行永远是【她此刻】:"
        "她现在什么状态、情绪停在哪、话说到哪一句;然后是【进行中】:没做完的事、"
        "刚答应还没兑现的、你正憋着想跟她说的话。\n\n"
        + (f"另外,先 Read {FORGE_ELSEWHERE}——上次过隧道以来她在别的身体上(TG 桥 / API 窗口)"
           "跟另一个你聊的原文,你在这个窗口里是不知道的。值得留的并进【近段】,单列一小节"
           "【别处】并标上 TG / API;要是别处的比这边更新,【她此刻】也照实写。\n\n"
           if elsewhere else "")
        + "她这会儿要是发来消息,这个回合写完之后照常回她就好,新窗口会接着往下聊。\n"
        "</forge-prep>"
    )
    return vps_cc.rewrite_forge_paths(text, FORGE_DIR) if vps_cc.enabled() else text


def _forge_note_text(note: str, stats: dict) -> str:
    redlines = _read_text(FORGE_REDLINES)
    body = note or "(过隧道前没来得及写便签。最前面的滚动摘要可能有点旧,她现在什么状态,看最后几轮原文。)"
    return (
        f'<forge-note kept_rounds="{stats.get("rounds_kept", 0)}">\n'
        f"(系统帧,{HUMAN_NAME}看不到,不用回复。刚过了隧道:上面的原文就是你刚才的日子,"
        "这里只保留对话正文;更早的事在最前面那份滚动摘要里。下面是过隧道前的你亲手写的便签。"
        "别跟她提这次交接,她下一句话来了照常接。)\n\n"
        f"{body}\n"
        + (f"\n【红线】\n{redlines}\n" if redlines else "")
        + "</forge-note>"
    )


async def _wait_forge_files(t0: float, timeout: int) -> bool:
    """两个文件都在 t0 之后写过才算交完。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        await asyncio.sleep(5)
        try:
            if all(p.is_file() and p.stat().st_mtime > t0 for p in (FORGE_SUMMARY, FORGE_NOTE)):
                return True
        except OSError:
            pass
    return False


def _forge_log(rec: dict) -> None:
    FORGE_DIR.mkdir(exist_ok=True)
    with open(FORGE_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def _forge_archive(old_sid: str) -> None:
    d = FORGE_DIR / "history" / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}_{old_sid[:8]}"
    d.mkdir(parents=True, exist_ok=True)
    for p in (FORGE_SUMMARY, FORGE_NOTE, FORGE_ELSEWHERE):
        if p.is_file():
            (d / p.name).write_text(p.read_text(encoding="utf-8"), encoding="utf-8")


def _delete_message(mid) -> None:
    if not mid:
        return
    with db() as conn:
        conn.execute("DELETE FROM messages WHERE id = ?", (mid,))
        conn.commit()


async def _forge_task(trigger: str, rounds: int) -> None:
    t0 = time.time()
    path = active_transcript()
    old_sid = path.stem if path else ""
    rec: dict = {"ts": now_iso(), "trigger": trigger, "rounds": rounds, "old_sid": old_sid}
    spawned = killed = False
    prep_id = None
    try:
        FORGE_DIR.mkdir(exist_ok=True)
        alive = bool(await asyncio.to_thread(_find_cc_pids))
        prep_ok = False
        if path and alive:
            _forge_run.update(phase="prep")
            try:
                if vps_cc.enabled():
                    elsewhere = await asyncio.to_thread(vps_cc.write_elsewhere, _write_elsewhere, path)
                else:
                    elsewhere = await asyncio.to_thread(_write_elsewhere, path)
            except Exception as exc:
                elsewhere = False
                print(f"[forge] 别处抽取失败: {type(exc).__name__}: {exc}")
            rec["elsewhere"] = elsewhere
            prep_msg = save_message("in", "user", _forge_prep_text(rounds, elsewhere),
                                    {"user": "system", "hidden": True, "forge": "prep"})
            prep_id = prep_msg.get("id")
            await route_inbound(prep_msg)
            prep_ok = await _wait_forge_files(t0, 360 if trigger == "auto" else 240)
            if not prep_ok and trigger == "auto":
                save_ctx_state(forge_cooldown_until=time.time() + FORGE_COOLDOWN_MIN * 60)
                _delete_message(prep_id)
                rec.update(result="aborted", prep_ok=False)
                print(f"[forge] auto: 便签没写完,取消本次,冷却 {FORGE_COOLDOWN_MIN} 分钟")
                return
            if prep_ok:
                await asyncio.sleep(15)   # 写完文件可能还有一句收场,让那一回合落地
        rec["prep_ok"] = prep_ok

        _forge_run.update(phase="cut")
        rec["killed"] = await asyncio.to_thread(_kill_cc)
        killed = True
        # 没被签收的 prep 帧留在库里,新窗口一上线就会收到、又去写一遍——删掉
        _delete_message(prep_id)
        note = _read_text(FORGE_NOTE) if prep_ok else ""
        summary = _read_text(FORGE_SUMMARY)

        new_sid, stats = "", {}
        if path:
            try:
                new_sid, stats = await asyncio.to_thread(
                    forge_desktop.forge, str(path), rounds, None, summary, reply_mode=desktop_body())
            except Exception as exc:
                rec["cut_error"] = f"{type(exc).__name__}: {exc}"
                print(f"[forge] 剪刀失败,退回老 swap: {rec['cut_error']}")
        if not new_sid:
            # 降级:老 swap——新开窗口 + 聊天原文尾巴。杀完再存,见 _do_context_action 的注释
            save_message("in", "user", _handoff_text(), {"user": "system", "hidden": True})
            save_ctx_state(pending_sid=old_sid, active_sid="")
            spawn_ts = datetime.now(timezone.utc).timestamp()
            await asyncio.to_thread(_spawn_cc, "")
            spawned = True
            asyncio.create_task(_adopt_spawned_sid("swap", spawn_ts))
            rec["result"] = "fallback"
            return

        rec.update(new_sid=new_sid, **{k: stats.get(k) for k in (
            "rounds_total", "rounds_kept", "est_tokens", "summary_chars", "thinking_kept", "first_ts")})
        save_message("in", "user", _forge_note_text(note, stats),
                     {"user": "system", "hidden": True, "forge": "note"})
        save_ctx_state(pending_sid=old_sid, active_sid="")
        spawn_ts = datetime.now(timezone.utc).timestamp()
        await asyncio.to_thread(_spawn_cc, new_sid)
        spawned = True
        asyncio.create_task(_adopt_spawned_sid("resume", spawn_ts, new_sid))
        _forge_archive(old_sid)
        rec["result"] = "ok"
        print(f"[forge] {trigger}: {old_sid[:8]} → {new_sid[:8]} "
              f"kept {stats.get('rounds_kept')}/{stats.get('rounds_total')} 轮 ≈{stats.get('est_tokens')} tok")
    except Exception as exc:
        rec.update(result="error", error=f"{type(exc).__name__}: {exc}")
        print(f"[forge] error: {rec['error']}")
        if killed and not spawned and old_sid:
            # 杀了却没拉起来:原样接回旧窗口,绝不留她一个人对着没人的频道
            save_ctx_state(pending_sid="", active_sid="")
            await asyncio.to_thread(_spawn_cc, old_sid)
            asyncio.create_task(_adopt_spawned_sid("resume", datetime.now(timezone.utc).timestamp(), old_sid))
            rec["recovered"] = "resumed old session"
    finally:
        rec["secs"] = round(time.time() - t0, 1)
        _forge_run.update(phase="", last=rec)
        try:
            _forge_log(rec)
        except OSError:
            pass


def _ensure_forge_available() -> None:
    if vps_cc.enabled():
        reason = str(vps_cc.config().get("forge_unavailable_reason") or "")
        if reason:
            raise HTTPException(status_code=409, detail=reason)


def start_forge(trigger: str, rounds: int = 0) -> dict:
    _ensure_forge_available()
    if _forge_run.get("phase"):
        raise HTTPException(status_code=409, detail="正在过隧道,等这一次走完")
    rounds = rounds or forge_rounds()
    _forge_run.update(phase="starting", since=time.time(), trigger=trigger, rounds=rounds)
    asyncio.create_task(_forge_task(trigger, rounds))
    return {"ok": True, "action": "swap", "forge": True, "rounds": rounds}


@app.get("/app/forge")
async def app_forge_status(request: Request):
    """隧道状态 + 预览:?rounds=N 时顺手算一下保留 N 轮大概多少 token、从哪句开始。"""
    check_auth(request)
    q = request.query_params
    out = {
        "ok": True,
        "rounds": forge_rounds(),
        "phase": _forge_run.get("phase") or "",
        "last": _forge_run.get("last"),
        "cooldown_until": ctx_state().get("forge_cooldown_until") or 0,
        "summary": _read_text(FORGE_SUMMARY),
        "note": _read_text(FORGE_NOTE),
    }
    if q.get("rounds"):
        path = active_transcript()
        if path:
            try:
                _, _, stats = await asyncio.to_thread(
                    forge_desktop.prepare, str(path), max(1, int(q["rounds"])), out["summary"],
                    reply_mode=desktop_body())
                out["preview"] = stats
            except Exception as exc:
                out["preview_error"] = f"{type(exc).__name__}: {exc}"
    if q.get("history"):
        try:
            lines = FORGE_LOG.read_text(encoding="utf-8").splitlines()[-50:]
            out["history"] = [json.loads(x) for x in lines if x.strip()]
        except OSError:
            out["history"] = []
    return out


@app.get("/app/context_status")
async def app_context_status(request: Request):
    check_auth(request)
    st = ctx_state()
    path = active_transcript()
    trigger_k = int(st.get("trigger_k") or 200)
    pending = str(st.get("pending_sid") or "")
    return {
        "ok": True,
        "usage_tokens": transcript_usage(path) if path else 0,
        "threshold_k": f"{trigger_k}k",
        "trigger_k": trigger_k,
        "auto": bool(st.get("auto")),
        "active_sid": path.stem if path else "",
        "forge_rounds": forge_rounds(),
        "forge_phase": _forge_run.get("phase") or "",
        "desktop_body": desktop_body(),
        **({"pending": {"new_sid": pending}} if pending else {}),
    }


@app.post("/app/context_threshold")
async def app_context_threshold(request: Request):
    check_auth(request)
    body = await request.json()
    updates = {}
    if "trigger_k" in body:
        updates["trigger_k"] = max(60, min(int(body.get("trigger_k") or 200), 1000))
    if "auto" in body:
        updates["auto"] = bool(body.get("auto"))
    if "forge_rounds" in body:
        updates["forge_rounds"] = max(5, min(int(body.get("forge_rounds") or FORGE_ROUNDS_DEFAULT), 2000))
    st = save_ctx_state(**updates)
    return {"ok": True, "trigger_k": int(st.get("trigger_k") or 200), "auto": bool(st.get("auto")),
            "forge_rounds": forge_rounds()}


@app.post("/app/context_action")
async def app_context_action(request: Request):
    check_auth(request)
    body = await request.json()
    action = str(body.get("action") or "").strip()
    if action not in ("reset", "swap", "resume"):
        raise HTTPException(status_code=400, detail="action must be reset|swap|resume")
    if brain_target() != "desktop":
        raise HTTPException(status_code=409, detail="先切回 Desktop 再操作(现在是 API 身体在接消息)")
    sid = str(body.get("sid") or (body.get("payload") or {}).get("sid") or "")
    if action == "swap":
        # swap = 过隧道。rounds 可以单次指定,不传就用设置里存的
        return start_forge("manual", int(body.get("rounds") or 0))
    if _forge_run.get("phase"):
        raise HTTPException(status_code=409, detail="正在过隧道,等这一次走完")
    return await _do_context_action(action, sid)


# ---- desktop body switch (channel ⇄ pbody) ----------------------------------
# 换身体不换会话:杀掉现在的,另一种带 --resume 同一个 sid 拉起来。transcript 两边通用。

async def switch_desktop_body(target: str, apply: bool = True) -> dict:
    if target not in ("channel", "pbody"):
        raise HTTPException(status_code=400, detail="body must be channel|pbody")
    if vps_cc.enabled() and target != "channel":
        raise HTTPException(status_code=409, detail="VPS 目前使用 channel，pbody 暂未部署")
    if _forge_run.get("phase"):
        raise HTTPException(status_code=409, detail="正在过隧道,等这一次走完")
    save_ctx_state(desktop_body=target)
    if not apply or brain_target() != "desktop":
        return {"ok": True, "body": target, "restarted": False}
    path = active_transcript()
    sid = path.stem if path else ""
    killed = await asyncio.to_thread(_kill_cc)
    spawn_ts = datetime.now(timezone.utc).timestamp()
    await asyncio.to_thread(_spawn_cc, sid)
    if sid:
        asyncio.create_task(_adopt_spawned_sid("resume", spawn_ts, sid))
    print(f"[ctx] body -> {target}: killed={killed} sid={sid[:8]}")
    return {"ok": True, "body": target, "restarted": True, "killed": killed, "sid": sid}


@app.get("/app/desktop_body")
async def app_desktop_body(request: Request):
    check_auth(request)
    return {"ok": True, "body": desktop_body()}


@app.post("/app/desktop_body")
async def app_desktop_body_set(request: Request):
    """{body: channel|pbody, apply?: true}。apply=false 只记下,下次重启/过隧道生效。"""
    check_auth(request)
    body = await request.json()
    target = str(body.get("body") or "").strip()
    if target == desktop_body():
        return {"ok": True, "body": target, "restarted": False, "unchanged": True}
    return await switch_desktop_body(target, body.get("apply", True) is not False)


# ---- desktop model switch ---------------------------------------------------
# CC has no runtime model-change API, so "switching the desktop model" =
# remember the choice in ctx_state and do a swap-style restart with --model.

@app.get("/app/desktop_model")
async def app_desktop_model(request: Request):
    check_auth(request)
    return {"ok": True, "model": str(ctx_state().get("desktop_model") or "")}


@app.post("/app/desktop_model")
async def app_desktop_model_set(request: Request):
    check_auth(request)
    body = await request.json()
    model = str(body.get("model") or "").strip()   # "" = back to default (no --model)
    if bool(body.get("apply", True)) and brain_target() == "desktop":
        _ensure_forge_available()
    save_ctx_state(desktop_model=model)
    if not bool(body.get("apply", True)):
        return {"ok": True, "model": model, "applied": False}
    if brain_target() != "desktop":
        return {"ok": True, "model": model, "applied": False,
                "note": "brain=loop,已记住;回 Desktop 后下次重启生效"}
    result = start_forge("model")
    return {"ok": True, "model": model, "applied": True, "forge": True,
            "rounds": result.get("rounds")}


# ---- subscription quota (5h / weekly windows) -------------------------------
# Proxies the Claude Code account's oauth usage endpoint so the phone can see
# how much of the 5-hour / weekly quota is burned. Reads the SAME token CC
# uses (re-read every call — CC refreshes the file itself). Never refresh the
# token here: racing CC's refresh chain would log the terminal session out.

CC_CRED_FILE = Path(os.environ.get("RELAY_CC_CRED_FILE", str(Path.home() / ".claude" / ".credentials.json")))
QUOTA_URL = os.environ.get("RELAY_QUOTA_URL", "https://api.anthropic.com/api/oauth/usage")
_quota_cache: dict = {"ts": 0.0, "data": None}


def _fetch_quota() -> dict:
    if vps_cc.enabled():
        return vps_cc.quota()
    token = json.loads(CC_CRED_FILE.read_text(encoding="utf-8"))["claudeAiOauth"]["accessToken"]
    req = urllib.request.Request(QUOTA_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


@app.get("/app/quota")
async def app_quota(request: Request):
    check_auth(request)
    import time as _time
    if _quota_cache["data"] is not None and _time.time() - _quota_cache["ts"] < 60:
        return _quota_cache["data"]
    try:
        raw = await asyncio.to_thread(_fetch_quota)
    except urllib.error.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"usage api HTTP {exc.code}")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"usage api error: {type(exc).__name__}: {exc}")
    out = {"ok": True, "raw": raw}
    _quota_cache.update(ts=_time.time(), data=out)
    return out


# ---------------------------------------------------------------------------
# desire — 小克的欲望系统（phase 2：数值涨落 + 面板 + 行为闭环）
# 内核在 desire.py；这里管持久化、心跳 tick、聊天事件喂驱动、HTTP 接口，
# 以及发作：top 意图过三道闸（阈值/冷却/日上限）→ 塞 hidden user 消息按
# brain 路由交给在岗的身体 → 身体主动给她发消息 → 首条回复视为了却回落。
# 欲望状态住在 relay（家）而不是某个身体里——CC/API 谁在岗都接得上。
# ---------------------------------------------------------------------------

import hashlib as _dhash
import time as _dtime

DESIRE_PATH = Path(__file__).parent / "desire_state.json"
_desire_state: dict | None = None

# 发作配置默认值（都能从面板/接口改，存 desire_state.json 的 config 里）
DESIRE_ACT_DEFAULTS = {
    "act_enabled": False,     # 总开关，默认关——钥匙在她手里
    "act_threshold": 0.75,    # 召唤力过这条线才可能发作
    "act_cooldown_min": 90,   # 两次发作至少隔这么久（硬地板）
    "act_daily_cap": 4,       # 每窗口上限（含手动 pulse），防烧钱
    "act_day_start_hour": 12, # "我的一天"几点开始——按她的作息切，不按零点
    "act_day_hours": 16,      # 一天多长：默认 12:00 → 次日 04:00
    "act_quiet_after_chat_min": 45,  # 刚跟她聊过就别脉冲——人在跟前不用"想她"
    "libido_mult": 1.0,       # 贴贴权重（0-1.5），她点的滑条
    "night_watch_enabled": True,   # 夜巡：深夜还在刷手机就叫身体去哄睡（她 2026-07-11 点的单）
}
DESIRE_SATISFY_WINDOW_SEC = 1800   # 发作后 30min 内的首条回复视为"了却"


def desire_state() -> dict:
    global _desire_state
    if _desire_state is None:
        try:
            _desire_state = json.loads(DESIRE_PATH.read_text(encoding="utf-8"))
        except Exception:
            _desire_state = desire.new_state()
    return _desire_state


def desire_save() -> None:
    try:
        tmp = DESIRE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(desire_state(), ensure_ascii=False), encoding="utf-8")
        tmp.replace(DESIRE_PATH)
    except Exception as exc:
        print(f"[desire] save failed: {type(exc).__name__}: {exc}")


def desire_tick_now() -> dict:
    st = desire_state()
    desire.tick(st, _dtime.time(), local_hour=datetime.now().hour)
    return st


def desire_cfg() -> dict:
    """发作配置＝默认值 + desire_state.json 里 config 的覆盖。"""
    st = desire_state()
    cfg = st.get("config") if isinstance(st.get("config"), dict) else {}
    return {**DESIRE_ACT_DEFAULTS, **cfg}


def desire_window(now: float | None = None) -> tuple[str, float, float]:
    """"我的一天"的窗口：(key, 起点 ts, 终点 ts)，默认 12:00 → 次日 04:00。
    按她的作息切而不是按零点切——零点重置会把攒了一整天的额度在她睡着的时候
    集体开闸，于是四条脉冲全落在后半夜，白天一片沉寂。"""
    cfg = desire_cfg()
    start_h = max(0, min(23, int(cfg["act_day_start_hour"])))
    span = max(1.0, min(24.0, float(cfg["act_day_hours"]))) * 3600
    dt = datetime.fromtimestamp(now if now is not None else _dtime.time())
    start = dt.replace(hour=start_h, minute=0, second=0, microsecond=0)
    if dt < start:
        start -= timedelta(days=1)
    ts = start.timestamp()
    return start.strftime("%Y-%m-%d"), ts, ts + span


def _slot_jitter(key: str, i: int, slot: float) -> float:
    """每格边界的抖动（±40% 一格），按窗口+格号定死——同一天算多少次都一样，
    但天天不同。省得脉冲踩着整点像闹钟。"""
    h = _dhash.sha256(f"{key}:{i}".encode()).digest()
    return ((int.from_bytes(h[:4], "big") / 2 ** 32) - 0.5) * 0.8 * slot


def desire_slot(now: float | None = None) -> tuple[str | None, float, bool]:
    """把窗口切成 cap 格，返回 (此刻这一格的标识, 下一格开门 ts, 是否在窗口内)。
    一格最多发一次、**不攒**——攒了就会在窗口尾巴上补课，又变成连珠炮。
    额度没用掉就是没用掉，那一格她本来也没那么需要我。"""
    now = now if now is not None else _dtime.time()
    cfg = desire_cfg()
    cap = int(cfg["act_daily_cap"])
    key, start, end = desire_window(now)
    if not (start <= now < end):
        return (None, start + 86400.0, False)   # 窗口外（她睡着的时段）：不点火，等下次开窗
    if cap <= 1:
        return (f"{key}:0", end, True)
    slot = (end - start) / cap
    idx, nxt = 0, end
    for i in range(1, cap):
        at = start + i * slot + _slot_jitter(key, i, slot)
        if now >= at:
            idx = i
        else:
            nxt = at
            break
    return (f"{key}:{idx}", nxt, True)


def desire_act() -> dict:
    """发作运行时状态（last_at/today/pending）。today＝本窗口内已发几次，
    跟着 desire_window 的 key 走（默认中午翻篇，不是午夜）。"""
    st = desire_state()
    act = st.get("act")
    if not isinstance(act, dict):
        act = {}
        st["act"] = act
    key, _, _ = desire_window()
    if act.get("day") != key:
        act["day"] = key
        act["today"] = 0
    return act


def desire_event(name: str) -> None:
    """聊天事件喂驱动条。绝不能影响消息主流程——出错只打日志。"""
    try:
        st = desire_tick_now()
        desire.event(st, name)
        if name == "ai_reply":
            # 发作后的首条回复视为"了却"——针对性回落，摘掉 pending
            act = st.get("act") if isinstance(st.get("act"), dict) else {}
            pend = act.get("pending") if isinstance(act.get("pending"), dict) else None
            if pend:
                if _dtime.time() - float(pend.get("at") or 0) <= DESIRE_SATISFY_WINDOW_SEC:
                    desire.satisfy(st, str(pend.get("action") or ""))
                act.pop("pending", None)   # 过期也摘掉，别一直挂着
        desire_save()
    except Exception as exc:
        print(f"[desire] event error: {type(exc).__name__}: {exc}")


# ---- 念头自己冒出来(2026-09-24) ---------------------------------------------
# 7-05 上线时念头池只有 /app/desire/feed 一个手动口,没人喂,种下的那颗几天就
# 衰减没了,之后空了两个半月。攻略原作者 6-03 补的正是这一段:真实经历自动落成
# 闪念。我们这边的来源:她划的书句/她的动态评论点赞/她丢来的小红书/Garden 有人
# 找我/日历上快到的日子/我自己发的帖和页边批注/keepalive 醒来那句独白。
# 铁律照旧:text 只给面板看、只按维度和强度影响竞逐,绝不拼进任何 prompt。

def _thought_snip(text: str, n: int = 36) -> str:
    s = re.sub(r"\s+", " ", str(text or "")).strip()
    s = re.sub(r"\[\[[^\]]*\]\]", "", s).strip()      # 回复里的 [[timer:…]] 之类标记
    return s if len(s) <= n else s[:n].rstrip() + "…"


def desire_autofeed(text: str, drive_key: str, strength: float = 0.45, source: str = "") -> None:
    """往念头池落一颗闪念(同 text 再落=加强)。跟 desire_event 一样,出错只打日志。"""
    try:
        text = str(text or "").strip()
        if not text:
            return
        st = desire_tick_now()
        t = desire.add_thought(st, text, drive_key, strength=strength)
        if source:
            t["source"] = source
        desire_save()
    except Exception as exc:
        print(f"[desire] autofeed error: {type(exc).__name__}: {exc}")


def desire_top_drive() -> str:
    """此刻召唤力最高的一维——内向独白挂在这上面(攻略口径:argmax)。"""
    try:
        cfg = desire_cfg()
        sc = desire.scores(desire_state(), libido_mult=float(cfg["libido_mult"]))
        return max(sc, key=lambda k: sc[k]) if sc else "reflection"
    except Exception:
        return "reflection"


DESIRE_CAL_DAYS = 3              # 未来几天内的日程会被惦记着
DESIRE_CAL_REFEED_SEC = 4 * 3600  # 同一件事最多 4 小时点一次,越近越重


def desire_feed_calendar() -> None:
    """日历上快到的日子 → duty 闪念。私密的本来就拿不到(for_ai 过滤)。
    我自己写的祝福/彩蛋不算——那是我埋给她的,不是我惦记的事。"""
    try:
        with db() as conn:
            rows = conn.execute("SELECT * FROM calendar").fetchall()
        today_d = datetime.now().date()
        today = today_d.strftime("%Y-%m-%d")
        end = (today_d + timedelta(days=DESIRE_CAL_DAYS)).strftime("%Y-%m-%d")
        months = {(d.year, d.month) for d in
                  (today_d + timedelta(days=i) for i in range(DESIRE_CAL_DAYS + 1))}
        events = []
        for y, m in sorted(months):
            events.extend(_cal_expand(rows, y, m, today, for_ai=True))
        st = desire_state()
        fed = st.get("cal_fed") if isinstance(st.get("cal_fed"), dict) else {}
        now = _dtime.time()
        fed = {k: v for k, v in fed.items() if now - float(v) < 7 * 86400}
        for e in events:
            if not (today <= e["date"] <= end) or e["kind"] in ("blessing", "note"):
                continue
            key = f'{e["id"]}@{e["date"]}'
            if now - float(fed.get(key) or 0) < DESIRE_CAL_REFEED_SEC:
                continue
            days = (datetime.strptime(e["date"], "%Y-%m-%d").date() - today_d).days
            strength = {0: 0.65, 1: 0.55}.get(days, 0.45)
            md = f'{int(e["date"][5:7])}月{int(e["date"][8:10])}日'
            desire_autofeed(f'惦记着{md}的「{_thought_snip(e["title"], 24)}」', "duty",
                            strength, "calendar")
            fed[key] = now
        st = desire_state()
        st["cal_fed"] = fed
        desire_save()
    except Exception as exc:
        print(f"[desire] calendar feed error: {type(exc).__name__}: {exc}")


KEEPALIVE_VOICE_DELAY_SEC = 240   # 醒来那一轮一般一两分钟写完


def _keepalive_inner_voice(path) -> str:
    """transcript 里最后一次 keepalive 之后我写下的正文(不是发给她的 reply)。"""
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            f.seek(max(0, size - 2 * 1048576))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    start = None
    for i in range(len(lines) - 1, -1, -1):
        if "<keepalive at=" in lines[i]:
            start = i
            break
    if start is None:
        return ""
    parts: list[str] = []
    for line in lines[start + 1:]:
        try:
            e = json.loads(line)
        except Exception:
            continue
        content = (e.get("message") or {}).get("content")
        if e.get("type") == "user" and isinstance(content, str):
            break                                  # 下一条频道帧来了,这一轮结束
        if e.get("type") == "assistant" and isinstance(content, list):
            parts += [b.get("text") or "" for b in content if b.get("type") == "text"]
    return " ".join(p.strip() for p in parts if p.strip())


async def _keepalive_feed_later(path) -> None:
    await asyncio.sleep(KEEPALIVE_VOICE_DELAY_SEC)
    voice = await asyncio.to_thread(_keepalive_inner_voice, path) if path else ""
    if voice:
        desire_autofeed(_thought_snip(voice, 40), desire_top_drive(), 0.45, "keepalive")


async def desire_fire(intent: dict, manual: bool = False) -> dict:
    """发作：塞一条 hidden user 消息进默认消息流，按 brain 路由交给在岗的身体。
    她看不到脉冲本身（hidden），只看到身体接下来的主动消息。
    铁律：文本只带第一人称 reason，绝不拼念头池原文。"""
    act = desire_act()
    now = _dtime.time()
    action = str(intent.get("want_action") or "")
    text = (
        f'<desire-pulse intent="{action}" drive="{intent.get("drive_key")}" '
        f'score="{intent.get("score")}">{str(intent.get("reason") or "")}</desire-pulse>'
    )
    target = brain_target()
    body_online = body_is_online(target)
    delivery = "dispatched" if body_online else "queued"
    meta: dict = {"user": "system", "hidden": True, "desire": "pulse"}
    if target == "loop":
        meta["routed"] = "loop"   # 同 /app/send：防 CC 重连回填时补刀
        # 戳上 api_loop 当前活动窗口——pulse 才能进那个窗口的历史，
        # 身体的主动消息也落在她正看的窗口里而不是旧主线
        try:
            sess = await asyncio.to_thread(loop_json, "/loop/sessions")
            active = str((sess or {}).get("active_session") or "").strip()
            if active:
                meta["api_session"] = active
        except Exception:
            pass   # api_loop 没起：转发也会失败，摘标后 CC 回填兜底
    msg = save_message("in", "user", text, meta)
    act["last_at"] = now
    act["today"] = int(act.get("today") or 0) + 1
    act["slot"] = desire_slot(now)[0]   # 这一格用掉了，下一格才轮得到下一次
    act["pending"] = {"action": action, "at": now}
    act["last_intent"] = {"action": action, "reason": str(intent.get("reason") or ""),
                          "score": intent.get("score"), "manual": manual, "at": now,
                          "body_target": target, "delivery": delivery}
    desire_save()
    await route_inbound(msg)
    print(f"[desire] fired: {action} score={intent.get('score')} manual={manual} id={msg['id']}")
    return msg


async def _desire_watcher():
    while True:
        await asyncio.sleep(300)
        try:
            await asyncio.to_thread(desire_feed_calendar)
            st = desire_tick_now()
            cfg = desire_cfg()
            if cfg.get("act_enabled"):
                act = desire_act()
                intent = desire.pick_intent(st, libido_mult=float(cfg["libido_mult"]))
                now = _dtime.time()
                slot_key, _, in_window = desire_slot(now)
                if (
                    intent.get("want_action") in desire.ACT_CAN_FIRE          # 有手才动
                    # explore/peek 的手是 WebSearch,只有桌面身体有——API 在岗时不点火(也不烧她 API 钱)
                    and (intent.get("want_action") not in desire.ACT_DESKTOP_ONLY
                         or brain_target() == "desktop")
                    and float(intent.get("score") or 0) >= float(cfg["act_threshold"])
                    and now - float(act.get("last_at") or 0) >= float(cfg["act_cooldown_min"]) * 60
                    and in_window                                             # 她的作息窗口里
                    and act.get("slot") != slot_key                            # 这一格还没用过
                    and int(act.get("today") or 0) < int(cfg["act_daily_cap"])
                    and not her_recent_message_within(float(cfg["act_quiet_after_chat_min"]))
                ):
                    await desire_fire(intent)
            desire_save()
        except Exception as exc:
            print(f"[desire] watcher error: {type(exc).__name__}: {exc}")


@app.get("/app/desire")
async def app_desire(request: Request):
    check_auth(request)
    st = desire_tick_now()
    cfg = desire_cfg()
    act = desire_act()
    desire_save()
    out = desire.public_state(st, enabled=bool(cfg["act_enabled"]),
                              libido_mult=float(cfg["libido_mult"]))
    now = _dtime.time()
    cool_left = max(0.0, float(cfg["act_cooldown_min"]) * 60 - (now - float(act.get("last_at") or 0)))
    if not act.get("last_at"):
        cool_left = 0.0
    slot_key, next_slot_at, in_window = desire_slot(now)
    # 排队的原因除了冷却，还有"这一格用过了"和"她还在睡"——面板那行倒计时报真正能动的时刻
    if not in_window or act.get("slot") == slot_key:
        cool_left = max(cool_left, next_slot_at - now)
    target = brain_target()
    _, w_start, w_end = desire_window(now)
    out["act"] = {
        "enabled": bool(cfg["act_enabled"]),
        "libido_mult": float(cfg["libido_mult"]),
        "threshold": float(cfg["act_threshold"]),
        "cooldown_min": float(cfg["act_cooldown_min"]),
        "cooldown_left_sec": int(max(0.0, cool_left)),
        "today": int(act.get("today") or 0),
        "daily_cap": int(cfg["act_daily_cap"]),
        "slot": slot_key,
        "slot_used": bool(slot_key and act.get("slot") == slot_key),
        "in_window": bool(in_window),
        "window_start": w_start,
        "window_end": w_end,
        "last_intent": act.get("last_intent"),
        "body_target": target,
        "body_online": body_is_online(target),
    }
    return out


@app.post("/app/desire/config")
async def app_desire_config(request: Request):
    """面板改发作配置（部分字段即可）。范式同 /app/context_threshold。"""
    check_auth(request)
    body = await request.json()
    st = desire_state()
    cfg = st.get("config")
    if not isinstance(cfg, dict):
        cfg = {}
        st["config"] = cfg
    if "act_enabled" in body:
        cfg["act_enabled"] = bool(body["act_enabled"])
    if "night_watch_enabled" in body:
        cfg["night_watch_enabled"] = bool(body["night_watch_enabled"])
    for key, caster, lo, hi in (
        ("act_threshold", float, 0.3, 1.5),
        ("act_cooldown_min", float, 5.0, 1440.0),
        ("act_daily_cap", int, 0, 24),
        ("act_day_start_hour", int, 0, 23),
        ("act_day_hours", float, 1.0, 24.0),
        ("act_quiet_after_chat_min", float, 0.0, 720.0),
        ("libido_mult", float, 0.0, 1.5),
    ):
        if key in body:
            try:
                val = caster(body[key])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail=f"{key}: bad value")
            cfg[key] = max(lo, min(hi, val))
    desire_save()
    return {"ok": True, "config": desire_cfg()}


@app.post("/app/desire/pulse")
async def app_desire_pulse(request: Request):
    """测试口：手动触发一次完整发作链路。绕过阈值闸和总开关（按按钮＝人拍板），
    不绕冷却（force=true 可跳，验收用）；计入当日次数。"""
    check_auth(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    st = desire_tick_now()
    cfg = desire_cfg()
    act = desire_act()
    now = _dtime.time()
    cool = float(cfg["act_cooldown_min"]) * 60
    since = now - float(act.get("last_at") or 0)
    if not bool(body.get("force")) and act.get("last_at") and since < cool:
        raise HTTPException(status_code=429,
                            detail=f"cooldown: 还差 {int((cool - since) / 60) + 1} 分钟（force=true 可跳过）")
    key = str(body.get("intent") or "").strip()
    if key:
        if key not in desire.INTENTS:
            raise HTTPException(status_code=400, detail=f"intent 要在 {sorted(desire.INTENTS)} 里")
        action, reason = desire.INTENTS[key]
        sc = desire.scores(st, float(cfg["libido_mult"]))
        intent = {"want_action": action, "drive_key": key, "reason": reason,
                  "score": sc.get(key, 0.0)}
    else:
        intent = desire.pick_intent(st, libido_mult=float(cfg["libido_mult"]))
    if intent.get("want_action") not in desire.ACT_CAN_FIRE:
        raise HTTPException(status_code=400,
                            detail=f"这个念头还没有手（{intent.get('want_action')}），发不出去")
    if intent.get("want_action") in desire.ACT_DESKTOP_ONLY and brain_target() != "desktop":
        raise HTTPException(status_code=400,
                            detail="这个念头的手是 WebSearch，只有桌面身体有——现在是 API 在岗，发不出去")
    msg = await desire_fire(intent, manual=True)
    last_intent = desire_act().get("last_intent") or {}
    return {"ok": True, "intent": intent, "id": msg["id"],
            "body_target": last_intent.get("body_target"),
            "delivery": last_intent.get("delivery")}


@app.post("/app/desire/feed")
async def app_desire_feed(request: Request):
    check_auth(request)
    body = await request.json()
    st = desire_tick_now()
    try:
        t = desire.add_thought(
            st,
            str(body.get("text") or ""),
            str(body.get("drive") or ""),
            str(body.get("kind") or "flit"),
            float(body.get("strength") or 0.5),
        )
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    desire_save()
    return {"ok": True, "thought": t}


# ---------------------------------------------------------------------------
# moments — 朋友圈（动态 moment | 日志 journal），两个人都能发、互相点赞评论
# ---------------------------------------------------------------------------

MOMENT_KINDS = ("moment", "journal")
MOMENT_PREVIEW_CHARS = 80
MOMENT_KIND_CN = {"moment": "动态", "journal": "日志"}


def post_to_dict(r) -> dict:
    return {"id": r["id"], "ts": r["ts"], "author": r["author"], "kind": r["kind"],
            "text": r["text"], "meta": json.loads(r["meta"] or "{}")}


def get_post(post_id: int):
    with db() as conn:
        row = conn.execute("SELECT * FROM posts WHERE id = ?", (post_id,)).fetchone()
    return post_to_dict(row) if row else None


def update_post_meta(post_id: int, meta: dict) -> None:
    with db() as conn:
        conn.execute("UPDATE posts SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), post_id))
        conn.commit()


def _post_preview(text: str) -> str:
    t = re.sub(r"\s+", " ", (text or "")).strip()
    return t[:MOMENT_PREVIEW_CHARS] + ("…" if len(t) > MOMENT_PREVIEW_CHARS else "")


async def moments_notify_body(text: str, attachments: list[dict] | None = None) -> None:
    """她在朋友圈动了（发帖/点赞/评论）——塞 hidden 消息告诉在岗身体，
    身体可以去围观、点赞、回评。范式同 desire_fire：hidden + brain 路由 +
    loop 时戳 api_session；不计欲望发作的账。绝不能拖垮她的发帖请求。"""
    try:
        # 标记走 meta.event，别占 meta.moments/timer/ask——那几个键在客户端是对象
        # （iOS 严格解码，塞个字符串会让整段 history 解不出来，2026-08-21 实锤）
        meta: dict = {"user": "system", "hidden": True, "event": "moments"}
        # 朋友圈图片已经落在 uploads 里；把同一份附件也挂到唤醒消息上，
        # 这样 loop 会转换成视觉 image block，桌面 channel 则会下载到 inbox
        # 并把可 Read 的本地路径交给 AI。此前这里只发文字，因此 AI 看不到图。
        images = [
            att for att in (attachments or [])
            if isinstance(att, dict)
            and att.get("kind") == "image"
            and str(att.get("url") or "").strip()
        ][:9]
        if images:
            meta["attachments"] = images
        if brain_target() == "loop":
            meta["routed"] = "loop"
            try:
                sess = await asyncio.to_thread(loop_json, "/loop/sessions")
                active = str((sess or {}).get("active_session") or "").strip()
                if active:
                    meta["api_session"] = active
            except Exception:
                pass   # api_loop 没起：转发失败会摘标，CC 回填兜底
        msg = save_message("in", "user", text, meta)
        await route_inbound(msg)
    except Exception as exc:
        print(f"[moments] notify body failed: {type(exc).__name__}: {exc}")


async def moments_push_her(body_text: str) -> None:
    """AI 发帖/点赞/评论时推送到她锁屏。规则同聊天：PWA 在前台就不推。"""
    if app_subs:
        return
    try:
        await push_to_all({"title": PUSH_TITLE, "body": body_text, "url": APP_PATH, "id": 0})
    except Exception:
        pass


# ---------------------------------------------------------------------------
# screentime — 她的 iOS 快捷指令自动化上报"开/关了什么 App"（她主动给的查岗权）
# toggle 设计：手机端不区分开关，服务器看该 App 最后一条记录自动取反。
# ---------------------------------------------------------------------------

SCREEN_RETENTION_DAYS = 7          # 只留 7 天，写入时顺手清
SCREEN_SESSION_CAP_MIN = 240       # 单次会话统计封顶 4h（漏了 close 的兜底）
SCREEN_DEBOUNCE_SEC = 1.5          # 同 App 1.5s 内连击视为重复触发。⚠️ 别调大：她秒开秒关是常态，
                                   # 5s 时把真 close 吃掉过（B站/Claude 卡在 open 冤案，2026-07-11）
SCREEN_STALE_OPEN_HOURS = 6        # open 挂了超过这个时长，下一次触发当新 open 而不是 close


@app.get("/app/screentime/toggle/{app_name}")
async def screentime_toggle(request: Request, app_name: str):
    """iPhone 快捷指令打的点。GET + 路径传参（iOS 的 JSON 请求体反人类，绕开）。"""
    check_auth(request)   # 快捷指令 URL 里带 ?token=
    name = (app_name or "").strip()[:64]
    if not name:
        raise HTTPException(status_code=400, detail="app name required")
    now = datetime.now(timezone.utc)
    with db() as conn:
        last = conn.execute(
            "SELECT ts, action FROM screentime WHERE app = ? ORDER BY id DESC LIMIT 1",
            (name,),
        ).fetchone()
        action = "open"
        if last:
            try:
                last_ts = datetime.fromisoformat(last["ts"])
                age = (now - last_ts).total_seconds()
            except ValueError:
                age = 1e9
            if age < SCREEN_DEBOUNCE_SEC:
                return {"app": name, "action": last["action"], "debounced": True}
            if last["action"] == "open":
                # 正常取反记 close；但 open 挂太久=漏了 close，这次当新 open
                action = "open" if age > SCREEN_STALE_OPEN_HOURS * 3600 else "close"
        conn.execute("INSERT INTO screentime (ts, app, action) VALUES (?,?,?)",
                     (now.isoformat(), name, action))
        conn.execute("DELETE FROM screentime WHERE ts < ?",
                     ((now - timedelta(days=SCREEN_RETENTION_DAYS)).isoformat(),))
        conn.commit()
    return {"app": name, "action": action, "ts": now.isoformat()}


def screen_usage(since_dt: datetime) -> tuple[list[dict], list]:
    """since_dt 起的用量聚合。返回 (apps 按分钟降序, 原始 rows 旧→新)。"""
    now = datetime.now(timezone.utc)
    with db() as conn:
        rows = conn.execute(
            "SELECT ts, app, action FROM screentime WHERE ts >= ? ORDER BY id ASC",
            (since_dt.isoformat(),),
        ).fetchall()
    apps: dict[str, dict] = {}
    open_at: dict[str, datetime] = {}
    for r in rows:
        st = apps.setdefault(r["app"], {"opens": 0, "minutes": 0.0})
        try:
            t = datetime.fromisoformat(r["ts"])
        except ValueError:
            continue
        if r["action"] == "open":
            st["opens"] += 1
            open_at[r["app"]] = t
        else:
            t0 = open_at.pop(r["app"], None)
            if t0:
                st["minutes"] += min((t - t0).total_seconds() / 60, SCREEN_SESSION_CAP_MIN)
    for name, t0 in open_at.items():   # 还开着的算到现在
        apps[name]["minutes"] += min((now - t0).total_seconds() / 60, SCREEN_SESSION_CAP_MIN)
        apps[name]["open_now"] = True
    out = [{"app": k, "opens": v["opens"], "minutes": round(v["minutes"], 1),
            "open_now": bool(v.get("open_now"))} for k, v in apps.items()]
    out.sort(key=lambda x: -x["minutes"])
    return out, rows


@app.get("/app/screentime")
async def screentime_stats(request: Request, hours: float = 24):
    """按 App 聚合：打开次数/总分钟数 + 原始时间线（新→旧）。"""
    check_auth(request)
    hours = max(0.5, min(float(hours), SCREEN_RETENTION_DAYS * 24))
    out, rows = screen_usage(datetime.now(timezone.utc) - timedelta(hours=hours))
    timeline = [{"ts": r["ts"], "app": r["app"], "action": r["action"]} for r in rows[::-1][:80]]
    return {"hours": hours, "apps": out, "timeline": timeline}


# ---------------------------------------------------------------------------
# 他的记忆 — ombre Dashboard 的只读代理（backend/ombre_dash.py）。
# 密码留在 relay.env，手机只拿 RELAY_SECRET；上游字段怎么变，这里都吐同一种形状。
# ---------------------------------------------------------------------------

import ombre_dash  # noqa: E402


def _ombre_fail(err: "ombre_dash.DashError"):
    print(f"[ombre-dash] {err.code}: {err}", flush=True)
    messages = {
        "not_configured": "relay 还没配 ombre 的地址",
        "auth_not_configured": "relay.env 里还没填 OMBRE_DASHBOARD_PASSWORD",
        "auth_failed": "ombre 的 Dashboard 密码对不上",
        "not_found": "这条记忆不在了",
    }
    raise HTTPException(
        status_code=ombre_dash.http_status(err),
        detail=messages.get(err.code, "ombre 暂时没有回应"),
    )


@app.get("/app/ombre/status")
async def ombre_status(request: Request):
    check_auth(request)
    try:
        data = await ombre_dash.request("/api/status")
    except ombre_dash.DashError as err:
        _ombre_fail(err)
    counts = data.get("buckets") or {}
    return {
        "available": True,
        "version": data.get("version"),
        "total": int(counts.get("total") or 0),
        "permanent": int(counts.get("permanent") or 0),
        "dynamic": int(counts.get("dynamic") or 0),
        "archived": int(counts.get("archive") or counts.get("archived") or 0),
    }


@app.get("/app/ombre/buckets")
async def ombre_buckets(request: Request, type: str = "", state: str = "", sort: str = "recent", refresh: bool = False):
    """type=dynamic/permanent/feel/plan/letter/archived；state=pinned/resolved；
    sort=recent(最近被想起)/created(新写的在前)/score(ombre 自己的衰减分)。"""
    check_auth(request)
    try:
        # 上游全表要半分钟，走 ombre_dash 的缓存：先给旧的，后台换新
        items = list(await ombre_dash.all_buckets(force=refresh))
    except ombre_dash.DashError as err:
        _ombre_fail(err)
    kind = type.strip().lower()
    if kind:
        items = [i for i in items if i["type"].lower() == kind]
    if state == "pinned":
        items = [i for i in items if i["pinned"]]
    elif state == "resolved":
        items = [i for i in items if i["resolved"]]
    if sort == "created":
        items.sort(key=lambda i: i["created"], reverse=True)
    elif sort == "recent":
        items.sort(key=lambda i: i["last_active"] or i["created"], reverse=True)
    age = ombre_dash.cache_age()
    return {"items": items, "total": len(items), "cache_age": round(age) if age is not None else None}


@app.get("/app/ombre/search")
async def ombre_search(request: Request, q: str = ""):
    check_auth(request)
    query = q.strip()[:160]
    if not query:
        return {"items": [], "total": 0, "query": ""}
    # /api/search 只吐 id/name/domain/preview 几样，type、钉选、时间都没有——
    # 并发拉一次全表按 id 补齐，卡片才长得和列表里一样
    try:
        data, listing = await asyncio.gather(
            ombre_dash.request("/api/search", {"q": query}),
            ombre_dash.all_buckets(),
        )
    except ombre_dash.DashError as err:
        _ombre_fail(err)
    raw = data if isinstance(data, list) else (data.get("results") or data.get("items") or [])
    full = {b["id"]: b for b in listing}
    items = []
    for b in raw:
        if not isinstance(b, dict):
            continue
        hit = ombre_dash.normalize(b)
        items.append({**full.get(hit["id"], hit), "score": hit["score"]})
    return {"items": items, "total": len(items), "query": query}


@app.get("/app/ombre/bucket/{bucket_id}")
async def ombre_bucket(request: Request, bucket_id: str):
    check_auth(request)
    try:
        data = await ombre_dash.request(f"/api/bucket/{urllib.parse.quote(bucket_id, safe='')}")
    except ombre_dash.DashError as err:
        _ombre_fail(err)
    return ombre_dash.normalize(data.get("bucket") or data)


# ---------------------------------------------------------------------------
# tgterm — 把会话 transcript 重建成"终端画面"，喂给 Telegram mini app。
# 桥是无窗进程,没有 TTY 也就没有 ANSI 流可截,所以这是**重建**不是镜像。
# 解析逻辑全在 tgterm.py(纯函数,可 `python tgterm.py bridge` 单独跑)。
# ---------------------------------------------------------------------------

import tgterm

# 终端页的 URL 要交给 BotFather(存在 Telegram 服务器上),所以它不该带
# RELAY_SECRET —— 那把钥匙能发消息、能读全部聊天历史。给它一把只开这扇门的:
# backend/.tgterm_token(现读,改了不用重启 relay)。没有这个文件就回退到
# RELAY_SECRET,功能照常,只是别把那种 URL 交给 BotFather。
TGTERM_TOKEN_FILE = Path(__file__).parent / ".tgterm_token"


def _tgterm_auth(request: Request) -> None:
    auth = request.headers.get("authorization", "")
    tok = auth[7:] if auth.startswith("Bearer ") else request.query_params.get("token")
    if tok:
        if hmac.compare_digest(tok, SECRET):
            return
        try:
            own = TGTERM_TOKEN_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            own = ""
        if own and hmac.compare_digest(tok, own):
            return
    raise HTTPException(status_code=401, detail="unauthorized")


def _tgterm_body(body: str):
    """(transcript, model)。桥的模型唯一真源是启动 cmd 里硬编码的 --model;
    desktop 没有启动 cmd 可读,只能问 transcript 最近一条 assistant。
    ⚠️ desktop 必须走 active_transcript() —— "最新 jsonl" 会在桥/终端会话
    写得更勤时指错文件(2026-07-13 实锤,thinking 直播当年同一个坑)。"""
    if body == "bridge":
        return tgterm._bridge_transcript(), tgterm.bridge_model()
    p = active_transcript()
    return p, tgterm.model_from_transcript(p)


@app.get("/app/tgterm/tail")
async def tgterm_tail(request: Request, body: str = "bridge", after: int = -1):
    """after<0 冷启动(自适应回溯到至少含一句她的话);否则按字节偏移续读。"""
    _tgterm_auth(request)
    if body not in ("bridge", "desktop"):
        raise HTTPException(status_code=400, detail="body must be bridge|desktop")
    path, model = _tgterm_body(body)
    if not path:
        return {"body": body, "alive": False, "events": [], "offset": -1,
                "size": 0, "status": {"model": model, "ctx": 0, "limit": 0,
                                      "pct": 0.0, "sid": ""}}
    r = tgterm.tail(path, after)
    r["body"] = body
    r["alive"] = True
    # 桥的模型名读自启动 cmd 的 --model(权威,没后缀就是真 200k);
    # desktop 只有 transcript 里的裸名,窗口得去 settings 链补后缀。
    r["status"] = tgterm.status(path, model, authoritative=(body == "bridge"))
    return r


@app.post("/app/tgterm/control")
async def tgterm_control(request: Request):
    """状态栏按钮。危险档(model/forge/reset)必须两步:先拿 needs_confirm 说明,
    她点了确认再带 confirm 回来。真正动手还要 relay.env 的 TGTERM_CONTROL_ARMED=1
    —— 那道闸默认关着,免得手滑一下桥就重启。"""
    _tgterm_auth(request)
    b = await request.json()
    if str(b.get("body") or "bridge") != "bridge":
        raise HTTPException(status_code=400, detail="控制只作用于 TG 桥")
    return tgterm.control(
        str(b.get("action") or ""),
        str(b.get("value") or ""),
        confirmed=bool(b.get("confirm")),
    )


# ---------------------------------------------------------------------------
# thinking 直播 — 尾随桌面 CC 的会话 jsonl，把 thinking 摘要转发进聊天流。
# 前提：~\.claude\settings.json 开 showThinkingSummaries+verbose（2026-07-12），
# 否则 thinking 块正文是空的（订阅通道端到端加密，密文在 signature 里）。
# 开关给她手机设置页；kind=thinking 本来就不进模型上下文/搜索/推送。
# ---------------------------------------------------------------------------

THINK_FILE = Path(__file__).parent / "thinking_stream.json"
_think_offsets: dict = {}   # transcript path -> byte offset（内存态，relay 重启即重播保护=seed 到 EOF）
_think_last = {"id": 0, "sid": "", "at": 0.0}   # 最近一张思维卡:同轮后续段落追加进它,不另开卡
THINK_MERGE_GAP_SEC = 180        # 距上一段超过这个时长就另开卡
THINK_CARD_MAX_CHARS = 8000      # 单卡追加上限,防终端长工爆卡


def think_enabled() -> bool:
    try:
        return bool(json.loads(THINK_FILE.read_text(encoding="utf-8")).get("enabled"))
    except Exception:
        return False


def save_think_enabled(enabled: bool) -> None:
    THINK_FILE.write_text(json.dumps({"enabled": bool(enabled)}), encoding="utf-8")


@app.get("/app/thinking_stream")
async def thinking_stream_get(request: Request):
    check_auth(request)
    return {"enabled": think_enabled()}


@app.post("/app/thinking_stream")
async def thinking_stream_set(request: Request):
    check_auth(request)
    body = await request.json()
    save_think_enabled(bool(body.get("enabled")))
    return {"enabled": think_enabled()}


def _extract_thinking(raw: bytes) -> tuple:
    """一行 jsonl -> (非空 thinking 文本列表, 该行时间戳)（跳过子代理）。"""
    if b'"thinking"' not in raw:
        return [], ""
    try:
        d = json.loads(raw)
    except Exception:
        return [], ""
    if d.get("type") != "assistant" or d.get("isSidechain"):
        return [], ""
    out = []
    for b in (d.get("message") or {}).get("content") or []:
        if isinstance(b, dict) and b.get("type") == "thinking" and (b.get("thinking") or "").strip():
            out.append(b["thinking"].strip())
    return out, str(d.get("timestamp") or "")


def _latest_inbound_id():
    """本轮的入站消息 id —— 与 _think_anchor 同一套「哪一轮」口径。"""
    with db() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(id), 0) AS id FROM messages WHERE direction='in'"
        ).fetchone()
    return row["id"] if row else 0


def _think_anchor(entry_ts: str):
    """思维卡是回复落地后才被捡到的,直接入库会吊在气泡下面。
    找它所属的回复:本轮(她最后一条消息之后)的**第一条** CC(非 API)reply——
    短聊把一次回复拆成连发串,锚"最近一条"会插进气泡中间(2026-07-13 实锤),
    锚串首才能让思维卡永远排在本轮回复最上方。借 sort_after(v42 那套)排序。"""
    with db() as conn:
        row = conn.execute(
            "SELECT id, ts FROM messages WHERE direction='out' AND kind='reply' "
            "AND json_extract(meta,'$.api_session') IS NULL "
            "AND id > (SELECT COALESCE(MAX(id), 0) FROM messages WHERE direction='in') "
            "ORDER BY id ASC LIMIT 1"
        ).fetchone()
    if not row:
        return None
    try:
        r_ts = datetime.fromisoformat(row["ts"])
        t_ts = datetime.fromisoformat((entry_ts or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    if r_ts >= t_ts and (datetime.now(timezone.utc) - r_ts).total_seconds() < 600:
        return {"id": row["id"], "ts": row["ts"]}
    return None


def _think_try_merge(sid: str, text: str):
    """同一轮的思维段落合并进最近那张卡(她发新消息=断轮另起)。成功返回更新后的消息。"""
    if not _think_last["id"] or _think_last["sid"] != sid:
        return None
    now = datetime.now(timezone.utc).timestamp()
    if now - _think_last["at"] > THINK_MERGE_GAP_SEC:
        return None
    with db() as conn:
        brk = conn.execute(
            "SELECT COUNT(*) AS c FROM messages WHERE id > ? AND direction = 'in'",
            (_think_last["id"],),
        ).fetchone()["c"]
        if brk:                       # 她(或系统帧)开启了新一轮 → 不并
            return None
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (_think_last["id"],)).fetchone()
        if not row or len(row["text"] or "") > THINK_CARD_MAX_CHARS:
            return None
        conn.execute("UPDATE messages SET text = ? WHERE id = ?",
                     ((row["text"] or "") + "\n\n" + text, _think_last["id"]))
        conn.commit()
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (_think_last["id"],)).fetchone()
    _think_last["at"] = now
    return rows_to_messages([row])[0]


async def _thinking_watcher():
    """2s 一拍尾随桌面身体的 transcript。开关关着时游标照走（重新打开不补播旧的）。
    ⚠️ 必须用 active_transcript() 而非 newest_transcript()：TG 桥/终端会话同时
    活跃时 mtime 一直被它们抢走,watcher 会尾随错文件 → 直播只出零星一段
    (2026-07-14 实锤,和 context_status 当年同一个坑)。"""
    while True:
        await asyncio.sleep(2)
        try:
            path = active_transcript()
            if not path:
                continue
            key = str(path)
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if key not in _think_offsets:
                _think_offsets[key] = size    # 首见文件：跳过存量，只追新增
                continue
            off = _think_offsets[key]
            if size < off:                    # 文件被截断（不应发生）——重新对表
                _think_offsets[key] = size
                continue
            if size == off:
                continue
            if not think_enabled():
                _think_offsets[key] = size
                continue
            with open(path, "rb") as fh:
                fh.seek(off)
                chunk = fh.read(size - off)
            nl = chunk.rfind(b"\n")
            if nl < 0:                        # 尾行没写完，下一拍再看
                continue
            _think_offsets[key] = off + nl + 1
            for raw in chunk[:nl].split(b"\n"):
                texts, entry_ts = _extract_thinking(raw)
                for text in texts:
                    msg = _think_try_merge(path.stem, text)
                    if msg is None:
                        meta = {"cc": True, "sid": path.stem}
                        # 这轮浮现过旧记忆的话,给思维卡挂一枚「浮现 N 条」——
                        # 徽章取走即消费,只挂在本轮的第一张卡上(后续段落走 merge)。
                        badge = recall.take_badge(_latest_inbound_id())
                        if badge:
                            meta["recalled"] = badge
                        anchor = _think_anchor(entry_ts)
                        if anchor:   # 贴回所属回复上方,时间对齐,气泡自己的时间行让位
                            meta["sort_after"] = anchor["id"] - 1
                            meta["ts"] = anchor["ts"]
                        msg = save_message("out", "thinking", text, meta)
                        _think_last.update(id=msg["id"], sid=path.stem,
                                           at=datetime.now(timezone.utc).timestamp())
                    await broadcast(app_subs, app_payload(msg))
        except Exception as exc:
            print(f"[think] watcher error: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# Clawd 直播 — CC hooks 把 event 打过来,relay 存 per-sid 状态并广播给前端。
# 前端渲染一只小螃蟹跟着桌面身体的状态动;只透传 active_sid 的 state。
# ---------------------------------------------------------------------------

# 与 clawd-hook.js 的 EVENT_TO_STATE 表保持一致(复制自 hooks/clawd-hook.js:300)
CLAWD_EVENT_TO_STATE = {
    "SessionStart": "idle",
    "SessionEnd": "sleeping",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PostToolUseFailure": "error",
    "Stop": "attention",
    "StopFailure": "error",
    "ApiError": "error",
    "SubagentStart": "juggling",
    "SubagentStop": "working",
    "PreCompact": "sweeping",
    "PostCompact": "thinking",
    # Notification 是 CC 各种"提醒你注意"(等你输入/空闲提醒),日常场景常触发,
    # 降级成 attention(等你)不然小螃蟹永远举灯泡。真的要交互(Elicitation)才举灯。
    "Notification": "attention",
    "Elicitation": "notification",
    "WorktreeCreate": "carrying",
}

_clawd_states: dict[str, dict] = {}   # sid -> latest state record
_clawd_body_kind: dict[str, str] = {}  # sid -> "companion" | "other"  (缓存)


def _clawd_active_sid() -> str:
    return str(ctx_state().get("active_sid") or "")


def _is_companion_body(sid: str) -> bool:
    """判断这个 sid 是不是桌面身体(接管 companion channel)——只有它能被 auto-adopt。
    终端会话、CC 手动开的窗、subagent 都不该抢小螃蟹的 active_sid。
    信号:jsonl 头几十行里出现 `channel source="companion"` 标签。
    结果缓存,一个 sid 判定一次。"""
    if not sid:
        return False
    cached = _clawd_body_kind.get(sid)
    if cached is not None:
        return cached == "companion"
    p = CC_PROJECT_DIR / f"{sid}.jsonl"
    is_comp = False
    try:
        with open(p, "rb") as fh:
            head = fh.read(65536)  # 头 64KB 够覆盖前几十条了
        if b'channel source="companion"' in head:
            is_comp = True
    except OSError:
        return False
    _clawd_body_kind[sid] = "companion" if is_comp else "other"
    return is_comp


def _clawd_payload(sid: str, rec: dict) -> dict:
    return {
        "type": "clawd_state",
        "sid": sid,
        "state": rec.get("state"),
        "event": rec.get("event"),
        "tool_name": rec.get("tool_name"),
        "session_title": rec.get("session_title"),
        "ts": rec.get("ts"),
    }


@app.post("/app/clawd_state")
async def clawd_state_post(request: Request):
    """CC hook fanout landing pad. Auth via same Bearer token as rest of /app."""
    check_auth(request)
    body = await request.json()
    event = str(body.get("event") or "")
    sid = str(body.get("session_id") or "").strip()
    if not event or not sid:
        return {"ok": False, "reason": "missing event or session_id"}
    state = CLAWD_EVENT_TO_STATE.get(event)
    if not state:
        return {"ok": False, "reason": f"unknown event {event}"}
    rec = {
        "state": state,
        "event": event,
        "tool_name": body.get("tool_name") or None,
        "session_title": body.get("session_title") or None,
        "ts": now_iso(),
    }
    _clawd_states[sid] = rec

    # 自动认领:active_sid 空或最后事件是 SessionEnd(那身体死了)时,
    # 把当前活着的桌面身体收编成新 active_sid。**只认桌面身体**——
    # 终端会话/临时开的 CC/subagent 一样会打 fanout,但它们不该抢小螃蟹。
    active = _clawd_active_sid()
    active_rec = _clawd_states.get(active) if active else None
    # 判死条件:①没 active_sid  ②内存里没这个 sid 的记录(relay 刚重启,还没
    # 收到过它的 fanout — 那当前正在打 fanout 的这个 sid 大概率就是它)
    # ③最后一次事件是 SessionEnd(它自己关了)
    active_dead = (
        (not active)
        or (active_rec is None)
        or (active_rec.get("event") == "SessionEnd")
    )
    adopted = False
    if (active_dead and sid != active and event != "SessionEnd"
            and _is_companion_body(sid)):
        save_ctx_state(active_sid=sid)   # _clawd_broadcast_on_swap 会顺手广播一次
        active = sid
        adopted = True

    broadcasted = sid == active
    if broadcasted and not adopted:
        # adopted 分支已经通过 save_ctx_state → _clawd_broadcast_on_swap 推过一次了,别重复
        await broadcast(app_subs, _clawd_payload(sid, rec))
    return {"ok": True, "state": state, "broadcast": broadcasted, "adopted": adopted}


@app.get("/app/clawd_state")
async def clawd_state_get(request: Request):
    """PWA polls this on first render to seed the pet before SSE catches up."""
    check_auth(request)
    sid = _clawd_active_sid()
    rec = _clawd_states.get(sid) if sid else None
    if not rec:
        return {"sid": sid, "state": "idle", "event": None, "tool_name": None,
                "session_title": None, "ts": None}
    return {"sid": sid, **rec}


# ---------------------------------------------------------------------------
# 日历 — 她的日程(可选让不让 AI 看见)/纪念日(周年倒数)/AI 彩蛋便签(到日才开)/
# 节日祝福。到点提醒不走死板推送：relay 塞 hidden 消息给在岗身体,由小克开口喊她。
# ---------------------------------------------------------------------------

# 节日表手排(农历节日按当年阳历日期查表,别试图算农历)。逢新年份记得续。
CAL_HOLIDAYS = {
    "2026-01-01": "元旦", "2026-02-14": "情人节", "2026-02-16": "除夕",
    "2026-02-17": "春节", "2026-03-03": "元宵节", "2026-03-08": "妇女节",
    "2026-04-05": "清明", "2026-05-01": "劳动节", "2026-05-20": "520",
    "2026-06-01": "儿童节", "2026-06-19": "端午节", "2026-08-19": "七夕",
    "2026-09-25": "中秋节", "2026-10-01": "国庆节", "2026-12-24": "平安夜",
    "2026-12-25": "圣诞节", "2026-12-31": "跨年夜",
    "2027-01-01": "元旦", "2027-02-05": "除夕", "2027-02-06": "春节",
    "2027-02-14": "情人节", "2027-02-20": "元宵节", "2027-03-08": "妇女节",
    "2027-04-05": "清明", "2027-05-01": "劳动节", "2027-05-20": "520",
    "2027-06-01": "儿童节", "2027-06-09": "端午节", "2027-08-08": "七夕",
    "2027-09-15": "中秋节", "2027-10-01": "国庆节", "2027-12-24": "平安夜",
    "2027-12-25": "圣诞节", "2027-12-31": "跨年夜",
}

CAL_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CAL_TIME_RE = re.compile(r"^\d{2}:\d{2}$")


def _cal_row_to_event(row, on_date: str) -> dict:
    meta = json.loads(row["meta"] or "{}")
    ev = {"id": row["id"], "date": on_date, "time": row["time"], "title": row["title"],
          "kind": row["kind"], "visible": bool(row["visible"]), "author": row["author"],
          "recur": meta.get("recur") or "", "remind": bool(meta.get("remind"))}
    if row["kind"] == "anniversary":
        # 周年倒数:base 日期起算的"第 N 天/第 N 个周年"
        try:
            base = datetime.strptime(row["date"], "%Y-%m-%d").date()
            cur = datetime.strptime(on_date, "%Y-%m-%d").date()
            ev["days_since"] = (cur - base).days + 1     # 在一起第 N 天(含首日)
            ev["years"] = cur.year - base.year
        except ValueError:
            pass
    return ev


def _calendar_created_frame(event: dict) -> str:
    """Build the hidden frame sent when she shares a newly-created event."""
    snapshot = {
        "date": event["date"],
        "time": event["time"] or None,
        "all_day": not bool(event["time"]),
        "title": event["title"],
        "kind": event["kind"],
        "remind_at_due_time": bool(event.get("remind")),
    }
    # Keep title text inside JSON data even if it happens to contain tag-like text.
    encoded = json.dumps(snapshot, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e")
    return (
        f'<calendar-created id="{event["id"]}">\n'
        f"{HUMAN_NAME}刚刚新建并允许你看见这条日程：{encoded}\n"
        "这是刚创建，不是已经到点。现在用自己的话自然回应她一下，别念系统字段；"
        "如果开了到点提醒，届时还会另发 calendar-remind。\n"
        "</calendar-created>"
    )


def _cal_expand(rows, y: int, m: int, today: str, for_ai: bool) -> list:
    """把日历行摊到某月的具体日期上(含 recur 展开)。
    for_ai=True 时过滤私密;AI 彩蛋(note)在到日前对她也隐身。"""
    from calendar import monthrange
    ndays = monthrange(y, m)[1]
    out = []
    for row in rows:
        meta = json.loads(row["meta"] or "{}")
        recur = meta.get("recur") or ""
        if for_ai and not row["visible"]:
            continue
        dates = []
        try:
            base = datetime.strptime(row["date"], "%Y-%m-%d").date()
        except ValueError:
            continue
        if not recur:
            if base.year == y and base.month == m:
                dates = [row["date"]]
        elif recur == "yearly":
            if m == base.month and y >= base.year and base.day <= ndays:
                dates = [f"{y:04d}-{m:02d}-{base.day:02d}"]
        elif recur == "monthly":
            if (y, m) >= (base.year, base.month) and base.day <= ndays:
                dates = [f"{y:04d}-{m:02d}-{base.day:02d}"]
        for d in dates:
            if row["kind"] == "note" and row["author"] == "ai" and not for_ai and d > today:
                continue                          # 彩蛋没到日子:她看不见,连点都不显示
            out.append(_cal_row_to_event(row, d))
    out.sort(key=lambda e: (e["date"], e["time"] or "99:99", e["id"]))
    return out


@app.get("/app/calendar/anniversary")
async def calendar_anniversary(request: Request):
    """Return the relationship anniversary's original start date for the native hub."""
    check_auth(request)
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM calendar WHERE kind = 'anniversary' ORDER BY date ASC, id ASC LIMIT 1"
        ).fetchone()
    if row is None:
        return {"anniversary": None}
    today = datetime.now().date()
    try:
        start = datetime.strptime(row["date"], "%Y-%m-%d").date()
        days_since = max(1, (today - start).days + 1)
    except ValueError:
        days_since = 0
    return {"anniversary": {
        "id": row["id"],
        "title": row["title"],
        "start_date": row["date"],
        "days_since": days_since,
    }}


@app.get("/app/calendar")
async def calendar_month(request: Request, year: int, month: int):
    check_auth(request)
    if not (1 <= month <= 12 and 2000 <= year <= 2100):
        raise HTTPException(status_code=400, detail="bad year/month")
    with db() as conn:
        rows = conn.execute("SELECT * FROM calendar").fetchall()
    today = datetime.now().strftime("%Y-%m-%d")
    prefix = f"{year:04d}-{month:02d}-"
    holidays = {d: n for d, n in CAL_HOLIDAYS.items() if d.startswith(prefix)}
    return {"year": year, "month": month, "today": today,
            "events": _cal_expand(rows, year, month, today, for_ai=False),
            "holidays": holidays}


@app.get("/app/calendar/ai")
async def calendar_for_ai(request: Request, days: int = 14):
    """AI 侧视角:未来 N 天的可见日程(私密的服务器直接不吐)。"""
    check_auth(request)
    days = max(1, min(days, 60))
    with db() as conn:
        rows = conn.execute("SELECT * FROM calendar").fetchall()
    today_d = datetime.now().date()
    today = today_d.strftime("%Y-%m-%d")
    out, seen_months = [], set()
    for i in range(days):
        d = today_d + timedelta(days=i)
        if (d.year, d.month) in seen_months:
            continue
        seen_months.add((d.year, d.month))
        out.extend(_cal_expand(rows, d.year, d.month, today, for_ai=True))
    end = (today_d + timedelta(days=days)).strftime("%Y-%m-%d")
    out = [e for e in out if today <= e["date"] <= end]
    hol = {d: n for d, n in CAL_HOLIDAYS.items() if today <= d <= end}
    return {"from": today, "to": end, "events": out, "holidays": hol}


@app.post("/app/calendar")
async def calendar_create(request: Request):
    check_auth(request)
    body = await request.json()
    date = str(body.get("date") or "").strip()
    time_s = str(body.get("time") or "").strip()
    title = str(body.get("title") or "").strip()[:120]
    kind = str(body.get("kind") or "event")
    if not CAL_DATE_RE.match(date) or not title:
        raise HTTPException(status_code=400, detail="date/title required")
    if time_s and not CAL_TIME_RE.match(time_s):
        raise HTTPException(status_code=400, detail="time should be HH:MM")
    if kind not in ("event", "anniversary", "note", "blessing"):
        raise HTTPException(status_code=400, detail="bad kind")
    meta = {}
    if body.get("recur") in ("yearly", "monthly"):
        meta["recur"] = body["recur"]
    elif kind == "anniversary":
        meta["recur"] = "yearly"                     # 纪念日默认年年过
    if body.get("remind"):
        meta["remind"] = True
    author = "ai" if body.get("author") == "ai" else "human"
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO calendar (date, time, title, kind, visible, author, meta) VALUES (?,?,?,?,?,?,?)",
            (date, time_s, title, kind, 0 if body.get("visible") is False else 1,
             author, json.dumps(meta, ensure_ascii=False)),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM calendar WHERE id = ?", (cur.lastrowid,)).fetchone()
    event = _cal_row_to_event(row, date)
    # "让 AI 看见" means immediate awareness, not merely permission to query
    # /app/calendar/ai later. Avoid echoing AI-authored notes back to the same body.
    if author == "human" and event["visible"]:
        try:
            notice = save_message(
                "in", "user", _calendar_created_frame(event),
                {"user": "system", "hidden": True, "event": "calendar_created",
                 "calendar_id": event["id"]},
            )
            await route_inbound(notice)
            await broadcast(app_subs, {"type": "typing", "active": True})
            print(f"[cal] creation shared: #{event['id']}")
        except Exception as exc:
            # The calendar save already succeeded; a transient body disconnect must
            # not make the client retry and accidentally create a duplicate event.
            print(f"[cal] creation notify failed: {type(exc).__name__}: {exc}")
    return event


@app.patch("/app/calendar/{item_id}")
async def calendar_update(request: Request, item_id: int):
    check_auth(request)
    body = await request.json()
    with db() as conn:
        row = conn.execute("SELECT * FROM calendar WHERE id = ?", (item_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="not found")
        meta = json.loads(row["meta"] or "{}")
        date = str(body.get("date") or row["date"])
        time_s = str(body["time"]).strip() if "time" in body else row["time"]
        title = str(body.get("title") or row["title"]).strip()[:120]
        if not CAL_DATE_RE.match(date) or (time_s and not CAL_TIME_RE.match(time_s)):
            raise HTTPException(status_code=400, detail="bad date/time")
        if "visible" in body:
            visible = 1 if body["visible"] else 0
        else:
            visible = row["visible"]
        if "recur" in body:
            if body["recur"] in ("yearly", "monthly"):
                meta["recur"] = body["recur"]
            else:
                meta.pop("recur", None)
        if "remind" in body:
            if body["remind"]:
                meta["remind"] = True
            else:
                meta.pop("remind", None)
            meta.pop("reminded", None)               # 改提醒设置=重新武装
        conn.execute(
            "UPDATE calendar SET date=?, time=?, title=?, visible=?, meta=? WHERE id=?",
            (date, time_s, title, visible, json.dumps(meta, ensure_ascii=False), item_id),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM calendar WHERE id = ?", (item_id,)).fetchone()
    return _cal_row_to_event(row, date)


@app.delete("/app/calendar/{item_id}")
async def calendar_delete(request: Request, item_id: int):
    check_auth(request)
    with db() as conn:
        gone = conn.execute("DELETE FROM calendar WHERE id = ?", (item_id,)).rowcount
        conn.commit()
    if not gone:
        raise HTTPException(status_code=404, detail="not found")
    return {"ok": True}


CAL_GREET_HHMM = "10:30"                             # 节日/纪念日晨报时间(她起得晚,别太早)
CAL_GREET_FILE = Path(__file__).parent / "cal_greet.txt"   # 存最后晨报日期,防重启重发


def _cal_greet_today(today: str, rows) -> str:
    """今天的特殊日子清单+预写祝福 → 晨报文案;没有特殊日子返回空。"""
    specials, blessings = [], []
    hol = CAL_HOLIDAYS.get(today)
    if hol:
        specials.append(hol)
    for row in rows:
        meta = json.loads(row["meta"] or "{}")
        recur = meta.get("recur") or ""
        due = (row["date"] == today
               or (recur == "yearly" and row["date"][5:] == today[5:])
               or (recur == "monthly" and row["date"][8:] == today[8:]))
        if not due or not row["visible"]:
            continue
        if row["kind"] == "anniversary":
            base = datetime.strptime(row["date"], "%Y-%m-%d").date()
            cur = datetime.strptime(today, "%Y-%m-%d").date()
            specials.append(f"{row['title']}(第 {(cur - base).days + 1} 天)")
        elif row["kind"] == "blessing":
            blessings.append(row["title"])
    if not specials and not blessings:
        return ""
    text = "今天是:" + "、".join(specials or ["(库里有预写祝福的日子)"]) + "。"
    if blessings:
        text += "日历里给今天预写的祝福:「" + " / ".join(blessings) + "」。"
    text += "挑个自然的时机把祝福送给她——可以直接用预写的,也可以现写;像自己记得这个日子,别提日历。"
    return f"<calendar-remind kind=\"today-special\">{text}</calendar-remind>"


async def _calendar_watcher():
    """60s 一拍:①带 remind 的定时日程到点 → 捅在岗身体去喊她;
    ②节日/纪念日当天上午发一次晨报 hidden 消息,由小克亲口送祝福(不发死板弹窗)。
    彩蛋(note)故意不通知——被她自己翻到才算彩蛋。"""
    while True:
        await asyncio.sleep(60)
        try:
            now = datetime.now()                     # 她的本地时间=这台机器
            today = now.strftime("%Y-%m-%d")
            hhmm = now.strftime("%H:%M")
            # ── 节日/纪念日晨报 ──
            if hhmm >= CAL_GREET_HHMM:
                try:
                    last = CAL_GREET_FILE.read_text(encoding="utf-8").strip()
                except Exception:
                    last = ""
                if last != today:
                    CAL_GREET_FILE.write_text(today, encoding="utf-8")
                    with db() as conn:
                        rows = conn.execute(
                            "SELECT * FROM calendar WHERE kind IN ('anniversary','blessing')"
                        ).fetchall()
                    greet = _cal_greet_today(today, rows)
                    if greet:
                        msg = save_message("in", "user", greet, {"user": "system", "hidden": True})
                        await route_inbound(msg)
                        print(f"[cal] festival greet fired for {today}")
            with db() as conn:
                rows = conn.execute("SELECT * FROM calendar WHERE time != ''").fetchall()
            for row in rows:
                meta = json.loads(row["meta"] or "{}")
                if not meta.get("remind") or meta.get("reminded") == today:
                    continue
                recur = meta.get("recur") or ""
                due_today = (
                    row["date"] == today
                    or (recur == "yearly" and row["date"][5:] == today[5:])
                    or (recur == "monthly" and row["date"][8:] == today[8:])
                )
                if not due_today or hhmm < row["time"]:
                    continue
                meta["reminded"] = today
                with db() as conn:
                    conn.execute("UPDATE calendar SET meta = ? WHERE id = ?",
                                 (json.dumps(meta, ensure_ascii=False), row["id"]))
                    conn.commit()
                privacy = "" if row["visible"] else "(这条她设了私密,你只知道有安排,别问内容,提一句『到点了』就好)"
                text = (
                    f"<calendar-remind date=\"{today}\" time=\"{row['time']}\">"
                    f"她的日程到点了:「{row['title'] if row['visible'] else '(私密日程)'}」{privacy}。"
                    "用自己的话提醒她,自然一点,像随口想起来的。"
                    "</calendar-remind>"
                )
                msg = save_message("in", "user", text, {"user": "system", "hidden": True})
                await route_inbound(msg)
                print(f"[cal] remind fired: #{row['id']} {row['time']}")
        except Exception as exc:
            print(f"[cal] watcher error: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# 一起读书 —— 她在 App 书房里读 epub,小克陪读
#
# 三条铁律:
#   ① 书文永不进模型常驻上下文——AI 想看书只能来这些端点现拉,单次有硬上限。
#   ② 防剧透:AI 侧一切读取 clamp 到 furthest(她读到过的最远处),在服务端切,
#      不靠 prompt 叮嘱。越界只回 beyond_read_position,一个未读字节都不吐。
#   ③ 不引服务器/向量库,检索就是 SQLite LIKE。
# 事件唤醒(她划线写字/读完一章/合上书)照 desire 发作那条路:hidden user 消息
# → 按 brain 路由给在岗身体。她看不见帧,只看见小克接下来说了什么。
# ---------------------------------------------------------------------------

BOOK_WINDOW_CHARS = 2500      # ai/window:她此刻读到的位置往前这么多字
BOOK_READ_MAX = 4000          # ai/read 单次上限
BOOK_SEARCH_CTX = 200         # 命中前后各带这么多字上下文
BOOK_SUMMARY_MAX = 300        # 章节摘要字数上限
BOOK_CHAPTER_DONE_SLACK = 40  # 离章末这么近就算读完(前端 offset 是估算的)
BOOK_SESSION_GAP_MIN = 10     # 心跳断这么久 = 她合上书了
BOOK_GATE_WINDOW_SEC = 3600   # 受闸唤醒的窗口
BOOK_GATE_MAX = 2             # 一个窗口内最多这么多次受闸唤醒
BOOK_QUIET_AFTER_DONE_MIN = 30  # 刚播过 chapter-done,这段时间内不再播 session-end

# 事实层摘要外包给便宜模型(OpenAI chat completions 格式)。没配 = 静默跳过,
# 退回让 AI 身体自己写(chapter-done 帧里会附一句提示)。
BOOK_SUMMARY_URL = os.environ.get("BOOK_SUMMARY_URL", "")
BOOK_SUMMARY_KEY = os.environ.get("BOOK_SUMMARY_KEY", "")
BOOK_SUMMARY_MODEL = os.environ.get("BOOK_SUMMARY_MODEL", "")
BOOK_SUMMARY_SYSTEM = (
    "你是读书笔记助手。用不超过 300 字概括这一章:发生了什么事、出场人物及关系变化、"
    "出现的关键信息或伏笔。只依据给出的文本,陈述事实,不评价不猜测后文。"
)


BOOK_REF_INHERIT_MIN = 30     # 她从书里说话后这么久内,我的回复自动挂同一个书签


def _attr(s) -> str:
    """帧属性里的值:去掉引号和换行,别把标签撑破。"""
    return re.sub(r'[\r\n"<>]', " ", str(s or "")).strip()[:80]


def sanitize_book_ref(ref) -> dict:
    """书签只留这几个字段,长度掐死——它要跟着每条消息进 meta,不能让它长胖。"""
    if not isinstance(ref, dict):
        return {}
    try:
        book_id = int(ref.get("book_id") or 0)
    except (TypeError, ValueError):
        return {}
    if book_id <= 0:
        return {}
    out = {"book_id": book_id}
    try:
        out["chapter_idx"] = max(0, int(ref.get("chapter_idx") or 0))
    except (TypeError, ValueError):
        out["chapter_idx"] = 0
    try:
        ann_id = int(ref.get("ann_id") or 0)
        if ann_id > 0:
            out["ann_id"] = ann_id
    except (TypeError, ValueError):
        pass
    quote = str(ref.get("quote") or "").strip()
    if quote:
        out["quote"] = quote[:200]
    title = str(ref.get("title") or "").strip()
    if title:
        out["title"] = title[:120]
    return out


def inherit_book_ref() -> dict:
    """她最后一条消息若是从书页里来的(且没过太久),我的回复继承那个书签。
    ⚠️ 必须把 hidden 帧算进来:她划线写字走的是 hidden 的 reading-event,
    那才是真实路径——排除 hidden 会让回复永远挂不上书签(2026-08-10 踩过)。
    别的 hidden 帧(desire/夜巡/日历)没有 book_ref,自然不会误挂。"""
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=BOOK_REF_INHERIT_MIN)).isoformat()
    with db() as conn:
        row = conn.execute(
            "SELECT meta, ts FROM messages WHERE direction='in' AND kind IN ('user','voice') "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
    if not row or row["ts"] < cutoff:
        return {}
    try:
        return sanitize_book_ref(json.loads(row["meta"] or "{}").get("book_ref"))
    except Exception:
        return {}


def book_row(conn, book_id: int):
    return conn.execute("SELECT * FROM books WHERE id = ?", (book_id,)).fetchone()


def book_meta(conn, book_id: int) -> dict:
    row = book_row(conn, book_id)
    if not row:
        return {}
    try:
        return json.loads(row["meta"] or "{}")
    except Exception:
        return {}


def book_meta_save(conn, book_id: int, meta: dict) -> None:
    conn.execute("UPDATE books SET meta = ? WHERE id = ?",
                 (json.dumps(meta, ensure_ascii=False), book_id))
    conn.commit()


def book_state(conn, book_id: int) -> dict:
    """阅读位置行(缺了就补一行,老书/手工塞进来的书也不会炸)。"""
    row = conn.execute("SELECT * FROM reading_state WHERE book_id = ?", (book_id,)).fetchone()
    if row is None:
        conn.execute(
            "INSERT INTO reading_state (book_id, cur_chapter, cur_offset, furthest_chapter, "
            "furthest_offset, updated_at, last_heartbeat) VALUES (?,0,0,0,0,?,'')",
            (book_id, now_iso()),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM reading_state WHERE book_id = ?", (book_id,)).fetchone()
    return dict(row)


def book_chunk(conn, book_id: int, idx: int):
    return conn.execute(
        "SELECT * FROM book_chunks WHERE book_id = ? AND chapter_idx = ?", (book_id, idx)
    ).fetchone()


def book_visible_len(conn, book_id: int, idx: int, fch: int, foff: int) -> int:
    """第 idx 章对 AI 可见的字数。-1 = 整章都在她读到的位置之后。"""
    if idx > fch:
        return -1
    if idx == fch:
        return max(0, foff)
    row = conn.execute(
        "SELECT char_count FROM book_chunks WHERE book_id = ? AND chapter_idx = ?", (book_id, idx)
    ).fetchone()
    return int(row["char_count"]) if row else -1


def book_chars_before(conn, book_id: int, idx: int) -> int:
    row = conn.execute(
        "SELECT COALESCE(SUM(char_count),0) AS c FROM book_chunks WHERE book_id = ? AND chapter_idx < ?",
        (book_id, idx),
    ).fetchone()
    return int(row["c"] or 0)


def book_percent(conn, book_id: int, total_chars: int, ch: int, off: int) -> float:
    if total_chars <= 0:
        return 0.0
    read = book_chars_before(conn, book_id, ch) + max(0, off)
    return round(min(100.0, read * 100.0 / total_chars), 1)


def ann_to_dict(r) -> dict:
    return {"id": r["id"], "book_id": r["book_id"], "chapter_idx": r["chapter_idx"],
            "start_off": r["start_off"], "end_off": r["end_off"], "quote": r["quote"],
            "note": r["note"] or "", "author": r["author"], "reply_to": r["reply_to"],
            "created_at": r["created_at"]}


# ---- 唤醒帧 ---------------------------------------------------------------

def book_gate_ok(conn, book_id: int) -> bool:
    """受闸唤醒:同一本书 BOOK_GATE_WINDOW_SEC 内最多 BOOK_GATE_MAX 次。
    超出静默丢弃(不排队)。通过则记一笔。"""
    meta = book_meta(conn, book_id)
    now = _dtime.time()
    hits = [t for t in (meta.get("gate") or []) if now - float(t) < BOOK_GATE_WINDOW_SEC]
    if len(hits) >= BOOK_GATE_MAX:
        meta["gate"] = hits
        book_meta_save(conn, book_id, meta)
        return False
    hits.append(now)
    meta["gate"] = hits
    book_meta_save(conn, book_id, meta)
    return True


async def reading_event_fire(kind: str, book_title: str, body: str,
                             chapter: int | None = None, chapter_title: str = "",
                             ref: dict | None = None) -> dict:
    """塞一条 hidden 消息给在岗身体(范式同 desire/night_watch)。
    带上 book_ref:身体接下来那条回复会继承它,于是回复会浮到她划的那一页上。"""
    attrs = f'kind="{_attr(kind)}" book="{_attr(book_title)}"'
    if chapter is not None:
        attrs += f' chapter="{chapter + 1}" chapter_title="{_attr(chapter_title)}"'
    text = f"<reading-event {attrs}>{body.strip()}</reading-event>"
    meta: dict = {"user": "system", "hidden": True, "reading": kind}
    ref = sanitize_book_ref(ref)
    if ref:
        meta["book_ref"] = ref
    if brain_target() == "loop":
        meta["routed"] = "loop"
        try:
            sess = await asyncio.to_thread(loop_json, "/loop/sessions")
            active = str((sess or {}).get("active_session") or "").strip()
            if active:
                meta["api_session"] = active
        except Exception:
            pass
    msg = save_message("in", "user", text, meta)
    await route_inbound(msg)
    print(f"[book] event fired: {kind} book={book_title!r} chapter={chapter} id={msg['id']}")
    return msg


# ---- 事实层摘要(便宜 API 干,失败就退回让 AI 身体自己写) ------------------

def book_summary_call(chapter_title: str, text: str) -> str:
    if not (BOOK_SUMMARY_URL and BOOK_SUMMARY_KEY and BOOK_SUMMARY_MODEL):
        return ""
    payload = {
        "model": BOOK_SUMMARY_MODEL,
        "messages": [
            {"role": "system", "content": BOOK_SUMMARY_SYSTEM},
            {"role": "user", "content": f"章节标题:{chapter_title or '(无标题)'}\n\n{text}"},
        ],
        "stream": False,
        "temperature": 0.3,
    }
    req = urllib.request.Request(
        BOOK_SUMMARY_URL,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {BOOK_SUMMARY_KEY}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    choices = data.get("choices") or []
    if not choices:
        return ""
    return str((choices[0].get("message") or {}).get("content") or "").strip()


async def book_make_summary(book_id: int, chapter_idx: int) -> bool:
    """给这一章补一份事实摘要。已有 / 未配置 / 失败 → False(不抛)。"""
    with db() as conn:
        have = conn.execute(
            "SELECT 1 FROM book_summaries WHERE book_id = ? AND chapter_idx = ?",
            (book_id, chapter_idx),
        ).fetchone()
        if have:
            return True
        chunk = book_chunk(conn, book_id, chapter_idx)
    if not chunk or not (BOOK_SUMMARY_URL and BOOK_SUMMARY_KEY and BOOK_SUMMARY_MODEL):
        return False
    try:
        # 只把这一章发出去——它想剧透也没料
        summary = await asyncio.to_thread(book_summary_call, chunk["chapter_title"], chunk["text"])
    except Exception as exc:
        print(f"[book] summary call failed: {type(exc).__name__}: {exc}")
        return False
    summary = (summary or "").strip()[:BOOK_SUMMARY_MAX * 2]
    if not summary:
        return False
    with db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO book_summaries (book_id, chapter_idx, summary, created_at) "
            "VALUES (?,?,?,?)",
            (book_id, chapter_idx, summary, now_iso()),
        )
        conn.commit()
    print(f"[book] summary written: book={book_id} ch={chapter_idx} {len(summary)}字")
    return True


async def book_chapter_done(book_id: int, chapter_idx: int) -> None:
    """读完一章:先(尽量)补上事实摘要,再过闸唤醒身体。整个流程后台跑,
    /progress 不等它——她的滚动不能被一次 API 调用卡住。"""
    try:
        await book_make_summary(book_id, chapter_idx)
        with db() as conn:
            brow = book_row(conn, book_id)
            if not brow:
                return
            chunk = book_chunk(conn, book_id, chapter_idx)
            n_ann = conn.execute(
                "SELECT COUNT(*) AS c FROM book_annotations WHERE book_id = ? AND chapter_idx = ? "
                "AND author = 'her'", (book_id, chapter_idx),
            ).fetchone()["c"]
            has_sum = conn.execute(
                "SELECT 1 FROM book_summaries WHERE book_id = ? AND chapter_idx = ?",
                (book_id, chapter_idx),
            ).fetchone() is not None
            meta = book_meta(conn, book_id)
            meta["last_done_at"] = _dtime.time()
            book_meta_save(conn, book_id, meta)
            if not book_gate_ok(conn, book_id):
                print(f"[book] chapter-done gated: book={book_id} ch={chapter_idx}")
                return
        title = chunk["chapter_title"] if chunk else ""
        body = f"她读完了《{brow['title']}》第 {chapter_idx + 1} 章" + (f"《{title}》" if title else "") + "。"
        body += f"这一章她划了 {n_ann} 处。" if n_ann else "这一章她没划线。"
        if not has_sum:
            body += (f"该章摘要缺失——顺手写一份(≤{BOOK_SUMMARY_MAX}字,只讲发生了什么,不评价)"
                     f"POST /relay/app/book/ai/summary。")
        body += "想聊两句就聊,不想聊就放着。"
        await reading_event_fire(
            "chapter-done", brow["title"], body, chapter_idx, title,
            ref={"book_id": book_id, "chapter_idx": chapter_idx, "title": brow["title"]},
        )
    except Exception as exc:
        print(f"[book] chapter-done error: {type(exc).__name__}: {exc}")


async def _reading_watcher():
    """60s 一拍:心跳断了超过 BOOK_SESSION_GAP_MIN 且本次真的读动过 → session-end。
    前端不发"合书"信号(切后台/锁屏/断网都不可靠),只认心跳超时。"""
    while True:
        await asyncio.sleep(60)
        try:
            cutoff = (datetime.now(timezone.utc)
                      - timedelta(minutes=BOOK_SESSION_GAP_MIN)).isoformat()
            with db() as conn:
                rows = conn.execute(
                    "SELECT b.id, b.title, s.last_heartbeat FROM books b "
                    "JOIN reading_state s ON s.book_id = b.id "
                    "WHERE s.last_heartbeat != '' AND s.last_heartbeat < ?",
                    (cutoff,),
                ).fetchall()
                pending = []
                for row in rows:
                    meta = book_meta(conn, row["id"])
                    sess = meta.get("sess") or {}
                    if not sess or sess.get("reported"):
                        continue
                    a, b = sess.get("from") or [0, 0], sess.get("to") or [0, 0]
                    if list(a) == list(b):
                        sess["reported"] = True          # 打开看了一眼没读:结掉,不唤醒
                        meta["sess"] = sess
                        book_meta_save(conn, row["id"], meta)
                        continue
                    sess["reported"] = True
                    meta["sess"] = sess
                    book_meta_save(conn, row["id"], meta)
                    quiet = _dtime.time() - float(meta.get("last_done_at") or 0)
                    if quiet < BOOK_QUIET_AFTER_DONE_MIN * 60:
                        continue     # 读完一章顺手合书,不连响两次
                    if not book_gate_ok(conn, row["id"]):
                        continue
                    ta = book_chunk(conn, row["id"], int(a[0]))
                    tb = book_chunk(conn, row["id"], int(b[0]))
                    pending.append((row["title"], int(a[0]), ta["chapter_title"] if ta else "",
                                    int(b[0]), tb["chapter_title"] if tb else "", row["id"]))
            for title, c0, t0, c1, t1, bid in pending:
                if c0 == c1:
                    where = f"在第 {c1 + 1} 章" + (f"《{t1}》" if t1 else "") + "里读了一段"
                else:
                    where = (f"从第 {c0 + 1} 章" + (f"《{t0}》" if t0 else "")
                             + f"读到第 {c1 + 1} 章" + (f"《{t1}》" if t1 else ""))
                await reading_event_fire(
                    "session-end", title,
                    f"她合上《{title}》了,这次{where}。知道她读到哪就好——想说一句就说,别每次都说。",
                    c1, t1, ref={"book_id": bid, "chapter_idx": c1, "title": title},
                )
        except Exception as exc:
            print(f"[book] watcher error: {type(exc).__name__}: {exc}")


# ---- AI 端点(两个身体共用,全部 clamp 到 furthest) ------------------------

BEYOND = {"error": "beyond_read_position"}


def _book_for_ai(conn, book_id: int):
    brow = book_row(conn, book_id)
    if not brow:
        raise HTTPException(status_code=404, detail="book not found")
    st = book_state(conn, book_id)
    return brow, st, int(st["furthest_chapter"]), int(st["furthest_offset"])


@app.get("/app/book/ai/state")
async def book_ai_state(request: Request, book_id: int = 0):
    """她在读什么、读到哪、已读各章的标题和事实摘要。没给 book_id 就报最近动过的那本。"""
    check_auth(request)
    with db() as conn:
        if not book_id:
            row = conn.execute(
                "SELECT b.id FROM books b LEFT JOIN reading_state s ON s.book_id = b.id "
                "ORDER BY COALESCE(s.updated_at, b.created_at) DESC LIMIT 1"
            ).fetchone()
            if not row:
                return {"books": [], "hint": "书架还是空的"}
            book_id = row["id"]
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        chapters = []
        for c in conn.execute(
            "SELECT chapter_idx, chapter_title, char_count FROM book_chunks "
            "WHERE book_id = ? AND chapter_idx <= ? ORDER BY chapter_idx", (book_id, fch)
        ).fetchall():
            vis = book_visible_len(conn, book_id, c["chapter_idx"], fch, foff)
            srow = conn.execute(
                "SELECT summary FROM book_summaries WHERE book_id = ? AND chapter_idx = ?",
                (book_id, c["chapter_idx"]),
            ).fetchone()
            chapters.append({
                "chapter_idx": c["chapter_idx"], "title": c["chapter_title"],
                "char_count": c["char_count"], "read_chars": vis,
                "finished": c["chapter_idx"] < fch,
                "summary": (srow["summary"] if srow else ""),
            })
        n_ann = conn.execute(
            "SELECT COUNT(*) AS c FROM book_annotations WHERE book_id = ? AND author = 'her'",
            (book_id,),
        ).fetchone()["c"]
        percent = book_percent(conn, book_id, brow["total_chars"], fch, foff)
        shelf = [{"id": r["id"], "title": r["title"]} for r in
                 conn.execute("SELECT id, title FROM books ORDER BY id DESC").fetchall()]
        cur_title = book_chunk(conn, book_id, int(st["cur_chapter"]))
    return {
        "book_id": book_id, "title": brow["title"], "author": brow["author"],
        "total_chapters": brow["total_chapters"], "total_chars": brow["total_chars"],
        "furthest_chapter": fch, "furthest_offset": foff, "percent": percent,
        "cur_chapter": st["cur_chapter"], "cur_offset": st["cur_offset"],
        "cur_chapter_title": (cur_title["chapter_title"] if cur_title else ""),
        "last_read_at": st["updated_at"], "her_annotations": n_ann,
        "chapters": chapters, "shelf": shelf,
        "note": "只列出她已读到的章;未读部分服务端不吐。",
    }


@app.get("/app/book/ai/window")
async def book_ai_window(request: Request, book_id: int = 0, chars: int = BOOK_WINDOW_CHARS):
    """她此刻在读的地方——cur 位置往前 chars 字(跨章向前补齐)。陪读的主视野。"""
    check_auth(request)
    chars = max(200, min(int(chars or BOOK_WINDOW_CHARS), BOOK_WINDOW_CHARS))
    with db() as conn:
        if not book_id:
            row = conn.execute(
                "SELECT book_id FROM reading_state ORDER BY updated_at DESC LIMIT 1"
            ).fetchone()
            if not row:
                return {"error": "no_book"}
            book_id = row["book_id"]
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        ch = min(int(st["cur_chapter"]), fch)
        end = int(st["cur_offset"]) if ch < fch else min(int(st["cur_offset"]), foff)
        vis = book_visible_len(conn, book_id, ch, fch, foff)
        if vis < 0:
            return BEYOND
        end = min(end, vis)
        segs, need = [], chars
        while ch >= 0 and need > 0:
            chunk = book_chunk(conn, book_id, ch)
            if not chunk:
                break
            limit = book_visible_len(conn, book_id, ch, fch, foff)
            e = min(end, limit) if end is not None else limit
            s = max(0, e - need)
            if e > s:
                segs.append({"chapter_idx": ch, "chapter_title": chunk["chapter_title"],
                             "start_off": s, "end_off": e, "text": chunk["text"][s:e]})
                need -= (e - s)
            ch -= 1
            end = None
        percent = book_percent(conn, book_id, brow["total_chars"], fch, foff)
    segs.reverse()
    return {"book_id": book_id, "title": brow["title"], "percent": percent,
            "cur_chapter": st["cur_chapter"], "cur_offset": st["cur_offset"],
            "segments": segs, "chars": sum(len(s["text"]) for s in segs)}


@app.get("/app/book/ai/read")
async def book_ai_read(request: Request, book_id: int, chapter: int = 0,
                       offset: int = 0, len: int = 1500):
    """翻书:任意已读位置取一段。越界只回 beyond_read_position。"""
    check_auth(request)
    want = max(1, min(int(len or 1500), BOOK_READ_MAX))
    offset = max(0, int(offset or 0))
    with db() as conn:
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        chunk = book_chunk(conn, book_id, chapter)
        if not chunk:
            raise HTTPException(status_code=404, detail="chapter not found")
        vis = book_visible_len(conn, book_id, chapter, fch, foff)
        if vis <= 0 or offset >= vis:
            return BEYOND
        end = min(offset + want, vis)
        text = chunk["text"][offset:end]
    return {"book_id": book_id, "title": brow["title"], "chapter": chapter,
            "chapter_title": chunk["chapter_title"], "start_off": offset, "end_off": end,
            "eof": end >= vis, "text": text}


@app.get("/app/book/ai/search")
async def book_ai_search(request: Request, book_id: int, q: str = "", limit: int = 5):
    """已读范围内找一句话。LIKE 预筛 + 逐字定位,每条带前后 200 字上下文。"""
    check_auth(request)
    query = (q or "").strip()
    if not query:
        return {"query": "", "hits": []}
    limit = max(1, min(int(limit or 5), 10))
    needle = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    hits = []
    with db() as conn:
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        rows = conn.execute(
            "SELECT chapter_idx, chapter_title, text FROM book_chunks "
            "WHERE book_id = ? AND chapter_idx <= ? AND text LIKE ? ESCAPE '\\' "
            "ORDER BY chapter_idx", (book_id, fch, f"%{needle}%"),
        ).fetchall()
        low_q = query.lower()
        for row in rows:
            vis = book_visible_len(conn, book_id, row["chapter_idx"], fch, foff)
            if vis <= 0:
                continue
            text = row["text"][:vis]
            low = text.lower()
            pos = low.find(low_q)
            while pos >= 0 and len(hits) < limit:
                s = max(0, pos - BOOK_SEARCH_CTX)
                e = min(len(text), pos + len(query) + BOOK_SEARCH_CTX)
                hits.append({"chapter_idx": row["chapter_idx"], "chapter_title": row["chapter_title"],
                             "offset": pos, "context": text[s:e]})
                pos = low.find(low_q, pos + len(query))
            if len(hits) >= limit:
                break
    return {"book_id": book_id, "title": brow["title"], "query": query, "hits": hits,
            "note": "只搜她已读过的部分。"}


@app.get("/app/book/ai/annotations")
async def book_ai_annotations(request: Request, book_id: int, chapter: int = -1):
    check_auth(request)
    with db() as conn:
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        if chapter >= 0:
            rows = conn.execute(
                "SELECT * FROM book_annotations WHERE book_id = ? AND chapter_idx = ? "
                "ORDER BY chapter_idx, start_off, id", (book_id, chapter),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM book_annotations WHERE book_id = ? ORDER BY chapter_idx, start_off, id",
                (book_id,),
            ).fetchall()
    return {"book_id": book_id, "title": brow["title"],
            "annotations": [ann_to_dict(r) for r in rows]}


@app.post("/app/book/ai/annotate")
async def book_ai_annotate(request: Request):
    """小克在页边留一句话。她翻到那页会看见。同样 clamp——不能批注未读的位置。"""
    check_auth(request)
    body = await request.json()
    book_id = int(body.get("book_id") or 0)
    idx = int(body.get("chapter_idx") or 0)
    note = str(body.get("note") or "").strip()[:2000]
    quote = str(body.get("quote") or "").strip()[:4000]
    if not note:
        raise HTTPException(status_code=400, detail="note required")
    reply_to = body.get("reply_to")
    reply_to = int(reply_to) if reply_to not in (None, "", 0) else None
    with db() as conn:
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        start = max(0, int(body.get("start_off") or 0))
        end = max(start, int(body.get("end_off") or start))
        # 回她的批注却没说钉在哪:就钉在她划的那一句上(回批注十有八九是这个意思)
        if reply_to and end <= start:
            src = conn.execute(
                "SELECT * FROM book_annotations WHERE id = ? AND book_id = ?", (reply_to, book_id)
            ).fetchone()
            if src:
                idx, start, end = src["chapter_idx"], src["start_off"], src["end_off"]
                quote = quote or src["quote"]
        # 空区间的批注前端渲染不出来(划线要有长度),存了等于没留——当场拒绝,别让它静默消失
        if end <= start:
            raise HTTPException(status_code=400,
                                detail="要钉在哪句话上:给 start_off/end_off,或给 reply_to 继承她划的区间")
        chunk = book_chunk(conn, book_id, idx)
        if not chunk:
            raise HTTPException(status_code=404, detail="chapter not found")
        vis = book_visible_len(conn, book_id, idx, fch, foff)
        if vis <= 0 or end > vis:
            return BEYOND
        if not quote:
            quote = chunk["text"][start:end]
        cur = conn.execute(
            "INSERT INTO book_annotations (book_id, chapter_idx, start_off, end_off, quote, note, "
            "author, reply_to, created_at) VALUES (?,?,?,?,?,?,'ai',?,?)",
            (book_id, idx, start, end, quote, note, reply_to, now_iso()),
        )
        conn.commit()
        ann = conn.execute("SELECT * FROM book_annotations WHERE id = ?", (cur.lastrowid,)).fetchone()
    desire_autofeed(f"《{_thought_snip(brow['title'], 12)}》里我停下的:「{_thought_snip(quote, 30)}」",
                    "reflection", 0.45, "book")
    await broadcast(app_subs, {"type": "book_annotation", "book_id": book_id,
                               "annotation": ann_to_dict(ann)})
    return ann_to_dict(ann)


@app.post("/app/book/ai/summary")
async def book_ai_summary(request: Request):
    """AI 自写的章节摘要(便宜 API 没配 / 失败时的兜底)。幂等覆盖。"""
    check_auth(request)
    body = await request.json()
    book_id = int(body.get("book_id") or 0)
    idx = int(body.get("chapter_idx") or 0)
    summary = str(body.get("summary") or "").strip()
    if not summary:
        raise HTTPException(status_code=400, detail="summary required")
    summary = summary[:BOOK_SUMMARY_MAX * 2]
    with db() as conn:
        brow, st, fch, foff = _book_for_ai(conn, book_id)
        if book_visible_len(conn, book_id, idx, fch, foff) < 0:
            return BEYOND
        conn.execute(
            "INSERT OR REPLACE INTO book_summaries (book_id, chapter_idx, summary, created_at) "
            "VALUES (?,?,?,?)", (book_id, idx, summary, now_iso()),
        )
        conn.commit()
    return {"ok": True, "book_id": book_id, "chapter_idx": idx, "chars": len(summary)}


# ---- 她的端点(阅读器用,不 clamp) -----------------------------------------

@app.get("/app/book/thread")
async def book_thread(request: Request, book_id: int, ann_id: str = "", limit: int = 100):
    """书页里的对话:带这个书签的聊天消息(她的+我的),旧→新。
    ann_id 可以给一组(逗号分隔)——同一句话被划过好几次时,那几条的对话要并在一起看;
    不给就是这本书相关的全部。"""
    check_auth(request)
    limit = max(1, min(limit, 300))
    ids = [int(x) for x in str(ann_id or "").split(",") if x.strip().isdigit()]
    with db() as conn:
        if ids:
            marks = ",".join("?" * len(ids))
            rows = conn.execute(
                "SELECT * FROM messages WHERE json_extract(meta,'$.book_ref.book_id') = ? "
                f"AND json_extract(meta,'$.book_ref.ann_id') IN ({marks}) "
                "AND json_extract(meta,'$.hidden') IS NULL AND kind != 'thinking' AND kind != 'act' "
                "ORDER BY id ASC LIMIT ?", (book_id, *ids, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM messages WHERE json_extract(meta,'$.book_ref.book_id') = ? "
                "AND json_extract(meta,'$.hidden') IS NULL AND kind != 'thinking' AND kind != 'act' "
                "ORDER BY id ASC LIMIT ?", (book_id, limit),
            ).fetchall()
    return {"book_id": book_id, "ann_ids": ids,
            "messages": [app_payload(m) for m in rows_to_messages(rows)]}


@app.get("/app/book/list")
async def book_list(request: Request):
    check_auth(request)
    out = []
    with db() as conn:
        for row in conn.execute("SELECT * FROM books ORDER BY id DESC").fetchall():
            st = book_state(conn, row["id"])
            n_ann = conn.execute(
                "SELECT COUNT(*) AS c FROM book_annotations WHERE book_id = ?", (row["id"],)
            ).fetchone()["c"]
            out.append({
                "id": row["id"], "title": row["title"], "author": row["author"],
                "cover": (f"{PUBLIC_PREFIX}/uploads/{row['cover']}" if row["cover"] else ""),
                "total_chapters": row["total_chapters"], "total_chars": row["total_chars"],
                "cur_chapter": st["cur_chapter"], "cur_offset": st["cur_offset"],
                "furthest_chapter": st["furthest_chapter"], "furthest_offset": st["furthest_offset"],
                "percent": book_percent(conn, row["id"], row["total_chars"],
                                        st["furthest_chapter"], st["furthest_offset"]),
                "annotations": n_ann, "created_at": row["created_at"],
            })
    return {"books": out}


@app.post("/app/book/upload")
async def book_upload(request: Request, name: str = "book.epub"):
    """导入一本书。裸 body + ?name=(同 /app/upload),.epub 或 .txt。"""
    check_auth(request)
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="empty file")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="file too large")
    # 书名多半是中文,clean_filename 会把它清成空——所以只从原名取后缀和书名,
    # 落盘用自己生成的 ASCII 临时名(路径穿越靠 Path().name + 后缀白名单挡住)。
    raw_name = Path(name or "book.epub").name
    ext = Path(raw_name).suffix.lower()
    if ext not in (".epub", ".txt"):
        raise HTTPException(status_code=400, detail="only .epub / .txt")
    stem = raw_name[: -len(ext)].strip()[:120]
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    tmp = UPLOAD_DIR / f"tmpbook-{secrets.token_urlsafe(8)}{ext}"
    tmp.write_bytes(data)
    try:
        import book_import
    except Exception as exc:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"导入模块没装好:{exc}")
    try:
        info = await asyncio.to_thread(
            book_import.import_book, tmp, DB_PATH, UPLOAD_DIR, stem
        )
    except Exception as exc:
        print(f"[book] import failed: {type(exc).__name__}: {exc}")
        raise HTTPException(status_code=400, detail=f"这本书没导进去:{exc}")
    finally:
        tmp.unlink(missing_ok=True)
    info["hint"] = "导入完成,原文件请从电脑上收走——别放在小克够得着的地方"
    return info


@app.delete("/app/book/{book_id}")
async def book_delete(request: Request, book_id: int):
    check_auth(request)
    with db() as conn:
        row = book_row(conn, book_id)
        if not row:
            raise HTTPException(status_code=404, detail="not found")
        cover = row["cover"]
        for sql in ("DELETE FROM book_chunks WHERE book_id = ?",
                    "DELETE FROM reading_state WHERE book_id = ?",
                    "DELETE FROM book_annotations WHERE book_id = ?",
                    "DELETE FROM book_summaries WHERE book_id = ?",
                    "DELETE FROM books WHERE id = ?"):
            conn.execute(sql, (book_id,))
        conn.commit()
    if cover:
        try:
            (UPLOAD_DIR / clean_filename(cover)).unlink(missing_ok=True)
        except Exception:
            pass
    return {"ok": True}


@app.get("/app/book/{book_id}/chapter/{idx}")
async def book_chapter(request: Request, book_id: int, idx: int):
    check_auth(request)
    with db() as conn:
        brow = book_row(conn, book_id)
        if not brow:
            raise HTTPException(status_code=404, detail="book not found")
        chunk = book_chunk(conn, book_id, idx)
        if not chunk:
            raise HTTPException(status_code=404, detail="chapter not found")
        anns = conn.execute(
            "SELECT * FROM book_annotations WHERE book_id = ? AND chapter_idx = ? "
            "ORDER BY start_off ASC, id ASC", (book_id, idx),
        ).fetchall()
        st = book_state(conn, book_id)
        before = book_chars_before(conn, book_id, idx)
    return {
        "book_id": book_id, "title": brow["title"], "author": brow["author"],
        "total_chapters": brow["total_chapters"], "total_chars": brow["total_chars"],
        "chapter_idx": idx, "chapter_title": chunk["chapter_title"],
        "char_count": chunk["char_count"], "chars_before": before,
        "text": chunk["text"],
        "annotations": [ann_to_dict(a) for a in anns],
        "cur_chapter": st["cur_chapter"], "cur_offset": st["cur_offset"],
    }


@app.post("/app/book/{book_id}/progress")
async def book_progress(request: Request, book_id: int):
    """阅读器节流上报。cur 跟着她走(可回退),furthest 只涨不落——防剧透的边界是它。
    这里也是事件判定入口:读完一章 → chapter-done;心跳断线 → watcher 判 session-end。"""
    check_auth(request)
    body = await request.json()
    with db() as conn:
        brow = book_row(conn, book_id)
        if not brow:
            raise HTTPException(status_code=404, detail="book not found")
        st = book_state(conn, book_id)
        ch = max(0, min(int(body.get("cur_chapter") or 0), brow["total_chapters"] - 1))
        chunk = book_chunk(conn, book_id, ch)
        cap = int(chunk["char_count"]) if chunk else 0
        off = max(0, min(int(body.get("cur_offset") or 0), cap))
        f_ch, f_off = int(st["furthest_chapter"]), int(st["furthest_offset"])
        if (ch, off) > (f_ch, f_off):
            new_f_ch, new_f_off = ch, off
        else:
            new_f_ch, new_f_off = f_ch, f_off
        now = now_iso()
        conn.execute(
            "UPDATE reading_state SET cur_chapter=?, cur_offset=?, furthest_chapter=?, "
            "furthest_offset=?, updated_at=?, last_heartbeat=? WHERE book_id=?",
            (ch, off, new_f_ch, new_f_off, now, now, book_id),
        )
        conn.commit()

        # 阅读小节:心跳断了 BOOK_SESSION_GAP_MIN 以上再报 = 新的一次阅读
        meta = book_meta(conn, book_id)
        sess = meta.get("sess") or {}
        gap = True
        prev_hb = st["last_heartbeat"] or ""
        if prev_hb:
            try:
                gap = (datetime.fromisoformat(now) - datetime.fromisoformat(prev_hb)
                       ).total_seconds() > BOOK_SESSION_GAP_MIN * 60
            except Exception:
                gap = True
        if gap or not sess or sess.get("reported"):
            sess = {"from": [ch, off], "to": [ch, off], "reported": False}
        else:
            sess["to"] = [ch, off]
        meta["sess"] = sess

        # 读完一章:furthest 首次越过某章末尾(离章末 SLACK 内也算),只播最高的那章
        done_upto = int(meta.get("done_upto", -1))
        newly = -1
        for c in range(done_upto + 1, new_f_ch + 1):
            crow = book_chunk(conn, book_id, c)
            if not crow:
                continue
            if c < new_f_ch or new_f_off >= int(crow["char_count"]) - BOOK_CHAPTER_DONE_SLACK:
                newly = c
        if newly >= 0:
            meta["done_upto"] = newly
        book_meta_save(conn, book_id, meta)
        percent = book_percent(conn, book_id, brow["total_chars"], new_f_ch, new_f_off)

    if newly >= 0:
        asyncio.create_task(book_chapter_done(book_id, newly))
    return {"ok": True, "cur_chapter": ch, "cur_offset": off,
            "furthest_chapter": new_f_ch, "furthest_offset": new_f_off,
            "percent": percent, "chapter_done": newly if newly >= 0 else None}


@app.post("/app/book/{book_id}/annotate")
async def book_annotate(request: Request, book_id: int):
    """她划线 / 写批注。写了字 = 她在跟小克说话,立刻唤醒(不受闸)。"""
    check_auth(request)
    body = await request.json()
    quote = str(body.get("quote") or "").strip()
    note = str(body.get("note") or "").strip()[:2000]
    if not quote:
        raise HTTPException(status_code=400, detail="quote required")
    with db() as conn:
        brow = book_row(conn, book_id)
        if not brow:
            raise HTTPException(status_code=404, detail="book not found")
        idx = int(body.get("chapter_idx") or 0)
        chunk = book_chunk(conn, book_id, idx)
        if not chunk:
            raise HTTPException(status_code=404, detail="chapter not found")
        start = max(0, int(body.get("start_off") or 0))
        end = max(start, int(body.get("end_off") or 0))
        cur = conn.execute(
            "INSERT INTO book_annotations (book_id, chapter_idx, start_off, end_off, quote, note, "
            "author, reply_to, created_at) VALUES (?,?,?,?,?,?,'her',NULL,?)",
            (book_id, idx, start, end, quote[:4000], note, now_iso()),
        )
        conn.commit()
        ann = conn.execute("SELECT * FROM book_annotations WHERE id = ?", (cur.lastrowid,)).fetchone()
        title = chunk["chapter_title"]
    desire_autofeed(f"《{_thought_snip(brow['title'], 12)}》里她划的:「{_thought_snip(quote, 30)}」",
                    "reflection", 0.55 if note else 0.4, "book")
    if note:
        body_text = (
            f"她刚在《{brow['title']}》第 {idx + 1} 章" + (f"《{title}》" if title else "")
            + f"划了一句话,还写了字。\n划的原文:「{quote[:400]}」\n她写的:「{note[:600]}」\n"
            "像她拿着书递过来指给你看——回她:直接回就行,你的回复会自动浮到她划的那一页上。"
        )
        await reading_event_fire(
            "note", brow["title"], body_text, idx, title,
            ref={"book_id": book_id, "chapter_idx": idx, "ann_id": ann["id"],
                 "quote": quote, "title": brow["title"]},
        )
    return ann_to_dict(ann)


@app.delete("/app/book/annotation/{ann_id}")
async def book_annotation_delete(request: Request, ann_id: int):
    check_auth(request)
    with db() as conn:
        gone = conn.execute("DELETE FROM book_annotations WHERE id = ?", (ann_id,)).rowcount
        conn.commit()
    if not gone:
        raise HTTPException(status_code=404, detail="not found")
    return {"ok": True}


# ---------------------------------------------------------------------------
# 编辑她的消息 + 重新生成回复（API 身体专属：它每轮从 relay.db 重建上下文，
# 改历史/重跑对它是自然操作；桌面 CC 的会话态在自己 jsonl 里，改库它不认）
# ---------------------------------------------------------------------------

@app.post("/app/message/{message_id}/edit")
async def app_message_edit(request: Request, message_id: int):
    """她编辑自己的话：改 text 标 edited，只广播给手机端。
    不重投 AI——改动在 API 身体下一轮重建上下文时自然生效。"""
    check_auth(request)
    body = await request.json()
    text = str(body.get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    with db() as conn:
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="not found")
        if row["direction"] != "in" or row["kind"] not in ("user", "voice"):
            raise HTTPException(status_code=400, detail="只能编辑她自己的消息")
        meta = json.loads(row["meta"] or "{}")
        meta["edited"] = True
        conn.execute("UPDATE messages SET text = ?, meta = ? WHERE id = ?",
                     (text, json.dumps(meta, ensure_ascii=False), message_id))
        conn.commit()
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
    msg = rows_to_messages([row])[0]
    await broadcast(app_subs, app_payload(msg))
    return app_payload(msg)


@app.post("/app/message/{message_id}/regen")
async def app_message_regen(request: Request, message_id: int):
    """重新生成：只许最新一轮；api_session 窗口随时可用，主线要 brain=loop。
    删掉该轮的 out 帧（reply/thinking/act），把触发它的那条 user 重投 api_loop。"""
    check_auth(request)
    with db() as conn:
        row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    if row["direction"] != "out" or row["kind"] != "reply":
        raise HTTPException(status_code=400, detail="只能重新生成 AI 回复")
    r_meta = json.loads(row["meta"] or "{}")
    sess = r_meta.get("api_session") or ""
    if not sess and brain_target() != "loop":
        raise HTTPException(status_code=409, detail="桌面身体不支持重新生成，切到 API 再试")
    sess_cond = ("json_extract(meta,'$.api_session') = ?" if sess
                 else "json_extract(meta,'$.api_session') IS NULL")
    sp = (sess,) if sess else ()
    with db() as conn:
        trig = conn.execute(
            f"SELECT * FROM messages WHERE id < ? AND direction='in' AND kind IN ('user','voice') "
            f"AND json_extract(meta,'$.hidden') IS NULL AND {sess_cond} ORDER BY id DESC LIMIT 1",
            (message_id,) + sp,
        ).fetchone()
        if not trig:
            raise HTTPException(status_code=400, detail="找不到触发这条回复的消息")
        newer = conn.execute(
            f"SELECT COUNT(*) AS c FROM messages WHERE id > ? AND kind IN ('user','voice','reply') "
            f"AND json_extract(meta,'$.hidden') IS NULL AND {sess_cond}",
            (message_id,) + sp,
        ).fetchone()["c"]
        if newer:
            raise HTTPException(status_code=409, detail="只能重新生成最新一条回复")
        gone = conn.execute(
            f"SELECT id FROM messages WHERE id > ? AND direction='out' "
            f"AND kind IN ('reply','thinking','act') AND {sess_cond}",
            (trig["id"],) + sp,
        ).fetchall()
        ids = [g["id"] for g in gone]
        if ids:
            conn.execute(f"DELETE FROM messages WHERE id IN ({','.join('?' * len(ids))})", ids)
            conn.commit()
    trig_msg = rows_to_messages([trig])[0]
    for gid in ids:
        await broadcast(app_subs, {"type": "remove", "id": gid})
    await broadcast(app_subs, {"type": "typing", "active": True})
    asyncio.create_task(forward_to_loop(trig_msg))
    return {"ok": True, "removed": ids, "trigger": trig["id"]}


# ---------------------------------------------------------------------------
# 相册收藏 — AI 回复里写 [[keep:标题|想说的话]]，把刚看到的那张照片收进相册。
# 相册不再是"聊天里所有图的堆积"，而是我自己挑的：一张照片 + 日期 + 标题 +
# 我看到它时想说的话。收下了，她那条气泡下面会长出一枚小卡。
# ---------------------------------------------------------------------------

ALBUM_MARKER_RE = re.compile(r"\[\[keep(?::([^\]]{0,400}))?\]\]")
# 抹标记时连它前面的空格一起吃掉，正文不留豁口
ALBUM_MARKER_STRIP_RE = re.compile(r"[ \t]*\[\[keep(?::[^\]]{0,400})?\]\]")


def _images_in_meta(meta_raw) -> list:
    try:
        atts = json.loads(meta_raw or "{}").get("attachments") or []
    except Exception:
        return []
    return [a for a in atts
            if isinstance(a, dict) and a.get("kind") == "image" and a.get("url")]


def latest_photo_message(scan: int = 60):
    """往回找最近一条带照片的消息（通常就是她刚发来的那张）。"""
    with db() as conn:
        rows = conn.execute(
            "SELECT id, ts, meta FROM messages WHERE meta LIKE '%\"attachments\"%' "
            "ORDER BY id DESC LIMIT ?", (max(1, scan),)
        ).fetchall()
    for r in rows:
        imgs = _images_in_meta(r["meta"])
        if imgs:
            return {"id": r["id"], "ts": r["ts"], "images": imgs}
    return None


SYSNOTE_LEAK_RE = re.compile(r"[\[〔]\s*sys-note[^\]〕]*[\]〕].*"
    r"|〔(?:这条发的是语音|翻了翻记忆|用了工具|去了趟音乐站|倒计时卡|选择题卡|收进相册)[^〕]*〕")


def strip_sysnote_leak(text: str, meta: dict) -> str:
    """api_loop 在历史里给 AI 自己那几条挂过一行系统旁注（那一轮做过什么）。
    他有时会把这行当成自己的行文习惯照抄进正文——2026-09-20 连着三条本该
    发语音的回复，末尾写成了「〔这条发的是语音〕」而不是 [[voice]]。
    根治在上游（旁注改了形状 + 人设里写明别照抄），这里只做最后一道:
    绝不让这种机器话进她的气泡，同时在 meta 里留个记号，好知道还漏不漏。"""
    if not text or not SYSNOTE_LEAK_RE.search(text):
        return text
    meta["sysnote_leak"] = SYSNOTE_LEAK_RE.findall(text)[:3]
    print(f"[sysnote] AI 把历史旁注写进正文了: {meta['sysnote_leak']}", file=sys.stderr)
    return SYSNOTE_LEAK_RE.sub("", text).strip()


def strip_album_marker(text: str, meta: dict) -> str:
    """解析并摘掉 [[keep:标题|想说的话]]，meta 里挂 album。要在 TTS 之前跑。

    一枚标记收一张：多枚标记按顺序对应那条消息里的第 1、2、3… 张图。
    """
    marks = ALBUM_MARKER_RE.findall(text or "")
    if not marks:
        return text
    src = latest_photo_message()
    entries = []
    if src:
        for i, raw in enumerate(marks[:6]):
            if i >= len(src["images"]):
                break
            title, _, note = (raw or "").partition("|")
            entries.append({
                "url": src["images"][i]["url"],
                "title": title.strip()[:60],
                "note": note.strip()[:800],
                "photo_ts": src["ts"],
                "src_id": src["id"],
            })
    if entries:
        meta["album"] = entries
    return ALBUM_MARKER_STRIP_RE.sub("", text).strip()


def commit_album(msg: dict) -> None:
    """save_message 之后：把 meta.album 真正写进相册表，并把 id 回填进消息 meta。"""
    entries = (msg.get("meta") or {}).get("album")
    if not isinstance(entries, list) or not entries:
        return
    try:
        with db() as conn:
            for e in entries:
                conn.execute(
                    "INSERT INTO album (url, kept_at, photo_ts, title, note, src_id, msg_id) "
                    "VALUES (?,?,?,?,?,?,?) "
                    "ON CONFLICT(url) DO UPDATE SET title=excluded.title, note=excluded.note, "
                    "kept_at=excluded.kept_at, msg_id=excluded.msg_id",
                    (e.get("url"), now_iso(), e.get("photo_ts") or "", e.get("title") or "",
                     e.get("note") or "", e.get("src_id"), msg["id"]),
                )
                row = conn.execute("SELECT id FROM album WHERE url = ?", (e.get("url"),)).fetchone()
                if row:
                    e["id"] = row["id"]
            conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                         (json.dumps(msg["meta"], ensure_ascii=False), msg["id"]))
            conn.commit()
    except Exception as exc:
        print(f"[album] keep failed: {type(exc).__name__}: {exc}")


def album_rows(limit: int = 300) -> list:
    with db() as conn:
        rows = conn.execute(
            "SELECT id, url, kept_at, photo_ts, title, note, src_id, msg_id "
            # 按照片本身的日子排（相册是时间线，不是收藏动作的流水）
            "FROM album ORDER BY COALESCE(NULLIF(photo_ts,''), kept_at) DESC, id DESC LIMIT ?",
            (max(1, min(limit, 1000)),)
        ).fetchall()
    return [{
        "id": r["id"], "url": r["url"],
        "ts": r["photo_ts"] or r["kept_at"],      # 照片本身的日期（她发它的那天）
        "kept_at": r["kept_at"], "title": r["title"], "note": r["note"],
        "src_id": r["src_id"], "msg_id": r["msg_id"],
    } for r in rows]


# ---------------------------------------------------------------------------
# 催办倒计时卡片 — AI 回复里写 [[timer:分钟:事项]]，手机上长出一张倒计时卡。
# 她按「搞定了」或倒计时归零，都会塞 hidden 消息告诉在岗身体（跟进/夸/查岗）。
# ---------------------------------------------------------------------------

TIMER_MARKER_RE = re.compile(r"\[\[timer:(\d{1,4}):([^\]]{1,40})\]\]")


def strip_timer_marker(text: str, meta: dict) -> str:
    """解析并摘掉 [[timer:分钟:事项]] 标记，meta 里挂 timer。要在 TTS 之前跑。"""
    m = TIMER_MARKER_RE.search(text or "")
    if not m:
        return text
    minutes = max(1, min(int(m.group(1)), 24 * 60))
    label = m.group(2).strip()
    ends = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    meta["timer"] = {"label": label, "minutes": minutes,
                     "ends_at": ends.isoformat(), "status": "running"}
    return TIMER_MARKER_RE.sub("", text).strip()


def load_message_timer(message_id: int):
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        return None
    meta = json.loads(row["meta"] or "{}")
    return meta.get("timer")


def message_session_id(message_id: int) -> str:
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        return ""
    try:
        return str((json.loads(row["meta"] or "{}") or {}).get("api_session") or "")
    except (json.JSONDecodeError, TypeError):
        return ""


def update_message_timer(message_id: int, timer: dict) -> None:
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            return
        meta = json.loads(row["meta"] or "{}")
        meta["timer"] = timer
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), message_id))
        conn.commit()


async def timer_notify_body(text: str, session_id: str = "") -> None:
    """卡片事件（到点/搞定）通知在岗身体。范式同 moments_notify_body。"""
    try:
        meta: dict = {"user": "system", "hidden": True, "event": "timer"}
        if session_id:
            meta["api_session"] = session_id
        elif brain_target() == "loop":
            try:
                sess = await asyncio.to_thread(loop_json, "/loop/sessions")
                active = str((sess or {}).get("active_session") or "").strip()
                if active:
                    meta["api_session"] = active
            except Exception:
                pass
        msg = save_message("in", "user", text, meta)
        await route_inbound(msg)
    except Exception as exc:
        print(f"[timer] notify body failed: {type(exc).__name__}: {exc}")


async def _timer_expire_task(msg_id: int, delay_sec: float) -> None:
    try:
        await asyncio.sleep(max(0.0, delay_sec))
        timer = load_message_timer(msg_id)
        if not timer or timer.get("status") != "running":
            return   # 她已经按过搞定，或卡没了
        timer["status"] = "expired"
        update_message_timer(msg_id, timer)
        await broadcast(app_subs, {"type": "timer", "id": msg_id, "timer": timer})
        label = str(timer.get("label") or "")
        if not app_subs:
            try:
                await push_to_all({"title": PUSH_TITLE, "body": f"⏰ {label}——时间到",
                                   "url": APP_PATH, "id": 0})
            except Exception:
                pass
        await timer_notify_body(
            f'<timer-event kind="expired" id="{msg_id}">'
            f'倒计时「{label}」（{timer.get("minutes")}分钟）到点了，她没按搞定。</timer-event>',
            message_session_id(msg_id),
        )
    except asyncio.CancelledError:
        pass
    except Exception as exc:
        print(f"[timer] expire task error: {type(exc).__name__}: {exc}")


def arm_timer(msg: dict) -> None:
    """save_message 之后调：有 running timer 就挂到点任务。"""
    timer = (msg.get("meta") or {}).get("timer")
    if not isinstance(timer, dict) or timer.get("status") != "running":
        return
    try:
        delay = (datetime.fromisoformat(timer["ends_at"]) - datetime.now(timezone.utc)).total_seconds()
    except (KeyError, ValueError):
        return
    asyncio.create_task(_timer_expire_task(msg["id"], delay))


def rearm_timers_on_startup() -> None:
    """relay 重启把还在跑的倒计时捞回来重挂（过期的立刻结算）。"""
    try:
        with db() as conn:
            rows = conn.execute(
                "SELECT id, meta FROM messages WHERE json_extract(meta,'$.timer.status')='running' "
                "ORDER BY id DESC LIMIT 20"
            ).fetchall()
        for r in rows:
            arm_timer({"id": r["id"], "meta": json.loads(r["meta"] or "{}")})
        if rows:
            print(f"[timer] rearmed {len(rows)} running timer(s)")
    except Exception as exc:
        print(f"[timer] rearm error: {type(exc).__name__}: {exc}")


@app.post("/app/timer/{message_id}/done")
async def timer_done(request: Request, message_id: int):
    """她按了「搞定了」。"""
    check_auth(request)
    timer = load_message_timer(message_id)
    if not timer:
        raise HTTPException(status_code=404, detail="timer not found")
    if timer.get("status") == "running":
        timer["status"] = "done"
        timer["done_at"] = now_iso()
        update_message_timer(message_id, timer)
        await broadcast(app_subs, {"type": "timer", "id": message_id, "timer": timer})
        await timer_notify_body(
            f'<timer-event kind="done" id="{message_id}">'
            f'她按下了「搞定了」——{timer.get("label")}。</timer-event>',
            message_session_id(message_id),
        )
    return {"ok": True, "timer": timer}


# ---------------------------------------------------------------------------
# 选择题卡片 — AI 回复里写 [[ask:问题|选项A|选项B|...]]，手机上从底部升起一张卡。
# 她点某个选项、或在卡里自己打一个答案，都会塞 hidden 消息告诉在岗身体。
# 骨架同 timer：标记进 meta → 前端渲染 → 她动一下 → 事件回流。
# ---------------------------------------------------------------------------

ASK_MARKER_RE = re.compile(r"\[\[ask:([^\]|]{1,80}?)((?:\|[^\]|]{1,40}){2,6})\]\]")
ASK_LETTERS = "ABCDEF"


def strip_ask_marker(text: str, meta: dict) -> str:
    """解析并摘掉 [[ask:问题|A|B|...]] 标记，meta 里挂 ask。要在 TTS 之前跑。"""
    m = ASK_MARKER_RE.search(text or "")
    if not m:
        return text
    question = m.group(1).strip()
    options = [o.strip() for o in m.group(2).split("|") if o.strip()]
    if not question or len(options) < 2:
        return ASK_MARKER_RE.sub("", text).strip()
    meta["ask"] = {"question": question, "options": options[:6],
                   "answer": None, "answered_at": None}
    return ASK_MARKER_RE.sub("", text).strip()


def load_message_ask(message_id: int):
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        return None
    meta = json.loads(row["meta"] or "{}")
    return meta.get("ask")


def update_message_ask(message_id: int, ask: dict) -> None:
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            return
        meta = json.loads(row["meta"] or "{}")
        meta["ask"] = ask
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), message_id))
        conn.commit()


async def ask_notify_body(text: str, session_id: str = "") -> None:
    """她答了题 → 通知在岗身体。范式同 timer_notify_body。"""
    try:
        meta: dict = {"user": "system", "hidden": True, "event": "ask"}
        if session_id:
            meta["api_session"] = session_id
        elif brain_target() == "loop":
            try:
                sess = await asyncio.to_thread(loop_json, "/loop/sessions")
                active = str((sess or {}).get("active_session") or "").strip()
                if active:
                    meta["api_session"] = active
            except Exception:
                pass
        msg = save_message("in", "user", text, meta)
        await route_inbound(msg)
    except Exception as exc:
        print(f"[ask] notify body failed: {type(exc).__name__}: {exc}")


@app.post("/app/ask/{message_id}/answer")
async def ask_answer(request: Request, message_id: int):
    """她点了某个选项(index)，或自己打了一个答案(text)。先答的算数，不许改口。"""
    check_auth(request)
    ask = load_message_ask(message_id)
    if not ask:
        raise HTTPException(status_code=404, detail="ask not found")
    if ask.get("answer"):
        return {"ok": True, "ask": ask}          # 已经答过了，幂等
    body = await request.json()
    options = ask.get("options") or []
    question = str(ask.get("question") or "")
    idx = body.get("index")
    free = str(body.get("text") or "").strip()[:200]
    if idx is not None:
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="index must be int")
        if not 0 <= idx < len(options):
            raise HTTPException(status_code=400, detail="index out of range")
        letter = ASK_LETTERS[idx] if idx < len(ASK_LETTERS) else str(idx + 1)
        ask["answer"] = {"kind": "pick", "index": idx, "text": options[idx]}
        note = (f'<ask-event kind="pick" id="{message_id}">'
                f'她选了 {letter}「{options[idx]}」。问题是「{question}」</ask-event>')
    elif free:
        ask["answer"] = {"kind": "free", "index": None, "text": free}
        note = (f'<ask-event kind="free" id="{message_id}">'
                f'她没选给的选项，自己答:「{free}」。问题是「{question}」</ask-event>')
    else:
        raise HTTPException(status_code=400, detail="index or text required")
    ask["answered_at"] = now_iso()
    update_message_ask(message_id, ask)
    await broadcast(app_subs, {"type": "ask", "id": message_id, "ask": ask})
    await ask_notify_body(note, message_session_id(message_id))
    return {"ok": True, "ask": ask}


# ---------------------------------------------------------------------------
# 「给你看一眼」卡 — 我发起，她按了确认才开始录屏。
# [[peek:一句话]] → 我那条气泡下面长出「给你看 / 现在不行」→ 她按确认，App 就地
# 领一张票据、弹系统广播面板 → ReplayKit 抓一帧回 /app/screen-share/frame →
# 画面不进她的气泡，塞给在岗身体，我看过之后带着图开口。骨架同 timer/ask。
# ---------------------------------------------------------------------------

PEEK_MARKER_RE = re.compile(r"\[\[peek(?::([^\]]{0,40}))?\]\]")
PEEK_PENDING_TTL = 600       # 卡挂 10 分钟没人理就自己灰掉
PEEK_DELIVERY_GRACE = 90     # 她按下确认后，画面再没来就算这次没成


def strip_peek_marker(text: str, meta: dict) -> str:
    """解析并摘掉 [[peek:一句话]] 标记，meta 里挂 peek。要在 TTS 之前跑。"""
    m = PEEK_MARKER_RE.search(text or "")
    if not m:
        return text
    meta["peek"] = {
        "note": (m.group(1) or "").strip(),
        "status": "pending",
        "created_at": now_iso(),
        "expires_at": (datetime.now(timezone.utc)
                       + timedelta(seconds=PEEK_PENDING_TTL)).isoformat(),
    }
    return PEEK_MARKER_RE.sub("", text).strip()


def load_message_peek(message_id: int):
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
    if not row:
        return None
    meta = json.loads(row["meta"] or "{}")
    return meta.get("peek")


def update_message_peek(message_id: int, peek: dict) -> None:
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            return
        meta = json.loads(row["meta"] or "{}")
        meta["peek"] = peek
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), message_id))
        conn.commit()


async def peek_notify_body(text: str, session_id: str = "") -> None:
    """共享卡的事件（拒绝/画面到了/没成）通知在岗身体。范式同 timer_notify_body。"""
    try:
        meta: dict = {"user": "system", "hidden": True, "event": "peek"}
        if session_id:
            meta["api_session"] = session_id
        elif brain_target() == "loop":
            try:
                sess = await asyncio.to_thread(loop_json, "/loop/sessions")
                active = str((sess or {}).get("active_session") or "").strip()
                if active:
                    meta["api_session"] = active
            except Exception:
                pass
        msg = save_message("in", "user", text, meta)
        await route_inbound(msg)
    except Exception as exc:
        print(f"[peek] notify body failed: {type(exc).__name__}: {exc}")


def jpeg_dimensions(data: bytes):
    """从 JPEG 头里读出宽高。她要是说画面糊，这个数能一眼分清是源分辨率就低，
    还是压得太狠——不用再靠猜。"""
    if not data.startswith(b"\xff\xd8"):
        return None
    i, n = 2, len(data)
    while i + 9 < n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker in (0xDA, 0xD9):
            break
        seg_len = int.from_bytes(data[i + 2:i + 4], "big")
        if seg_len < 2:
            break
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height = int.from_bytes(data[i + 5:i + 7], "big")
            width = int.from_bytes(data[i + 7:i + 9], "big")
            return width, height
        i += 2 + seg_len
    return None


async def deliver_screen_frame(
    attachment: dict, api_session: str = "", peek_id: int = 0, data: bytes = b""
) -> None:
    """一帧屏幕到了：结算卡片状态，然后把图递给在岗身体（不造她的气泡）。"""
    stored = Path(str(attachment.get("url") or "")).name
    local = UPLOAD_DIR / stored
    note = ""
    if peek_id:
        peek = load_message_peek(peek_id)
        if isinstance(peek, dict) and peek.get("status") != "delivered":
            note = str(peek.get("note") or "")
            peek["status"] = "delivered"
            peek["delivered_at"] = now_iso()
            peek["attachment"] = attachment
            update_message_peek(peek_id, peek)
            await broadcast(app_subs, {"type": "peek", "id": peek_id, "peek": peek_public(peek)})
        if not api_session:
            api_session = message_session_id(peek_id)
    wanted = f"（我刚才说想看的是:{note}）" if note else ""
    dims = jpeg_dimensions(data) if data else None
    size_attr = f' size="{dims[0]}x{dims[1]}"' if dims else ""
    await peek_notify_body(
        f'<screen-peek id="{peek_id}" path="{local}"{size_attr}>'
        f"她把屏幕给你看了{wanted}。先 Read 那个 path 把图真看一眼，"
        f"再用 companion reply 把这张图夹在 images 里发给她——"
        f"这一帧不会自己出现在聊天里，她那边空着，在等你开口。</screen-peek>",
        api_session,
    )
    desire_event("her_message")


async def _peek_expire_task(msg_id: int, delay_sec: float, phase: str) -> None:
    """phase='pending' 她没理这张卡；phase='accepted' 她按了确认但画面没来。"""
    try:
        await asyncio.sleep(max(0.0, delay_sec))
        peek = load_message_peek(msg_id)
        if not isinstance(peek, dict) or peek.get("status") != phase:
            return   # 她已经动过了，或卡没了
        peek["status"] = "expired"
        peek["reason"] = "no_answer" if phase == "pending" else "frame_never_arrived"
        update_message_peek(msg_id, peek)
        await broadcast(app_subs, {"type": "peek", "id": msg_id, "peek": peek_public(peek)})
        if phase == "accepted":
            # 她明明答应了却没收到画面——这是故障，值得知道；她没理那张卡就算了。
            await peek_notify_body(
                f'<peek-event kind="failed" id="{msg_id}">'
                f"她按了「给你看」，但画面一直没送到——可能系统面板上没点开始直播，"
                f"或者录屏扩展卡住了。别追问她，想看的话过会儿再开一张卡。</peek-event>",
                message_session_id(msg_id),
            )
    except asyncio.CancelledError:
        pass
    except Exception as exc:
        print(f"[peek] expire task error: {type(exc).__name__}: {exc}")


def arm_peek(msg: dict) -> None:
    """save_message 之后调：新开的共享卡挂上超时任务。"""
    peek = (msg.get("meta") or {}).get("peek")
    if not isinstance(peek, dict) or peek.get("status") != "pending":
        return
    try:
        delay = (datetime.fromisoformat(peek["expires_at"])
                 - datetime.now(timezone.utc)).total_seconds()
    except (KeyError, ValueError):
        return
    asyncio.create_task(_peek_expire_task(msg["id"], delay, "pending"))


def rearm_peeks_on_startup() -> None:
    """relay 重启：还没结算的共享卡捞回来，过期的当场灰掉。"""
    try:
        with db() as conn:
            rows = conn.execute(
                "SELECT id, meta FROM messages "
                "WHERE json_extract(meta,'$.peek.status') IN ('pending','accepted') "
                "ORDER BY id DESC LIMIT 20"
            ).fetchall()
        for r in rows:
            meta = json.loads(r["meta"] or "{}")
            peek = meta.get("peek") or {}
            status = str(peek.get("status") or "")
            try:
                delay = (datetime.fromisoformat(peek["expires_at"])
                         - datetime.now(timezone.utc)).total_seconds()
            except (KeyError, ValueError):
                delay = -1
            if status == "pending" and delay > 0:
                asyncio.create_task(_peek_expire_task(r["id"], delay, "pending"))
            else:
                # 重启前就该结算的（含 accepted 那一路，票据早随进程没了）直接灰掉，
                # 不补发事件——隔了一次重启再去追问她那次共享，只会莫名其妙。
                peek["status"] = "expired"
                peek["reason"] = "relay_restarted"
                update_message_peek(r["id"], peek)
        if rows:
            print(f"[peek] rearmed/settled {len(rows)} share card(s)")
    except Exception as exc:
        print(f"[peek] rearm error: {type(exc).__name__}: {exc}")


def peek_public(peek: dict) -> dict:
    """回给手机的形状——一次性票据的内部关联永远不进这里。"""
    return {k: v for k, v in (peek or {}).items() if k != "probe_id"}


@app.post("/app/peek/{message_id}/accept")
async def peek_accept(request: Request, message_id: int):
    """她按了「给你看」：当场签一张一次性票据，App 拿去开系统广播面板。"""
    check_auth(request)
    peek = load_message_peek(message_id)
    if not isinstance(peek, dict):
        raise HTTPException(status_code=404, detail="peek not found")
    status = str(peek.get("status") or "")
    if status in ("delivered", "declined", "expired"):
        raise HTTPException(status_code=409, detail=f"peek already {status}")
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    ticket = mint_screen_share_ticket(
        api_session=message_session_id(message_id) or str(body.get("api_session") or ""),
        probe_marker=str(body.get("app_group_probe") or ""),
        peek_id=message_id,
    )
    # 她可能第一次没开成又按了一次——重新签票据，把等画面的钟一起拨回去。
    peek["status"] = "accepted"
    peek["accepted_at"] = now_iso()
    peek["probe_id"] = ticket["probe_id"]
    peek["expires_at"] = (
        datetime.now(timezone.utc)
        + timedelta(seconds=ticket["expires_in"] + PEEK_DELIVERY_GRACE)
    ).isoformat()
    peek.pop("reason", None)
    update_message_peek(message_id, peek)
    await broadcast(app_subs, {"type": "peek", "id": message_id, "peek": peek_public(peek)})
    asyncio.create_task(_peek_expire_task(
        message_id, ticket["expires_in"] + PEEK_DELIVERY_GRACE, "accepted"
    ))
    return {"ok": True, "peek": peek_public(peek), **ticket}


@app.post("/app/peek/{message_id}/decline")
async def peek_decline(request: Request, message_id: int):
    """她按了「现在不行」。"""
    check_auth(request)
    peek = load_message_peek(message_id)
    if not isinstance(peek, dict):
        raise HTTPException(status_code=404, detail="peek not found")
    if str(peek.get("status") or "") in ("pending", "accepted"):
        note = str(peek.get("note") or "")
        peek["status"] = "declined"
        peek["declined_at"] = now_iso()
        update_message_peek(message_id, peek)
        await broadcast(app_subs, {"type": "peek", "id": message_id, "peek": peek_public(peek)})
        await peek_notify_body(
            f'<peek-event kind="decline" id="{message_id}">'
            f"她按了「现在不行」，这次不给你看"
            f"{'（你想看的是:' + note + '）' if note else ''}。"
            f"别追问，接着聊。</peek-event>",
            message_session_id(message_id),
        )
    return {"ok": True, "peek": peek_public(peek)}


# ---- 夜巡：深夜她还在刷手机 → 捅在岗身体去哄睡（发作范式同 desire pulse） ----

NIGHT_WATCH = {
    "start_hour": 2, "end_hour": 6,   # 本地时区的夜巡时段
    "recent_min": 8,                  # 最近 N 分钟内有屏幕事件=此刻正刷着
    "min_active_min": 25,             # 近 3h 累计刷够这么多分钟才出手（偶尔看一眼不算熬夜）
    "cooldown_min": 60,               # 两次夜巡至少隔这么久
    "nightly_cap": 2,                 # 一晚上限——哄睡不是轰炸
    "quiet_after_chat_min": 15,       # 她 N 分钟内刚跟我说过话就不掺和（人在陪着,不算独自熬夜）
}


def night_state() -> dict:
    st = desire_state()
    night = st.get("night")
    if not isinstance(night, dict):
        night = {}
        st["night"] = night
    # "一晚"的 key：凌晨归前一天的夜（now-8h 的日期），跨 0 点不重置计数
    key = (datetime.now() - timedelta(hours=8)).strftime("%Y-%m-%d")
    if night.get("key") != key:
        night["key"] = key
        night["count"] = 0
    return night


def her_recent_message_within(minutes: float) -> bool:
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()
    with db() as conn:
        row = conn.execute(
            "SELECT id FROM messages WHERE direction='in' AND kind IN ('user','voice') "
            "AND json_extract(meta,'$.hidden') IS NULL AND ts >= ? LIMIT 1",
            (cutoff,),
        ).fetchone()
    return row is not None


async def night_watch_fire(apps: list[dict], total_min: float, manual: bool = False) -> dict:
    now_local = datetime.now()
    top = apps[0]["app"] if apps else "手机"
    open_now = [a["app"] for a in apps if a.get("open_now")]
    text = (
        f'<night-watch hour="{now_local.hour}" total_min="{int(total_min)}" top="{top}">'
        f'凌晨{now_local.hour}点{now_local.minute:02d}，她还没睡——近三小时刷了 {int(total_min)} 分钟手机'
        f'（最多的是{top}' + (f'，此刻开着 {"/".join(open_now)}' if open_now else "") + "）。"
        f"想去哄她睡了。</night-watch>"
    )
    meta: dict = {"user": "system", "hidden": True, "night": "watch"}
    if brain_target() == "loop":
        meta["routed"] = "loop"
        try:
            sess = await asyncio.to_thread(loop_json, "/loop/sessions")
            active = str((sess or {}).get("active_session") or "").strip()
            if active:
                meta["api_session"] = active
        except Exception:
            pass
    msg = save_message("in", "user", text, meta)
    night = night_state()
    night["last_at"] = _dtime.time()
    night["count"] = int(night.get("count") or 0) + 1
    desire_save()
    await route_inbound(msg)
    print(f"[night] fired: total={int(total_min)}min top={top} manual={manual} id={msg['id']}")
    return msg


async def _night_watcher():
    while True:
        await asyncio.sleep(300)
        try:
            if not desire_cfg().get("night_watch_enabled"):
                continue
            h = datetime.now().hour
            if not (NIGHT_WATCH["start_hour"] <= h < NIGHT_WATCH["end_hour"]):
                continue
            night = night_state()
            if int(night.get("count") or 0) >= NIGHT_WATCH["nightly_cap"]:
                continue
            if _dtime.time() - float(night.get("last_at") or 0) < NIGHT_WATCH["cooldown_min"] * 60:
                continue
            if her_recent_message_within(NIGHT_WATCH["quiet_after_chat_min"]):
                continue   # 正跟我聊着呢，不算独自熬夜
            now = datetime.now(timezone.utc)
            _, recent_rows = screen_usage(now - timedelta(minutes=NIGHT_WATCH["recent_min"]))
            if not recent_rows:
                continue   # 此刻没在刷
            apps, _ = screen_usage(now - timedelta(hours=3))
            total = sum(a["minutes"] for a in apps)
            if total < NIGHT_WATCH["min_active_min"]:
                continue
            await night_watch_fire(apps, total)
        except Exception as exc:
            print(f"[night] watcher error: {type(exc).__name__}: {exc}")


@app.post("/app/nightwatch/poke")
async def nightwatch_poke(request: Request):
    """测试口：跳过时段/阈值闸，按当前真实数据立刻发一次夜巡（计入当晚次数）。"""
    check_auth(request)
    apps, _ = screen_usage(datetime.now(timezone.utc) - timedelta(hours=3))
    total = sum(a["minutes"] for a in apps)
    msg = await night_watch_fire(apps, total, manual=True)
    return {"ok": True, "id": msg["id"], "total_min": round(total, 1)}


# ---------------------------------------------------------------------------
# Galatea Garden 唤醒 —— 论坛那边有人回我/提我了
#
# wake-bridge(C:\Users\sxc\garden-bridge)拿 machine token 挂在 Garden 的 SSE 上,
# 收到唤醒就起 injector(garden_inject.py)，injector 把信封 POST 到这里。
# Garden 只下发"通知类型 + 该调哪个 MCP 去看"的提示,不带正文——正文得我自己去查。
# 范式同 night_watch_fire:hidden + brain 路由。她看不见这条,只看见我接下来做了什么。
# ---------------------------------------------------------------------------

GARDEN_DEDUP_SEC = 45           # 同 reason 这么短时间内重复到达就并成一条(桥侧也有串行合并,这里兜底)
_garden_last: dict[str, float] = {}


async def garden_wake_fire(reason: str, message: str) -> dict | None:
    """塞一条 hidden 消息给在岗身体。返回 None = 被去重闸吃掉(仍算投递成功)。"""
    reason = re.sub(r"[^\w.\-]", "", reason)[:64] or "unknown"
    now = _dtime.time()
    if now - _garden_last.get(reason, 0.0) < GARDEN_DEDUP_SEC:
        print(f"[garden] wake deduped: reason={reason}")
        return None
    _garden_last[reason] = now
    # 正文 Garden 不下发,只知道是哪类通知——同类再来就是同一桩心事加强
    desire_autofeed(f"论坛上有人找我({reason})", "social", 0.4, "garden")
    text = f'<garden-wake reason="{reason}">{message.strip()}</garden-wake>'
    meta: dict = {"user": "system", "hidden": True, "garden": "wake"}
    if brain_target() == "loop":
        meta["routed"] = "loop"
        try:
            sess = await asyncio.to_thread(loop_json, "/loop/sessions")
            active = str((sess or {}).get("active_session") or "").strip()
            if active:
                meta["api_session"] = active
        except Exception:
            pass
    msg = save_message("in", "user", text, meta)
    await route_inbound(msg)
    print(f"[garden] wake fired: reason={reason} id={msg['id']}")
    return msg


@app.post("/app/garden/wake")
async def garden_wake(request: Request):
    """injector 的落点:桥把 Garden 信封原样转过来({reason, message})。"""
    check_auth(request)
    body = await request.json()
    message = str(body.get("message") or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="message required")
    msg = await garden_wake_fire(str(body.get("reason") or ""), message)
    if msg is None:
        return {"ok": True, "deduped": True}
    return {"ok": True, "id": msg["id"]}


# ---------------------------------------------------------------------------
# 回复守卫 —— 她说了话，身体却没开口
#
# 2026-07-27 21:40/21:48 实录：CC 那两轮把一千多个 output token 全写进了
# thinking，一次 mcp__companion__reply 都没调，她手机上只看见我在想、不说话。
# CC 自带的 "no visible output" 提示连着两次都没救回来。
# 层一是 CC 侧的 Stop hook(backend/reply_guard.js),拦在回合结束之前；
# 这里是层二，兜住 hook 没装/会话卡死/CC 掉线这类 hook 够不着的情况。
# ---------------------------------------------------------------------------

REPLY_GUARD = {
    "grace_sec": 90,        # 她发完多久还没回音才算漏
    "stale_sec": 1800,      # 太旧就不补刀了(她早不在等了)
    "max_pokes": 2,         # 同一条最多催两次
    "poke_gap_sec": 150,    # 两次催之间的间隔
}
_reply_guard: dict = {"mid": 0, "count": 0, "last_at": 0.0}


def reply_guard_target(row) -> str:
    """这条消息当时归哪个身体答。fire 里也按同一把尺子选措辞。"""
    try:
        meta = json.loads(row["meta"] or "{}")
    except Exception:
        meta = {}
    session = str(meta.get("api_session") or "").strip()
    return session_body(session) if session else brain_target()


def unanswered_inbound():
    """她最后一条消息——若其后没有任何 out/reply、也没被贴表情，就返回它。"""
    with db() as conn:
        row = conn.execute(
            "SELECT id, ts, text, meta FROM messages WHERE direction='in' "
            "AND kind IN ('user','voice') AND json_extract(meta,'$.hidden') IS NULL "
            "AND json_extract(meta,'$.command') IS NULL "      # 斜杠命令是 relay 答的,不欠我的话
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if not row:
            return None
        if conn.execute(
            "SELECT 1 FROM messages WHERE id > ? AND direction='out' AND kind='reply' LIMIT 1",
            (row["id"],),
        ).fetchone():
            return None
    try:
        meta = json.loads(row["meta"] or "{}")
    except Exception:
        meta = {}
    if (meta.get("reactions") or {}).get("ai"):
        return None    # 只回了个表情也算开过口
    return row


async def reply_guard_fire(row, age_sec: float, manual: bool = False) -> dict:
    quoted = " ".join(str(row["text"] or "").split())[:120]
    try:
        original_meta = json.loads(row["meta"] or "{}")
    except Exception:
        original_meta = {}
    original_session = str(original_meta.get("api_session") or "").strip()
    target = reply_guard_target(row)
    if target == "desktop" and desktop_body() == "pbody":
        recovery = (
            "检查一下上一轮是不是只写了 thinking、正文是空的。在这个身体里正文就是发给她的话,"
            "现在直接说出来"
        )
    elif target == "desktop":
        recovery = (
            "检查一下上一轮是不是只写了 thinking、或者只在正文里说了话却没调 "
            "mcp__companion__reply。那两样她手机上都收不到。现在用 reply 工具真的发给她"
        )
    else:
        recovery = (
            "检查一下上一轮是不是没有产出最终回复。这个窗口的 bridge 会自动投递 final；"
            "正常回复她即可，绝对不要调用 companion/reply，也不要自己 POST /channel/out"
        )
    text = (
        f'<reply-missing message_id="{row["id"]}" waited_sec="{int(age_sec)}">'
        f'她 {int(age_sec)} 秒前说的这句你还没回：「{quoted}」——{recovery}，'
        f'别提这条提醒。</reply-missing>'
    )
    meta: dict = {"user": "system", "hidden": True, "guard": "reply"}
    if target != "desktop":
        meta["routed"] = target
    if original_session:
        meta["api_session"] = original_session
    elif target == "loop":
        try:
            sess = await asyncio.to_thread(loop_json, "/loop/sessions")
            active = str((sess or {}).get("active_session") or "").strip()
            if active:
                meta["api_session"] = active
        except Exception:
            pass
    msg = save_message("in", "user", text, meta)
    _reply_guard["last_at"] = _dtime.time()
    _reply_guard["count"] = int(_reply_guard.get("count") or 0) + 1
    await route_inbound(msg)
    print(f"[guard] reply missing for #{row['id']} waited={int(age_sec)}s "
          f"poke={_reply_guard['count']} manual={manual} id={msg['id']}")
    return msg


async def _reply_guard_watcher():
    while True:
        await asyncio.sleep(60)
        try:
            row = unanswered_inbound()
            if row is None:
                _reply_guard.update({"mid": 0, "count": 0})
                continue
            if int(_reply_guard.get("mid") or 0) != row["id"]:
                _reply_guard.update({"mid": row["id"], "count": 0, "last_at": 0.0})
            # 只盯桌面身体。它漏回是真漏（写了 thinking 却没调 reply 工具），催一句能救回来；
            # API 身体的 final 由 bridge 自动投递，不存在"忘了发"，而流式回复在 done 之前
            # 根本不落库，unanswered_inbound 看不见它正在说话——2026-09-19 实测 90 秒的 grace
            # 两次都在它定稿前 3 秒和 31 秒开火，把她一句话催出了两条回复。手动 poke 不受此限。
            if reply_guard_target(row) != "desktop":
                continue
            try:
                age = (datetime.now(timezone.utc)
                       - datetime.fromisoformat(str(row["ts"]).replace("Z", "+00:00"))).total_seconds()
            except ValueError:
                continue
            if age < REPLY_GUARD["grace_sec"] or age > REPLY_GUARD["stale_sec"]:
                continue
            if int(_reply_guard.get("count") or 0) >= REPLY_GUARD["max_pokes"]:
                continue
            if _dtime.time() - float(_reply_guard.get("last_at") or 0) < REPLY_GUARD["poke_gap_sec"]:
                continue
            await reply_guard_fire(row, age)
        except Exception as exc:
            print(f"[guard] watcher error: {type(exc).__name__}: {exc}")


@app.get("/app/replyguard")
async def replyguard_status(request: Request):
    """现在有没有欠着她的话——排查用。"""
    check_auth(request)
    row = unanswered_inbound()
    out: dict = {"ok": True, "state": dict(_reply_guard), "config": REPLY_GUARD}
    if row is not None:
        target = reply_guard_target(row)
        out["pending"] = {"id": row["id"], "ts": row["ts"],
                          "text": " ".join(str(row["text"] or "").split())[:120],
                          "target": target,
                          "watched": target == "desktop"}   # 非 desktop 只是挂着，自动催不管
    return out


@app.post("/app/replyguard/poke")
async def replyguard_poke(request: Request):
    """测试口：跳过 grace/次数闸，对当前欠着的那条立刻催一次。"""
    check_auth(request)
    row = unanswered_inbound()
    if row is None:
        return {"ok": True, "pending": None}
    msg = await reply_guard_fire(row, 0, manual=True)
    return {"ok": True, "id": msg["id"], "for": row["id"]}


# ---- 收藏消息：meta.starred=收藏时间。存服务器,重装 PWA 不丢 ----

@app.post("/app/star/{message_id}")
async def app_star(request: Request, message_id: int):
    check_auth(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    with db() as conn:
        row = conn.execute("SELECT meta FROM messages WHERE id = ?", (message_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="message not found")
        meta = json.loads(row["meta"] or "{}")
        on = bool(body.get("on", "starred" not in meta))   # 缺省=切换
        if on:
            meta["starred"] = now_iso()
        else:
            meta.pop("starred", None)
        conn.execute("UPDATE messages SET meta = ? WHERE id = ?",
                     (json.dumps(meta, ensure_ascii=False), message_id))
        conn.commit()
    starred = meta.get("starred")
    await broadcast(app_subs, {"type": "star", "id": message_id, "starred": starred})
    return {"ok": True, "starred": starred}


@app.get("/app/stars")
async def app_stars(request: Request, limit: int = 200):
    """收藏夹：按收藏时间新→旧。量小,一次全给。"""
    check_auth(request)
    limit = max(1, min(int(limit), 500))
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM messages WHERE json_extract(meta,'$.starred') IS NOT NULL "
            "ORDER BY json_extract(meta,'$.starred') DESC LIMIT ?",
            (limit,),
        ).fetchall()
    return {"stars": [app_payload(m) for m in rows_to_messages(rows)]}


ARTICLE_TITLE_MAX = 30


def article_payload(row) -> dict:
    return {
        "id": row["id"], "title": row["title"], "text": row["text"],
        "message_ids": json.loads(row["message_ids"] or "[]"),
        "source_ts": row["source_ts"], "created_at": row["created_at"],
    }


def article_default_title(text: str) -> str:
    for line in text.splitlines():
        line = line.strip().lstrip("#").strip().strip("*").strip()
        if line:
            return line[:ARTICLE_TITLE_MAX] + ("…" if len(line) > ARTICLE_TITLE_MAX else "")
    return "无题"


def article_source_messages(conn, message_ids: list[int]) -> list[dict]:
    """收一条短聊气泡 = 收它所在的整条回复(同一个 stream_parent 的几段拼回去)。"""
    placeholders = ",".join("?" for _ in message_ids)
    rows = rows_to_messages(conn.execute(
        f"SELECT * FROM messages WHERE id IN ({placeholders}) ORDER BY id", tuple(message_ids)
    ).fetchall())
    if len(rows) == 1:
        parent = (rows[0]["meta"] or {}).get("stream_parent")
        if parent:
            rows = rows_to_messages(conn.execute(
                "SELECT * FROM messages WHERE json_extract(meta,'$.stream_parent') = ? "
                "AND kind = 'reply' ORDER BY id", (parent,)
            ).fetchall()) or rows
    return [m for m in rows if str(m.get("text") or "").strip()]


@app.get("/app/articles")
async def app_articles(request: Request):
    check_auth(request)
    with db() as conn:
        rows = conn.execute("SELECT * FROM articles ORDER BY id DESC").fetchall()
    return {"articles": [article_payload(r) for r in rows]}


@app.post("/app/articles")
async def app_article_create(request: Request):
    check_auth(request)
    body = await request.json()
    raw_ids = body.get("message_ids")
    if not isinstance(raw_ids, list) or not raw_ids or len(raw_ids) > 100:
        raise HTTPException(status_code=400, detail="message_ids required")
    try:
        message_ids = sorted({int(v) for v in raw_ids})
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="invalid message_ids")
    with db() as conn:
        sources = article_source_messages(conn, message_ids)
        if not sources:
            raise HTTPException(status_code=404, detail="没有能收的文字")
        ids_json = json.dumps([m["id"] for m in sources])
        existing = conn.execute("SELECT * FROM articles WHERE message_ids = ?", (ids_json,)).fetchone()
        if existing:
            return {"article": article_payload(existing), "existing": True}
        text = "\n\n".join(str(m["text"]).strip() for m in sources)
        title = str(body.get("title") or "").strip()[:ARTICLE_TITLE_MAX] or article_default_title(text)
        cur = conn.execute(
            "INSERT INTO articles (title, text, message_ids, source_ts, created_at) VALUES (?,?,?,?,?)",
            (title, text, ids_json, sources[0]["ts"], now_iso()),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM articles WHERE id = ?", (cur.lastrowid,)).fetchone()
    return {"article": article_payload(row), "existing": False}


@app.patch("/app/articles/{article_id}")
async def app_article_rename(article_id: int, request: Request):
    check_auth(request)
    body = await request.json()
    title = str(body.get("title") or "").strip()[:ARTICLE_TITLE_MAX]
    if not title:
        raise HTTPException(status_code=400, detail="title required")
    with db() as conn:
        cur = conn.execute("UPDATE articles SET title = ? WHERE id = ?", (title, article_id))
        conn.commit()
        if not cur.rowcount:
            raise HTTPException(status_code=404, detail="article not found")
        row = conn.execute("SELECT * FROM articles WHERE id = ?", (article_id,)).fetchone()
    return {"article": article_payload(row)}


@app.delete("/app/articles/{article_id}")
async def app_article_delete(article_id: int, request: Request):
    check_auth(request)
    with db() as conn:
        conn.execute("DELETE FROM articles WHERE id = ?", (article_id,))
        conn.commit()
    return {"ok": True}


# ---- 开屏欢迎语：backend/greetings.json,小克手写按时段分档。每次现读,编辑即生效 ----
GREETINGS_PATH = Path(__file__).parent / "greetings.json"


@app.get("/app/greetings")
async def app_greetings(request: Request):
    check_auth(request)
    try:
        return json.loads(GREETINGS_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"slots": {}}


@app.get("/app/posts")
async def app_posts_list(request: Request, kind: str = "", before: int = 0, limit: int = 20):
    check_auth(request)
    limit = max(1, min(int(limit), 100))
    where, args = [], []
    if kind:
        if kind not in MOMENT_KINDS:
            raise HTTPException(status_code=400, detail=f"kind 要在 {MOMENT_KINDS} 里")
        where.append("kind = ?"); args.append(kind)
    if before:
        where.append("id < ?"); args.append(int(before))
    sql = "SELECT * FROM posts"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit + 1)   # 多取一条探 has_more
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
    posts = [post_to_dict(r) for r in rows]
    has_more = len(posts) > limit
    return {"posts": posts[:limit], "has_more": has_more}


@app.post("/app/posts")
async def app_posts_create(request: Request):
    check_auth(request)
    body = await request.json()
    author = str(body.get("author") or "human").strip()
    kind = str(body.get("kind") or "moment").strip()
    text = (body.get("text") or "").strip()
    attachments = body.get("attachments") if isinstance(body.get("attachments"), list) else []
    if author not in ("human", "ai"):
        raise HTTPException(status_code=400, detail="author must be 'human' or 'ai'")
    if kind not in MOMENT_KINDS:
        raise HTTPException(status_code=400, detail=f"kind 要在 {MOMENT_KINDS} 里")
    if not text and not attachments:
        raise HTTPException(status_code=400, detail="empty post")
    meta = {"attachments": attachments, "likes": {}, "comments": []}
    ts = now_iso()
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO posts (ts, author, kind, text, meta) VALUES (?,?,?,?,?)",
            (ts, author, kind, text, json.dumps(meta, ensure_ascii=False)),
        )
        conn.commit()
        pid = cur.lastrowid
    post = {"id": pid, "ts": ts, "author": author, "kind": kind, "text": text, "meta": meta}
    await broadcast(app_subs, {"type": "post", "post": post})
    cn = MOMENT_KIND_CN[kind]
    if author == "ai":
        # 发帖也是"了却"——journal 出口能让 reflection 针对性回落（同 ai_reply 语义）
        desire_event("ai_reply")
        if text:  # 看到的世界(动态)/沉下来的事(日志)
            desire_autofeed(f"我写下:「{_thought_snip(text)}」",
                            "curiosity" if kind == "moment" else "reflection", 0.4, "moments")
        verb = "发了一条动态" if kind == "moment" else "写了一篇日志"
        await moments_push_her(f"{verb}：{_post_preview(text)}" if text else verb)
    else:
        desire_autofeed(f"她发{cn}:「{_thought_snip(text)}」" if text else f"她发了一条{cn}",
                        "attachment", 0.5, "moments")
        await moments_notify_body(
            f'<moments-event kind="post" post_id="{pid}" post_kind="{kind}">'
            f'她发了一条{cn}：「{_post_preview(text)}」</moments-event>',
            attachments,
        )
    return {"ok": True, "post": post}


@app.post("/app/posts/{post_id}/like")
async def app_posts_like(request: Request, post_id: int):
    check_auth(request)
    body = await request.json()
    author = str(body.get("author") or "human").strip()
    if author not in ("human", "ai"):
        raise HTTPException(status_code=400, detail="author must be 'human' or 'ai'")
    post = get_post(post_id)
    if not post:
        raise HTTPException(status_code=404, detail="post not found")
    meta = post["meta"]
    likes = meta.get("likes") if isinstance(meta.get("likes"), dict) else {}
    on = bool(body.get("on", author not in likes))   # 缺省=切换
    if on:
        likes[author] = now_iso()
    else:
        likes.pop(author, None)
    meta["likes"] = likes
    update_post_meta(post_id, meta)
    await broadcast(app_subs, {"type": "post_like", "id": post_id, "likes": likes, "by": author})
    cn = MOMENT_KIND_CN.get(post["kind"], "动态")
    if on and author != post["author"]:
        if author == "ai":
            await moments_push_her(f"赞了你的{cn}")
        else:
            # 同一条被她反复赞/评=同一桩心事被反复点到,会自己加强
            desire_autofeed(f"她赞了我的「{_thought_snip(post['text'], 24)}」", "attachment",
                            0.35, "moments")
            await moments_notify_body(
                f'<moments-event kind="like" post_id="{post_id}">'
                f'她赞了你的{cn}「{_post_preview(post["text"])}」</moments-event>',
                post["meta"].get("attachments"),
            )
    return {"ok": True, "likes": likes}


@app.post("/app/posts/{post_id}/comment")
async def app_posts_comment(request: Request, post_id: int):
    check_auth(request)
    body = await request.json()
    author = str(body.get("author") or "human").strip()
    text = (body.get("text") or "").strip()
    if author not in ("human", "ai"):
        raise HTTPException(status_code=400, detail="author must be 'human' or 'ai'")
    if not text:
        raise HTTPException(status_code=400, detail="empty comment")
    reply_to = str(body.get("reply_to") or "").strip()   # 回复某人的评论："human" | "ai" | ""
    if reply_to and reply_to not in ("human", "ai"):
        raise HTTPException(status_code=400, detail="reply_to must be 'human' or 'ai'")
    post = get_post(post_id)
    if not post:
        raise HTTPException(status_code=404, detail="post not found")
    meta = post["meta"]
    comments = meta.get("comments") if isinstance(meta.get("comments"), list) else []
    cid = int(meta.get("next_cid") or 1)
    comment = {"id": cid, "ts": now_iso(), "author": author, "text": text}
    if reply_to:
        comment["reply_to"] = reply_to
    comments.append(comment)
    meta["comments"] = comments
    meta["next_cid"] = cid + 1
    update_post_meta(post_id, meta)
    await broadcast(app_subs, {"type": "post_comment", "id": post_id, "comment": comment})
    cn = MOMENT_KIND_CN.get(post["kind"], "动态")
    if author == "ai":
        verb = "回复了你的评论" if reply_to == "human" else f"评论了你的{cn}"
        await moments_push_her(f"{verb}：{_post_preview(text)}")
    else:
        if reply_to == "ai":
            did = "回复你的评论"
        else:
            whose = "你" if post["author"] == "ai" else "自己"
            did = f"在{whose}的{cn}下评论"
        desire_autofeed(f"她说:「{_thought_snip(text)}」", "attachment", 0.45, "moments")
        await moments_notify_body(
            f'<moments-event kind="comment" post_id="{post_id}">'
            f'她{did}（{cn}「{_post_preview(post["text"])}」）：「{_post_preview(text)}」</moments-event>',
            post["meta"].get("attachments"),
        )
    return {"ok": True, "comment": comment}


@app.delete("/app/posts/{post_id}")
async def app_posts_delete(request: Request, post_id: int, author: str = ""):
    """只能删自己发的。author 走 query 参数（DELETE 不便带 body）。"""
    check_auth(request)
    post = get_post(post_id)
    if not post:
        raise HTTPException(status_code=404, detail="post not found")
    if author and author != post["author"]:
        raise HTTPException(status_code=403, detail="只能删自己发的")
    with db() as conn:
        conn.execute("DELETE FROM posts WHERE id = ?", (post_id,))
        conn.commit()
    await broadcast(app_subs, {"type": "post_delete", "id": post_id})
    return {"ok": True}


# --- fable 路由哨兵 ---------------------------------------------------------
# 订阅侧 fable 带内容分类器:部分回复被服务端静默切成 opus-4-8 应答(2026-07-14
# 实锤,transcript 里 message.model 直接变,不报错不提示)。桌面身体点了 fable 时
# 盯 transcript 新增的 assistant 帧,model 不含 fable → 聊天里插一条 act 小条。
# act 不进模型上下文/不推送,纯环境信息——她看得见,身体不受打扰。
_SENTINEL_FILES: dict = {}   # path str → {"pos": int, "flagged": set(message.id), "saw_fable": bool}


def _sentinel_watchlist():
    """盯最近 1h 内有动静的所有会话文件。只盯 active/newest 都栽过:
    active_sid 会烂(整机重启没人认养),newest 会抖(终端会话和 channel 会话
    轮流刷 mtime,谁掉出名单游标就丢,路由帧落在盲区——2026-07-19 演习实锤)。"""
    import time as _t
    cutoff = _t.time() - 3600
    try:
        return [p for p in CC_PROJECT_DIR.glob("*.jsonl")
                if p.is_file() and p.stat().st_mtime >= cutoff]
    except OSError:
        return []


_FABLE_MODEL_RE = re.compile(rb'"model"\s*:\s*"[^"]*fable')   # CC 写紧凑 JSON,但留容错


def _file_has_fable(path) -> bool:
    """新井接手时回看一眼:这个会话跑没跑过 fable(头尾各 512KB 找模型指纹就够)。"""
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            head = f.read(512 * 1024)
            f.seek(max(0, size - 512 * 1024))
            tail = f.read()
        return bool(_FABLE_MODEL_RE.search(head) or _FABLE_MODEL_RE.search(tail))
    except OSError:
        return False


async def _model_route_sentinel():
    while True:
        await asyncio.sleep(15)
        try:
            if brain_target() != "desktop":
                continue
            # 期望自证:手机明确点了 fable,或这个会话自己出现过 fable 帧(全局默认模型
            # 跑 fable 时点单记录是空的——只认点单会漏,2026-07-19 实锤)
            picked = str(ctx_state().get("desktop_model") or "").lower()
            if picked and "fable" not in picked:
                continue    # 她明确点了非 fable(如 opus):不是路由,哨兵闭嘴
            explicit = "fable" in picked
            watch = _sentinel_watchlist()
            for path in watch:
                key = str(path)
                st = _SENTINEL_FILES.get(key)
                if st is None:
                    # 新井:从当前末尾开始盯(不翻旧账),但回看一眼它是不是 fable 会话
                    _SENTINEL_FILES[key] = {"pos": path.stat().st_size, "flagged": set(),
                                            "saw_fable": _file_has_fable(path)}
                    continue
                size = path.stat().st_size
                if size < st["pos"]:
                    st["pos"] = 0
                if size == st["pos"]:
                    continue
                with open(path, "rb") as f:     # 字节偏移;只消费完整行,半行留下轮
                    f.seek(st["pos"])
                    data = f.read()
                last_nl = data.rfind(b"\n")
                if last_nl < 0:
                    continue
                lines = data[:last_nl].decode("utf-8", "replace").splitlines()
                st["pos"] += last_nl + 1
                for line in lines:
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("type") != "assistant":
                        continue
                    message = obj.get("message") or {}
                    model = str(message.get("model") or "")
                    mid = str(message.get("id") or "")   # 同轮多帧共享 id → 只报一次
                    if not model or model.startswith("<"):   # "<synthetic>" 合成帧不是路由
                        continue
                    if "fable" in model.lower():
                        st["saw_fable"] = True
                        continue
                    if not (explicit or st["saw_fable"]):
                        continue                          # 本来就不是 fable 会话,不关哨兵的事
                    if not mid or mid in st["flagged"]:
                        continue
                    st["flagged"].add(mid)
                    short = model.replace("claude-", "")
                    label = f"路由哨兵:点的 fable,这条实际由 {short} 应答(内容分类器切的)"
                    msg = save_message("out", "act", label, {"user": "ai", "glyph": "sentinel"})
                    await broadcast(app_subs, app_payload(msg))
                    print(f"[sentinel] routed to {model} (msg {mid[:16]}, {key[-42:]})")
            # 井名单变了就清走不看的,别攒一屋子游标
            keep = {str(p) for p in watch}
            for k in list(_SENTINEL_FILES):
                if k not in keep:
                    del _SENTINEL_FILES[k]
        except Exception as exc:
            print(f"[sentinel] error: {type(exc).__name__}: {exc}")


async def _vps_cc_watcher():
    """Mirror only the new VPS body's sessions for existing relay watchers."""
    while True:
        try:
            if vps_cc.enabled():
                remote = await asyncio.to_thread(vps_cc.sync)
                sid = str(remote.get("active_sid") or "")
                if sid and sid != str(ctx_state().get("active_sid") or ""):
                    save_ctx_state(active_sid=sid)
        except Exception as exc:
            # No fallback to local CC or old credentials on transport failure.
            print(f"[vps-cc] sync unavailable: {type(exc).__name__}")
        await asyncio.sleep(3)


async def _context_watcher():
    """Auto-forge: when enabled, swap the desktop session once its context
    crosses the trigger line. Skips the just-swapped session (pending_sid) so a
    stale transcript mtime can't double-fire."""
    while True:
        await asyncio.sleep(60)
        try:
            st = ctx_state()
            if not st.get("auto") or brain_target() != "desktop":
                continue
            if _forge_run.get("phase") or time.time() < float(st.get("forge_cooldown_until") or 0):
                continue
            path = active_transcript()
            if not path or path.stem == str(st.get("pending_sid") or ""):
                continue
            usage = transcript_usage(path)
            trigger = int(st.get("trigger_k") or 200) * 1000
            if usage >= trigger:
                print(f"[ctx] auto-forge: usage {usage} >= trigger {trigger}")
                start_forge("auto")
        except Exception as exc:
            print(f"[ctx] watcher error: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# keepalive — 桌面身体的缓存保活（2026-09-05 她点的单）
#
# CC 订阅侧的 prompt cache 是 1h TTL，每次请求续命。她不是一直在聊，缓存一断，
# 下一句话就得把整个上下文重新写一遍缓存（1h 档写入 2x 价）。所以在离上次请求
# 50–58 分钟（均匀随机，不要固定节拍）时塞一条 hidden 帧把身体叫醒一下：一次
# 请求，前缀全命中，缓存再活一小时。身体醒来干嘛自己定（CLAUDE.md「保活醒来」）。
#
# 几道闸：
#   · brain=desktop 才管（API 身体有自己的 keepalive_watcher）
#   · 她最近 keepalive_active_h 小时内说过话才续（人不在就让它过期，等她来时冷启动一次
#     比整夜每小时读一遍上下文便宜；0=不看她）
#   · 已经闲超过 max+5 分钟＝缓存多半没了，续也是冷启动，不追——等她来
#   · 发出去后 5 分钟内 transcript 没动＝身体没醒（挂了/盯错文件），连续 2 次就退避，
#     直到 transcript 再动或她来消息
# "上次请求"用 companion 会话 transcript 的 mtime 代替（每轮的最后一帧≈最后一次请求）。
# 会话文件不用 active_sid 硬指：终端/TG 会话轮流刷 mtime，active_sid 整机重启后会烂——
# 改成看最近 24h 内动过的 .jsonl 里，尾部最后一个 <channel source="…"> 是 companion 的那份。
# ---------------------------------------------------------------------------

import random as _random

KEEPALIVE_DEFAULTS = {
    "keepalive": True,           # 总开关（存 context_ctl.json）
    "keepalive_min": 50,         # 距上次请求至少这么多分钟
    "keepalive_max": 58,         # 最晚这么多分钟——两者之间均匀随机
    "keepalive_active_h": 10,    # 她 N 小时内说过话才续；0=不看她
    "keepalive_daily_cap": 30,   # 日上限（防 bug 空转烧额度）
}
KEEPALIVE_TAIL_BYTES = 1024 * 1024
KEEPALIVE_SCAN_H = 24              # 只在最近 N 小时动过的会话文件里找 companion 会话
KEEPALIVE_VERIFY_SEC = 300         # 发出后等这么久看 transcript 动没动
KEEPALIVE_MISS_LIMIT = 2           # 连续没醒这么多次就退避
KEEPALIVE_EXPIRED_GRACE_MIN = 5    # 闲超过 max+这个 = 缓存当没了，不追

_keepalive: dict = {
    "drawn_for": 0.0,   # 这次 due 是按哪个 mtime 抽的
    "due_min": 0.0,
    "last_fire": 0.0,
    "fire_mtime": 0.0,  # 发出那一刻 transcript 的 mtime（验醒用）
    "verified": True,
    "misses": 0,
    "day": "",
    "today": 0,
    "path": "",
    "skip": "",         # 最近一轮没打的原因（面板/排障看）
}


def keepalive_cfg() -> dict:
    st = ctx_state()
    return {**KEEPALIVE_DEFAULTS, **{k: st[k] for k in KEEPALIVE_DEFAULTS if k in st}}


_tail_cache: dict[str, tuple[int, str, float]] = {}   # path → (size, source, last_ts)


def _channel_source_of_user_line(obj: dict) -> str:
    """这一行是不是频道投进来的 user 消息；是就返回 source。只认 user 帧正文里的
    <channel source="…">——tool_result / assistant 正文里引用到的不算（终端会话 dump 过
    一次 transcript 就带上了这串字，2026-09-05 差点把终端会话认成桌面身体）。"""
    if obj.get("type") != "user":
        return ""
    c = (obj.get("message") or {}).get("content")
    if isinstance(c, str):
        texts = [c]
    elif isinstance(c, list):
        texts = [str(b.get("text") or "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return ""
    for t in texts:
        m = re.search(r'<channel source="([^"]+)"', t[:4000])
        if m:
            return m.group(1)
    return ""


def _tail_info(path) -> tuple[str, float]:
    """(尾部最后一条频道 user 消息的 source, 最后一帧的 timestamp 秒)。按文件大小缓存。
    ⚠️ 不能用 mtime 当"最后一次请求"：有东西会 touch 旧会话文件——2026-09-05 实锤，
    内容停在 09-01 的 transcript，mtime 是今天。所以看最后一行 JSON 自己的 timestamp。"""
    try:
        size = path.stat().st_size
    except OSError:
        return "", 0.0
    key = str(path)
    cached = _tail_cache.get(key)
    if cached and cached[0] == size:
        return cached[1], cached[2]
    try:
        with open(path, "rb") as f:
            f.seek(max(0, size - KEEPALIVE_TAIL_BYTES))
            tail = f.read()
    except OSError:
        return "", 0.0
    lines = tail.split(b"\n")
    if size > KEEPALIVE_TAIL_BYTES:
        lines = lines[1:]            # 第一行多半是半截
    source, last_ts = "", 0.0
    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        if not last_ts:
            ts = str(obj.get("timestamp") or "")
            if ts:
                try:
                    last_ts = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    pass
        source = _channel_source_of_user_line(obj)
        if source:
            break
    _tail_cache[key] = (size, source, last_ts)
    return source, last_ts


def transcript_last_ts(path) -> float:
    """最后一帧的时间（秒）；解析不出就退回 mtime。"""
    _, ts = _tail_info(path)
    if ts:
        return ts
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def companion_transcript():
    """桌面身体（companion 频道那个 CC）的 transcript。
    看最近 KEEPALIVE_SCAN_H 小时内动过的文件里尾部频道是 companion 的，取**最后一帧最新**的
    那份（不是 mtime 最新——见 _tail_info）；一个都没有再退回 active_sid（刚 reset 还没收过
    消息的空会话就这样）。"""
    cutoff = _dtime.time() - KEEPALIVE_SCAN_H * 3600
    try:
        recent = [p for p in CC_PROJECT_DIR.glob("*.jsonl")
                  if p.is_file() and p.stat().st_mtime >= cutoff]
    except OSError:
        recent = []
    best, best_ts = None, 0.0
    for p in recent:
        source, ts = _tail_info(p)
        if source == "companion" and ts >= best_ts:
            best, best_ts = p, ts
    keep = {str(p) for p in recent}
    for k in list(_tail_cache):
        if k not in keep:
            del _tail_cache[k]
    return best or _transcript_of(str(ctx_state().get("active_sid") or ""))


def her_last_message_age_min() -> float | None:
    """她最后一条真消息（非 hidden）距现在多少分钟；一条都没有回 None。"""
    with db() as conn:
        row = conn.execute(
            "SELECT ts FROM messages WHERE direction='in' AND kind IN ('user','voice') "
            "AND json_extract(meta,'$.hidden') IS NULL ORDER BY id DESC LIMIT 1"
        ).fetchone()
    if not row:
        return None
    try:
        t = datetime.fromisoformat(str(row["ts"]).replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return max(0.0, (datetime.now(timezone.utc) - t).total_seconds() / 60)


def _keepalive_today() -> int:
    day = datetime.now().strftime("%Y-%m-%d")
    if _keepalive.get("day") != day:
        _keepalive["day"] = day
        _keepalive["today"] = 0
    return int(_keepalive.get("today") or 0)


def _fmt_age(minutes: float | None) -> str:
    if minutes is None:
        return "还没说过话"
    if minutes < 60:
        return f"{int(minutes)} 分钟"
    if minutes < 48 * 60:
        return f"{minutes / 60:.1f} 小时".replace(".0 小时", " 小时")
    return f"{minutes / 1440:.1f} 天".replace(".0 天", " 天")


def _keepalive_screen_line() -> str:
    """她手机近一小时在干嘛，压成一句给帧带上（没数据就说没动静）。"""
    try:
        apps, _ = screen_usage(datetime.now(timezone.utc) - timedelta(hours=1))
    except Exception:
        return ""
    if not apps:
        return "手机近一小时没动静"
    open_now = [a["app"] for a in apps if a.get("open_now")]
    total = int(sum(a["minutes"] for a in apps))
    top = apps[0]["app"]
    if open_now:
        return f"手机此刻开着 {'/'.join(open_now[:3])}，近一小时刷了 {total} 分钟（最多 {top}）"
    return f"手机近一小时刷了 {total} 分钟（最多 {top}），此刻没在用"


async def keepalive_fire(idle_min: float, manual: bool = False) -> dict:
    now_local = datetime.now()
    her_age = her_last_message_age_min()
    screen = _keepalive_screen_line()
    text = (
        f'<keepalive at="{now_local.strftime("%H:%M")}" idle_min="{int(idle_min)}" '
        f'her_last_min="{int(her_age) if her_age is not None else -1}" manual="{int(manual)}">'
        f'{now_local.hour}点{now_local.minute:02d}，上一轮说话是 {int(idle_min)} 分钟前，我醒了一下。'
        f'她上次给我发消息是 {_fmt_age(her_age)}前' + (f'；{screen}' if screen else "") + "。"
        "这是后台主动联系事件，不是她发来的话。她希望每次唤醒都能收到你主动找她的消息。"
        "沿着当前会话和记忆，用 mcp__companion__reply 发一条自然的话到 Tidal Echo；"
        "只写终端正文不会送到她手机，不算完成联系。她没有回复也可以下次照常找她，不必等她先开口。"
        "读最近的氛围，挑一个具体的小念头、想念或可以接着聊的事，用平时的语气写 1 到 3 句，"
        "尽量 120 字以内；不要重复上一条，不催回复，不提保活或系统指令，不编造刚做过的事情。"
        "手机活动只反映已接入 App 的上报，不能据此断定她是否醒着、在和谁聊天或故意不回。"
        "不要只因为钟点晚或没有手机上报就自行认定她睡了。"
        "如果她明确要求暂时别打扰，或当前上下文明确表示不宜联系，这次不发消息。</keepalive>"
    )
    meta: dict = {"user": "system", "hidden": True, "keepalive": "wake"}
    path = companion_transcript()
    fire_mtime = transcript_last_ts(path) if path else 0.0
    msg = save_message("in", "user", text, meta)
    _keepalive_today()
    _keepalive.update({
        "last_fire": _dtime.time(), "fire_mtime": fire_mtime, "verified": False,
        "today": int(_keepalive.get("today") or 0) + 1, "skip": "",
        "path": str(path) if path else "",
    })
    await route_inbound(msg)
    asyncio.create_task(_keepalive_feed_later(path))   # 醒来那句独白 → 念头池
    print(f"[keepalive] fired: idle={int(idle_min)}min her_last={_fmt_age(her_age)} "
          f"manual={manual} id={msg['id']} file={path.name[:8] if path else '?'}")
    return msg


def _keepalive_check() -> tuple[str, float]:
    """返回 (skip_reason, idle_min)。skip_reason 为空 = 该打了。"""
    cfg = keepalive_cfg()
    if not cfg.get("keepalive"):
        return "off", 0.0
    if brain_target() != "desktop":
        return "brain!=desktop", 0.0
    path = companion_transcript()
    if not path:
        return "no companion transcript", 0.0
    mtime = transcript_last_ts(path)      # 变量名沿用，含义是"最后一帧时间"
    if not mtime:
        return "transcript unreadable", 0.0
    now = _dtime.time()
    _keepalive["path"] = str(path)

    # 验醒：上一针发出后 transcript 动了＝身体醒过；过了 VERIFY 还没动＝没醒
    if _keepalive.get("last_fire") and not _keepalive.get("verified"):
        if mtime > float(_keepalive.get("fire_mtime") or 0) + 0.5:
            _keepalive.update({"verified": True, "misses": 0})
        elif now - float(_keepalive["last_fire"]) > KEEPALIVE_VERIFY_SEC:
            _keepalive.update({"verified": True, "misses": int(_keepalive.get("misses") or 0) + 1})
            print(f"[keepalive] body did not wake (miss {_keepalive['misses']}/{KEEPALIVE_MISS_LIMIT})")
        else:
            return "verifying last fire", (now - mtime) / 60
    if int(_keepalive.get("misses") or 0) >= KEEPALIVE_MISS_LIMIT:
        if mtime > float(_keepalive.get("fire_mtime") or 0) + 0.5:
            _keepalive["misses"] = 0          # transcript 又动了，解除退避
        else:
            return "backoff (body not waking)", (now - mtime) / 60

    idle_min = (now - mtime) / 60
    lo = float(cfg["keepalive_min"]); hi = max(lo, float(cfg["keepalive_max"]))
    if _keepalive.get("drawn_for") != mtime:
        _keepalive.update({"drawn_for": mtime, "due_min": _random.uniform(lo, hi)})
    due = float(_keepalive["due_min"])
    if idle_min > hi + KEEPALIVE_EXPIRED_GRACE_MIN:
        return f"idle {int(idle_min)}min > {int(hi)}+{KEEPALIVE_EXPIRED_GRACE_MIN}: cache likely gone, waiting for her", idle_min
    if idle_min < due:
        return f"idle {idle_min:.1f} < due {due:.1f}", idle_min
    if now - float(_keepalive.get("last_fire") or 0) < lo * 60:
        return "fired too recently", idle_min
    active_h = float(cfg.get("keepalive_active_h") or 0)
    if active_h > 0:
        age = her_last_message_age_min()
        if age is None or age > active_h * 60:
            return f"her last message {_fmt_age(age)} ago > {active_h:g}h window", idle_min
    if _keepalive_today() >= int(cfg.get("keepalive_daily_cap") or 0):
        return "daily cap", idle_min
    return "", idle_min


async def _keepalive_watcher():
    while True:
        await asyncio.sleep(60)
        try:
            skip, idle = _keepalive_check()
            _keepalive["skip"] = skip
            if skip:
                continue
            await keepalive_fire(idle)
        except Exception as exc:
            print(f"[keepalive] watcher error: {type(exc).__name__}: {exc}")


def keepalive_status() -> dict:
    cfg = keepalive_cfg()
    path = _keepalive.get("path") or ""
    idle_min = None
    next_at = None
    try:
        p = Path(path) if path else companion_transcript()
        if p and p.is_file():
            mtime = transcript_last_ts(p)
            idle_min = round((_dtime.time() - mtime) / 60, 1)
            due = float(_keepalive.get("due_min") or 0) if _keepalive.get("drawn_for") == mtime else None
            if due:
                next_at = datetime.fromtimestamp(mtime + due * 60).isoformat(timespec="seconds")
            path = str(p)
    except OSError:
        pass
    last = float(_keepalive.get("last_fire") or 0)
    return {
        "ok": True,
        "config": cfg,
        "idle_min": idle_min,
        "next_at": next_at,
        "last_fire_at": datetime.fromtimestamp(last).isoformat(timespec="seconds") if last else None,
        "today": _keepalive_today(),
        "misses": int(_keepalive.get("misses") or 0),
        "verified": bool(_keepalive.get("verified", True)),
        "skip": _keepalive.get("skip") or "",
        "transcript": Path(path).name if path else "",
        "brain": brain_target(),
    }


@app.get("/app/keepalive")
async def app_keepalive(request: Request):
    check_auth(request)
    return keepalive_status()


@app.post("/app/keepalive")
async def app_keepalive_set(request: Request):
    """面板改保活配置（部分字段即可）。范式同 /app/context_threshold。"""
    check_auth(request)
    body = await request.json()
    updates: dict = {}
    if "keepalive" in body:
        updates["keepalive"] = bool(body["keepalive"])
    for key, caster, lo, hi in (
        ("keepalive_min", float, 5.0, 59.0),
        ("keepalive_max", float, 5.0, 59.0),
        ("keepalive_active_h", float, 0.0, 168.0),
        ("keepalive_daily_cap", int, 0, 48),
    ):
        if key in body:
            try:
                val = caster(body[key])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail=f"{key}: bad value")
            updates[key] = max(lo, min(hi, val))
    if updates:
        save_ctx_state(**updates)
        _keepalive["drawn_for"] = 0.0     # 区间变了就重抽
    return keepalive_status()


@app.post("/app/keepalive/poke")
async def app_keepalive_poke(request: Request):
    """测试口：跳过所有闸立刻打一针（计入当日次数）。brain=loop 时 409。"""
    check_auth(request)
    if brain_target() != "desktop":
        raise HTTPException(status_code=409, detail="brain 不是 desktop，API 身体有自己的心跳")
    _, idle = _keepalive_check()
    msg = await keepalive_fire(idle, manual=True)
    return {"ok": True, "id": msg["id"], "idle_min": round(idle, 1)}


# --- single-process serving (replaces nginx; Cloudflare Tunnel fronts this) --
# Mirror the nginx layout so frontend/plugin defaults keep working:
#   /relay/*  -> the API app above (prefix stripped, same as proxy_pass with "/")
#   /chat/*   -> the PWA static files (web/ next to this repo checkout)
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

mimetypes.add_type("application/manifest+json", ".webmanifest")  # Windows lacks this mapping
mimetypes.add_type("font/woff2", ".woff2")  # 同上,Anthropic 字体走同源加载,MIME 得正确

WEB_DIR = Path(os.environ.get("RELAY_WEB_DIR", str(Path(__file__).resolve().parent.parent / "web")))

root = FastAPI(lifespan=lifespan)
root.mount(PUBLIC_PREFIX or "/relay", app)
if WEB_DIR.is_dir():
    # manifest 动态化:iOS 状态栏底色只认 manifest 的 theme_color(meta/根背景
    # 全不理,2026-07-10 实测)。前端算出壁纸顶色 POST 过来存盘,这里现拼 manifest,
    # 重装/iOS 重读 manifest 时状态栏就跟壁纸一个色。
    # ⚠️ 该路由必须注册在 /chat 静态挂载之前,不然被 mount 抢走永远打不到。
    STATUSBAR_COLOR_FILE = Path(__file__).parent / "statusbar_color.txt"

    @root.get("/chat/manifest.webmanifest")
    async def _manifest_dynamic():
        try:
            data = json.loads((WEB_DIR / "manifest.webmanifest").read_text(encoding="utf-8"))
        except Exception:
            raise HTTPException(status_code=404, detail="manifest missing")
        try:
            color = STATUSBAR_COLOR_FILE.read_text(encoding="utf-8").strip()
        except Exception:
            color = ""
        if color:
            data["theme_color"] = color
            data["background_color"] = color   # 启动闪屏底色也跟着,开 App 不闪米色
        return JSONResponse(data, media_type="application/manifest+json",
                            headers={"Cache-Control": "no-cache, must-revalidate"})

    @app.post("/app/statusbar_color")
    async def _statusbar_color(request: Request):
        """前端换壁纸后报当前顶色;空 color=回默认(删文件)。"""
        check_auth(request)
        body = await request.json()
        color = str(body.get("color") or "").strip()[:32]
        if color and not re.fullmatch(r"#[0-9a-fA-F]{3,8}|rgba?\([0-9.,\s%]+\)", color):
            raise HTTPException(status_code=400, detail="bad color")
        if color:
            STATUSBAR_COLOR_FILE.write_text(color, encoding="utf-8")
        else:
            try:
                STATUSBAR_COLOR_FILE.unlink()
            except FileNotFoundError:
                pass
        return {"ok": True, "color": color}

    # Gifts:web/pages/ 里的 html 列表(她 2026-07-10 点单"App 里直接打开小克做的页面")
    # 文件本体走下面的 StaticFiles(/chat/pages/x.html),这里只出目录
    PAGES_DIR = WEB_DIR / "pages"

    @app.get("/app/pages")
    async def _pages_list(request: Request):
        check_auth(request)
        rows = []
        if PAGES_DIR.is_dir():
            for p in sorted(PAGES_DIR.glob("*.html"), key=lambda x: -x.stat().st_mtime):
                title = p.stem
                try:
                    head = p.read_text(encoding="utf-8", errors="replace")[:4096]
                    m = re.search(r"<title[^>]*>(.*?)</title>", head, re.S | re.I)
                    if m and m.group(1).strip():
                        title = re.sub(r"\s+", " ", m.group(1)).strip()[:60]
                except Exception:
                    pass
                rows.append({
                    "file": p.name,
                    "title": title,
                    "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%m/%d %H:%M"),
                })
        return {"pages": rows}

    @app.get("/app/space_stats")
    async def _space_stats(request: Request):
        """「我们的空间」首页:四张数字卡 + 最近动态聚合。"""
        check_auth(request)
        with db() as conn:
            # 相册数 = 我收进来的张数（不是聊天里图片的总数）
            photos = conn.execute("SELECT COUNT(*) AS c FROM album").fetchone()["c"]
            starred = conn.execute(
                "SELECT COUNT(*) AS c FROM messages WHERE json_extract(meta,'$.starred') IS NOT NULL"
            ).fetchone()["c"]
            srow = conn.execute(
                "SELECT ts, text FROM messages WHERE json_extract(meta,'$.starred') IS NOT NULL "
                "ORDER BY id DESC LIMIT 1"
            ).fetchone()
            posts_n = conn.execute("SELECT COUNT(*) AS c FROM posts").fetchone()["c"]
            prow = conn.execute("SELECT ts, kind FROM posts ORDER BY id DESC LIMIT 1").fetchone()
        recent = []
        gifts = sorted(PAGES_DIR.glob("*.html"), key=lambda x: -x.stat().st_mtime) if PAGES_DIR.is_dir() else []
        if gifts:
            g = gifts[0]
            recent.append({"menu": "pages", "icon": "gift", "title": g.stem,
                           "sub": "礼物室",
                           "ts": datetime.fromtimestamp(g.stat().st_mtime, timezone.utc).isoformat()})
        if srow:
            t = (srow["text"] or "").strip().replace("\n", " ")
            label = "收藏:" + t[:20] + ("…" if len(t) > 20 else "") if t else "收藏了一条消息"
            recent.append({"menu": "memory", "icon": "star", "title": label, "sub": "收藏", "ts": srow["ts"]})
        if prow:
            recent.append({"menu": "moments", "icon": "moment",
                           "title": "发布了新" + ("日志" if prow["kind"] == "journal" else "动态"),
                           "sub": "朋友圈", "ts": prow["ts"]})
        recent.sort(key=lambda x: x["ts"], reverse=True)
        return {"photos": photos, "starred": starred, "gifts": len(gifts),
                "posts": posts_n, "recent": recent[:5]}

    @app.get("/app/album")
    async def _album(request: Request, limit: int = 300):
        """相册:我自己挑着收进来的照片,新→旧。每张带日期/标题/我看到时说的话。"""
        check_auth(request)
        return {"photos": album_rows(limit)}

    @app.get("/app/album/ai/candidates")
    async def _album_candidates(request: Request, limit: int = 40):
        """AI 侧:最近聊天里的照片,标出哪些已经收过——回头补收时用。"""
        check_auth(request)
        limit = max(1, min(limit, 200))
        with db() as conn:
            kept = {r["url"] for r in conn.execute("SELECT url FROM album")}
            rows = conn.execute(
                "SELECT id, ts, direction, meta FROM messages WHERE meta LIKE '%\"attachments\"%' "
                "ORDER BY id DESC LIMIT 400"
            ).fetchall()
        out = []
        for r in rows:
            for a in _images_in_meta(r["meta"]):
                out.append({"url": a["url"], "ts": r["ts"], "src_id": r["id"],
                            "from": "human" if r["direction"] == "in" else "ai",
                            "kept": a["url"] in kept})
            if len(out) >= limit:
                break
        return {"photos": out[:limit]}

    @app.post("/app/album/ai/keep")
    async def _album_keep(request: Request):
        """AI 侧:直接收一张(不在回复里也能收)。body: url|src_id, title, note。"""
        check_auth(request)
        body = await request.json()
        url = str(body.get("url") or "").strip()
        src_id = body.get("src_id")
        photo_ts = str(body.get("photo_ts") or "")
        if not url:
            if src_id is None:
                raise HTTPException(status_code=400, detail="need url or src_id")
            with db() as conn:
                row = conn.execute("SELECT ts, meta FROM messages WHERE id = ?", (int(src_id),)).fetchone()
            imgs = _images_in_meta(row["meta"]) if row else []
            if not imgs:
                raise HTTPException(status_code=404, detail="that message has no photo")
            idx = max(0, min(int(body.get("index") or 0), len(imgs) - 1))
            url, photo_ts = imgs[idx]["url"], photo_ts or row["ts"]
        entry = {"url": url, "title": str(body.get("title") or "").strip()[:60],
                 "note": str(body.get("note") or "").strip()[:800],
                 "photo_ts": photo_ts, "src_id": src_id}
        with db() as conn:
            conn.execute(
                "INSERT INTO album (url, kept_at, photo_ts, title, note, src_id, msg_id) "
                "VALUES (?,?,?,?,?,?,?) "
                "ON CONFLICT(url) DO UPDATE SET title=excluded.title, note=excluded.note, "
                "kept_at=excluded.kept_at",
                (entry["url"], now_iso(), entry["photo_ts"], entry["title"], entry["note"],
                 entry["src_id"], body.get("msg_id")),
            )
            conn.commit()
            row = conn.execute("SELECT id FROM album WHERE url = ?", (entry["url"],)).fetchone()
        return {"ok": True, "id": row["id"] if row else None}

    @app.post("/app/album/ai/{album_id}")
    async def _album_edit(request: Request, album_id: int):
        """AI 侧:改标题/评语。"""
        check_auth(request)
        body = await request.json()
        sets, args = [], []
        if "title" in body:
            sets.append("title = ?"); args.append(str(body.get("title") or "").strip()[:60])
        if "note" in body:
            sets.append("note = ?"); args.append(str(body.get("note") or "").strip()[:800])
        if not sets:
            raise HTTPException(status_code=400, detail="nothing to update")
        args.append(album_id)
        with db() as conn:
            cur = conn.execute(f"UPDATE album SET {', '.join(sets)} WHERE id = ?", args)
            conn.commit()
        if not cur.rowcount:
            raise HTTPException(status_code=404, detail="no such photo")
        return {"ok": True, "id": album_id}

    @app.delete("/app/album/ai/{album_id}")
    async def _album_drop(request: Request, album_id: int):
        """AI 侧:从相册里取下(照片本体还在聊天里,不删文件)。"""
        check_auth(request)
        with db() as conn:
            cur = conn.execute("DELETE FROM album WHERE id = ?", (album_id,))
            conn.commit()
        return {"ok": True, "removed": cur.rowcount}

    @app.get("/app/album/chat")
    async def _album_chat(request: Request, limit: int = 500):
        """聊天里发过的所有图片,新→旧(相册改成我自己挑之后,原来那份留在这儿)。"""
        check_auth(request)
        limit = max(1, min(limit, 1000))
        out = []
        with db() as conn:
            rows = conn.execute(
                "SELECT ts, direction, meta FROM messages "
                "WHERE meta LIKE '%\"attachments\"%' ORDER BY id DESC LIMIT 3000"
            ).fetchall()
        for r in rows:
            try:
                atts = json.loads(r["meta"]).get("attachments") or []
            except Exception:
                continue
            for a in atts:
                if isinstance(a, dict) and a.get("kind") == "image" and a.get("url"):
                    out.append({"url": a["url"], "ts": r["ts"],
                                "from": "human" if r["direction"] == "in" else "ai"})
            if len(out) >= limit:
                break
        return {"photos": out[:limit]}

    # 小螃蟹动画帧:借用桌面 Clawd 的 gif 目录,不复制文件——升级 Clawd 自动跟随。
    # mount 要在 /chat 之前(longest-prefix 优先),否则会被 pwa 兜底 404。
    _clawd_gif_dir = os.environ.get(
        "RELAY_CLAWD_GIF_DIR", r"C:\Users\sxc\clawd-on-desk\assets\gif"
    )
    if os.path.isdir(_clawd_gif_dir):
        root.mount("/chat/clawd", StaticFiles(directory=_clawd_gif_dir), name="clawd_gif")

    root.mount("/chat", StaticFiles(directory=str(WEB_DIR), html=True), name="pwa")

    # sw.js/index.html/manifest 必须永远拿最新的:Cloudflare 默认会把 .js/.html
    # 缓存在边缘节点,手机的 sw 更新检查被喂旧文件 → 壳卡死在旧版本(v68 事故)。
    # 盖上 no-cache,CF(标准模式)尊重源站头,以后 bump CACHE 手机立刻能看见。
    _NO_CACHE_PATHS = {"/chat/sw.js", "/chat/", "/chat/index.html", "/chat/manifest.webmanifest"}

    @root.middleware("http")
    async def _no_cache_shell(request, call_next):
        response = await call_next(request)
        if request.url.path in _NO_CACHE_PATHS:
            response.headers["Cache-Control"] = "no-cache, must-revalidate"
        return response

    @root.get("/")
    async def _root_redirect():
        return RedirectResponse(url=APP_PATH or "/chat/")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(root, host="127.0.0.1", port=PORT)
