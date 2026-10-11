"""
ombre Dashboard 代理：让她在 App 里翻我的记忆库。

ombre 的 Dashboard API 只认 /auth/login 换来的 ombre_session cookie（Bearer 不行），
所以由 relay 拿着密码替手机登录、缓存 cookie、过期自动重登——密码只躺在 relay.env，
手机端永远只见到 RELAY_SECRET。思路抄自 Bunny & Elliott 的「Dashboard 接入前端」教程，
从 Node 改写成这里的 httpx。

只读。钉选/归档/删除这类动作不开到手机上：记忆是我自己用 MCP 工具管的。

env:
  OMBRE_DASHBOARD_URL       默认取 RECALL_URL 的 origin（同一台 hazel.zeabur.app）
  OMBRE_DASHBOARD_PASSWORD  Dashboard 登录密码（= Zeabur 上 PASSWORD 那个变量）
  OMBRE_DASHBOARD_TIMEOUT   秒，默认 10
"""
from __future__ import annotations

import asyncio
import os
import re
import urllib.parse

import httpx


def _default_url() -> str:
    explicit = os.environ.get("OMBRE_DASHBOARD_URL", "").strip()
    if explicit:
        return explicit.rstrip("/")
    recall_url = os.environ.get("RECALL_URL", "").strip()
    if recall_url:
        parts = urllib.parse.urlsplit(recall_url)
        if parts.scheme and parts.netloc:
            return f"{parts.scheme}://{parts.netloc}"
    return ""


DASHBOARD_URL = _default_url()
DASHBOARD_PASSWORD = os.environ.get("OMBRE_DASHBOARD_PASSWORD", "")
TIMEOUT = float(os.environ.get("OMBRE_DASHBOARD_TIMEOUT", "10"))


class DashError(Exception):
    """code: not_configured / auth_not_configured / auth_failed / upstream / unavailable"""

    def __init__(self, code: str, detail: str = "", status: int | None = None):
        super().__init__(detail or code)
        self.code = code
        self.status = status


_client: httpx.AsyncClient | None = None
_session_cookie = ""
_login_lock = asyncio.Lock()


def configured() -> bool:
    return bool(DASHBOARD_URL)


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        # 不让 httpx 自己存 cookie：会话只认 _session_cookie 这一份，重登时好整个替换
        _client = httpx.AsyncClient(
            timeout=TIMEOUT,
            limits=httpx.Limits(keepalive_expiry=600),
            follow_redirects=False,
        )
    return _client


def _capture_cookie(resp: httpx.Response) -> None:
    global _session_cookie
    token = resp.cookies.get("ombre_session")
    if token:
        _session_cookie = token


async def _login(stale: str) -> None:
    global _session_cookie
    async with _login_lock:
        # 排队期间别的请求已经重登过了，就直接用新的
        if _session_cookie and _session_cookie != stale:
            return
        if not DASHBOARD_PASSWORD:
            raise DashError("auth_not_configured", "relay.env 里没有 OMBRE_DASHBOARD_PASSWORD")
        try:
            resp = await _get_client().post(
                f"{DASHBOARD_URL}/auth/login", json={"password": DASHBOARD_PASSWORD}
            )
        except httpx.HTTPError as e:
            raise DashError("unavailable", f"login: {type(e).__name__}") from e
        if resp.status_code >= 400:
            raise DashError("auth_failed", f"login HTTP {resp.status_code}", resp.status_code)
        _session_cookie = ""
        _capture_cookie(resp)
        if not _session_cookie:
            raise DashError("auth_failed", "login 没有下发 ombre_session")


async def request(path: str, params: dict | None = None, _retried: bool = False, timeout: float | None = None):
    if not configured():
        raise DashError("not_configured", "没有 OMBRE_DASHBOARD_URL / RECALL_URL")
    if not _session_cookie:
        await _login("")
    sent = _session_cookie
    try:
        resp = await _get_client().get(
            f"{DASHBOARD_URL}{path}",
            params=params,
            cookies={"ombre_session": sent},
            timeout=timeout or TIMEOUT,
        )
    except httpx.HTTPError as e:
        raise DashError("unavailable", f"{path}: {type(e).__name__}") from e
    if resp.status_code == 401 and not _retried:
        await _login(sent)
        return await request(path, params, _retried=True, timeout=timeout)
    if resp.status_code == 401:
        raise DashError("auth_failed", f"{path} 重登后仍 401", 401)
    if resp.status_code == 404:
        raise DashError("not_found", path, 404)
    if resp.status_code >= 400:
        raise DashError("upstream", f"{path} HTTP {resp.status_code}", resp.status_code)
    # ombre 对不存在的路径回 200 + 纯文本 "Not Found"（见 auto-recall 的坑），别当 JSON 硬解
    try:
        return resp.json()
    except ValueError as e:
        raise DashError("upstream", f"{path} 返回的不是 JSON") from e


def http_status(err: DashError) -> int:
    return {
        "not_configured": 503,
        "auth_not_configured": 503,
        "not_found": 404,
    }.get(err.code, 502)


# --- 规整 -------------------------------------------------------------------

_WIKILINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


def _strip_wikilinks(text: str) -> str:
    return _WIKILINK.sub(lambda m: m.group(2) or m.group(1), text)


def _list(value) -> list[str]:
    if isinstance(value, list):
        return [str(v) for v in value if str(v).strip()]
    if isinstance(value, str):
        return [s.strip() for s in value.split(",") if s.strip()]
    return []


def _num(*values) -> float | None:
    for v in values:
        if v is None or v == "":
            continue
        try:
            n = float(v)
        except (TypeError, ValueError):
            continue
        return n
    return None


def _bool(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes", "on")
    return bool(value)


def normalize(bucket: dict) -> dict:
    """列表项、搜索项、详情三种形状统一成一种。详情的字段都在 metadata 里。"""
    meta = bucket.get("metadata") or bucket.get("meta") or {}
    content = str(bucket.get("display_content") or bucket.get("content") or "")
    if content and not bucket.get("display_content"):
        content = _strip_wikilinks(content)
    preview = str(bucket.get("content_preview") or content)
    importance = _num(bucket.get("importance"), meta.get("importance"))
    activation = _num(bucket.get("activation_count"), meta.get("activation_count"))
    domains = _list(bucket.get("domain") or meta.get("domain"))
    # 同一个词常常既是 domain 又是 tag（「恋爱」），前端是两个拼起来显示的，这里先去重
    tags = list(dict.fromkeys(t for t in _list(bucket.get("tags") or meta.get("tags")) if t not in domains))
    return {
        "id": str(bucket.get("id") or ""),
        "name": str(bucket.get("name") or meta.get("name") or bucket.get("id") or ""),
        "type": str(bucket.get("type") or meta.get("type") or "dynamic"),
        "content": content,
        # Full details, not list previews, are required for quota-based breath.
        "raw_content": str(bucket.get("content") or "") if isinstance(bucket.get("metadata"), dict) else "",
        "surfacing_policy_version": 1 if isinstance(bucket.get("metadata"), dict) else 0,
        "protected": _bool(bucket.get("protected", meta.get("protected"))),
        "anchor": _bool(bucket.get("anchor", meta.get("anchor"))),
        "dont_surface": _bool(bucket.get("dont_surface", meta.get("dont_surface"))),
        "tombstone": _bool(bucket.get("tombstone", meta.get("tombstone"))),
        "archived": _bool(bucket.get("archived", meta.get("archived"))),
        "deleted_at": str(bucket.get("deleted_at") or meta.get("deleted_at") or ""),
        "preview": re.sub(r"\s+", " ", preview).strip()[:160],
        "domains": domains,
        "tags": tags,
        "importance": int(max(0, min(10, round(importance)))) if importance is not None else 5,
        "valence": _num(bucket.get("valence"), meta.get("valence")),
        "arousal": _num(bucket.get("arousal"), meta.get("arousal")),
        "pinned": _bool(bucket.get("pinned", meta.get("pinned"))),
        "resolved": _bool(bucket.get("resolved", meta.get("resolved"))),
        "activation_count": int(activation or 0),
        "why_remembered": str(bucket.get("why_remembered") or meta.get("why_remembered") or ""),
        "created": str(bucket.get("created") or meta.get("created") or ""),
        "last_active": str(bucket.get("last_active") or meta.get("last_active") or ""),
        "score": _num(bucket.get("score")),
    }


# --- 全表缓存 -----------------------------------------------------------------
# ombre 的 /api/buckets 在 Zeabur 上要 25–45 秒才吐完（09-24 实测，345 桶），
# 手机上每开一次记忆页就干等半分钟。这里存一份规整好的全表：
# 有就先给旧的，旧了在后台换新的（同一时刻只刷一次），relay 重启从磁盘接着用。

import json  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

CACHE_FRESH_SEC = float(os.environ.get("OMBRE_DASHBOARD_CACHE_SEC", "180"))
_CACHE_FILE = Path(__file__).with_name("ombre_buckets_cache.json")
_cache_items: list[dict] | None = None
_cache_at = 0.0
_refresh_task: asyncio.Task | None = None


def _load_disk_cache() -> None:
    global _cache_items, _cache_at
    try:
        blob = json.loads(_CACHE_FILE.read_text(encoding="utf-8"))
        _cache_items = [i for i in blob.get("items", []) if isinstance(i, dict)]
        _cache_at = float(blob.get("at") or 0)
    except (OSError, ValueError):
        pass


async def _refresh_all() -> list[dict]:
    global _cache_items, _cache_at
    data = await request("/api/buckets", {"sort": "score"}, timeout=90)
    raw = data if isinstance(data, list) else (data.get("buckets") or data.get("items") or [])
    items = [normalize(b) for b in raw if isinstance(b, dict)]
    _cache_items, _cache_at = items, time.time()
    try:
        tmp = _CACHE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps({"at": _cache_at, "items": items}, ensure_ascii=False), encoding="utf-8")
        tmp.replace(_CACHE_FILE)
    except OSError as e:
        print(f"[ombre-dash] 缓存落盘失败: {e}", flush=True)
    return items


def _kick_refresh() -> asyncio.Task:
    global _refresh_task
    if _refresh_task is None or _refresh_task.done():
        _refresh_task = asyncio.create_task(_refresh_all())
        _refresh_task.add_done_callback(
            lambda t: t.cancelled() or not t.exception()
            or print(f"[ombre-dash] 后台刷新失败: {t.exception()}", flush=True)
        )
    return _refresh_task


async def all_buckets(force: bool = False) -> list[dict]:
    """规整好的全表。有缓存就立刻给（旧了顺手后台刷新）；一份都没有才等上游。"""
    if _cache_items is None:
        _load_disk_cache()
    if _cache_items is not None:
        if force or time.time() - _cache_at > CACHE_FRESH_SEC:
            _kick_refresh()
        return _cache_items
    return await asyncio.shield(_kick_refresh())


def cache_age() -> float | None:
    return time.time() - _cache_at if _cache_items is not None else None
