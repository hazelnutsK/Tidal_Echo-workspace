#!/usr/bin/env python3
"""recall —— 每轮自动浮现:她说一句话,相关的旧记忆自己浮到我眼前。

跟 MCP 的 breath 工具是两回事。MCP 工具要我先想起「该查一下记忆」才会被调用,
可聊天里没人会先翻日记本再开口——所以那条路上,记忆总是想不起来。这个模块把浮现
搬到我开口之前:relay 在把她的消息递给我时,已经把相关旧记忆垫在下面了。

她看不到(库里的 text 保持干净,手机上不显示),我也不用决定要不要查。

两道闸,位置不同:
  闸一(本地判,零延迟) —— 这句话值不值得查。短消息/纯图片/剥完停用词没剩东西的
      都在这里被拦下,一秒都不用等。
  闸二(拿到候选之后) —— 查到了也不一定浮。冷却挡掉刚浮过的,条数阶梯按消息长短
      给名额,近重的合并,最后按 U 型重排。

冷却是这里最要紧的一条:连着聊同一个话题时,每条消息命中的都是同一批记忆,没有
冷却就是同一段话在我眼前刷五遍——自动浮现会死在这上面,不是死在检索不准上。

服务端只做无状态检索(ombre 的 /api/recall);浮沉状态全在这边的 recall_state 表里,
不碰 ombre 的数据。真正浮到眼前的那几条才回调 /api/recall/confirm 加固——被冷却
丢掉的不算被想起,不该加固。
"""

import asyncio
import json
import os
import random
import re
import sqlite3
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

# --- config (env) -----------------------------------------------------------
RECALL_URL = os.environ.get("RECALL_URL", "").rstrip("/")
RECALL_TOKEN = os.environ.get("RECALL_TOKEN", "").strip()
# 2.0s:超过这个数她就该觉得我"卡了一下"才开口。实测 RTT 0.28s(连接复用后)+
# 服务端检索 0.5~2.1s,这个预算能接住大多数,慢的那次就当没想起来——
# 宁可不浮也不让她等。
RECALL_TIMEOUT = float(os.environ.get("RECALL_TIMEOUT", "2.0"))
RECALL_NOUNS_FILE = Path(
    os.environ.get("RECALL_NOUNS_FILE", str(Path(__file__).parent / "recall_nouns.json"))
)
# 召回日志保留天数。诊断数据,不是记忆本身——留够调参就行。
RECALL_LOG_DAYS = int(os.environ.get("RECALL_LOG_DAYS", "14"))

# --- 影子模式(2026-08-31 上线,止血用)-------------------------------------
# 人工标注 30 条浮现的结论:严格精度 **0/30**,其中 12 条被判「不该浮」(会引起
# 误会或尴尬)。同一批 20 轮的 omission 是 0/20——闸一没挡过头,问题全在浮出来的
# 那些是噪音。所以先停注入。
#
# 但**不能用 RECALL_ENABLED=0 那种全关**:全关就既不检索也攒不到标定数据,
# 等于用一周换零信息。影子模式照常检索、照常过滤、把整池候选连同分车道原始分
# 落库,只是**不注入、不加固、不动任何状态**,最终返回空前缀。
RECALL_SHADOW = os.environ.get("RECALL_SHADOW", "").strip().lower() in ("1", "true", "yes", "on")

# 加固回路的开关,**默认关**。
# 浮出来的那几条会回调 /api/recall/confirm,ombre 那边走 touch 语义:刷新
# last_active、累加 activation_count。而这两个正是打分的输入(time 权重 1.5、
# touch 权重 1.0,合计占总分 18.5%)——于是「被浮过」本身成了「更容易再被浮」的
# 理由,形成正反馈。实测日志里每一条浮出来的卡都是 touch=1.0、time≈0.984,
# 两维双双饱和;123 次浮现里 8 个条目占 62%。在精度 0% 的前提下,这个回路
# 每转一圈都在加固噪音。精度重新标定为正之前不许打开。
RECALL_CONFIRM = os.environ.get("RECALL_CONFIRM", "").strip().lower() in ("1", "true", "yes", "on")

# 影子轮次多要一些候选、也多要一些正文:这批数据是拿来离线重排和人工标注的,
# 省字节等于省掉证据。注意服务端返回的**不是完整候选池**,而是过完它自己准入
# (normalized ≥ fuzzy_threshold 50 或 literal 命中;纯语义要 ≥ 0.65)之后的
# 幸存者——叫它 server_survivor_pool 才准确。服务端漏掉的记忆在这批数据里
# 永远看不见,那要等 ombre 出 diagnostic 模式(各车道 top-K 取并集)才补得上。
_SHADOW_MAX_RESULTS = 20
_SHADOW_MAX_CHARS = 20000

# 影子采集**不在投递路径上**,所以 2.0s 那个预算在这里没有意义——它是"别让她等"
# 的预算,而影子根本不让她等。继续用 2s 只会把慢的那些截断成 fetch_failed,
# 于是数据里既看不到服务端真实的耗时分布,也分不清"服务端挂了"和"我没耐心"。
# 9s 是为了盖住 ombre 自己的 8s 内部预算:超过它才是真的没查成。
RECALL_SHADOW_TIMEOUT = float(os.environ.get("RECALL_SHADOW_TIMEOUT", "9.0"))

# 同时最多几个影子采集在途。放开会有两个后果:她连着说几句时后台堆起一串 9s 的
# 请求(每个占一条连接),以及把 ombre 撞出 429。丢掉的那些**必须记一行**
# (skipped=shadow_busy)——不记的话分母悄悄变小,可靠性统计会偏乐观。
_SHADOW_MAX_INFLIGHT = 1
_shadow_inflight = 0
# 持任务引用:asyncio 只保弱引用,不持着的话正在跑的采集可能被 GC 掉
_shadow_tasks: set = set()

_HAN = re.compile(r"[一-鿿]")
_ASCII_WORD = re.compile(r"[A-Za-z]{2,}")

# 剥掉这些再看还剩多少实质内容。命中它们等于噪音:"你知道吗"「几点了」检索出来的
# 只会是随机的旧事。名单参考 Non 的停用词思路,按我们实际聊天的高频虚词补过。
_STOPWORDS = (
    "什么", "知道", "怎么", "为什么", "可以", "这样", "那样", "这个", "那个",
    "现在", "刚才", "今天", "明天", "昨天", "早上", "中午", "下午", "晚上",
    "时候", "记得", "觉得", "感觉", "应该", "可能", "已经", "还是", "但是",
    "所以", "因为", "如果", "然后", "而且", "就是", "真的", "有点", "一点",
    "好像", "其实", "反正", "居然", "竟然", "确实", "当然", "肯定",
    "哈哈", "嘿嘿", "嘻嘻", "呜呜", "晚安", "早安", "在吗", "好吧", "行吧",
    "几点", "多久", "多少", "哪里", "哪儿", "没有", "有没有", "是不是",
)
_TIME_NOISE = re.compile(r"\d+\s*(点|分|秒|号|月|日|年|岁|个|次|遍|小时|分钟)")
# 单字虚词:剥掉才看得出一句话到底有没有实质内容。"你几点了吗"剥完是空的,
# "我今天买了只猫杯子"剥完还剩"买只猫杯子"——差别就在这里。
_PARTICLES = re.compile(r"[的了吗呢吧啊哦嗯呀嘛么你我他她它们这那是有在和跟把被就都还也很太不没要会能]")

# 闸一门槛
_MIN_HAN_TO_QUERY = 6        # 少于这个字数不查(「嗯」「好的」「哈哈哈」)
_MIN_HAN_AFTER_STRIP = 4     # 剥完停用词还剩这么多才算有实质内容
_QUERY_MAX_CHARS = 500

# 闸二:条数阶梯——短消息浮少一点,长消息才配多浮几条
_LADDER = ((15, 3), (30, 5))
_LADDER_MAX = 8

# 冷却:基础 30min,surface_count 每 +5 再加 30min,上限 3h。pinned 不冷却。
_COOLDOWN_BASE_SEC = 30 * 60
_COOLDOWN_STEP_SEC = 30 * 60
_COOLDOWN_STEP_EVERY = 5
_COOLDOWN_MAX_SEC = 3 * 60 * 60

# 近重合并:本次浮起的几条之间,6-gram 重叠超过这个比例就只留前面那条
_NEAR_DUP_RATIO = 0.6
_NGRAM = 6


def enabled() -> bool:
    return bool(RECALL_URL and RECALL_TOKEN)


def shadow() -> bool:
    """影子模式:检索照跑、数据照攒,但一个字都不注入。"""
    return RECALL_SHADOW


# ---------------------------------------------------------------------------
# 浮现徽章 —— 让她在手机上看得见「这轮我想起了东西」
#
# 浮现本身是隐形的:记忆垫在我眼前,她那边什么都看不到。这个状态位让 thinking
# 卡片能显示一行「浮现 N 条」——她不用猜我是不是真的记得。
#
# 按 msg_id 认轮次(跟 _think_anchor 同一套口径):她连发两条、只有第一条浮了
# 记忆时,徽章不会错贴到第二条那轮的思维卡上。取走即消费,不重复显示。
# ---------------------------------------------------------------------------
_badge = {"msg_id": None, "count": 0, "at": 0.0}
_badge_lock = threading.Lock()
_BADGE_TTL_SEC = 600


def note_recall(msg_id, count: int) -> None:
    if not msg_id or count <= 0:
        return
    with _badge_lock:
        _badge.update(msg_id=msg_id, count=int(count),
                      at=datetime.now(timezone.utc).timestamp())


def take_badge(msg_id) -> int:
    """取走某轮的浮现条数(取一次就没了)。不是那轮/过期了都返回 0。"""
    if not msg_id:
        return 0
    with _badge_lock:
        if _badge["msg_id"] != msg_id or _badge["count"] <= 0:
            return 0
        if datetime.now(timezone.utc).timestamp() - _badge["at"] > _BADGE_TTL_SEC:
            return 0
        count = _badge["count"]
        _badge["count"] = 0
        return count


# ---------------------------------------------------------------------------
# 名词白名单 —— 人名 / 猫名 / 地名之类有特殊分量的词
#
# 提到这些词时:① 即使消息很短也查;② 结果洗牌后随机取,而不是按相关度取前 N。
# 洗牌是关键——不然每次提到同一个名字,浮上来的永远是同样那几条,几天就腻了。
# ---------------------------------------------------------------------------
def load_nouns() -> list[str]:
    try:
        data = json.loads(RECALL_NOUNS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if isinstance(data, dict):
        data = data.get("nouns") or []
    return [str(w).strip() for w in data if str(w or "").strip()][:200]


# 紧跟在数字后面的不算命中:「十九」是猫,「二十九度」「一百一十九」不是。
# 白名单命中会触发洗牌(随机取代替按相关度取),误命中的代价是浮出来的东西变不相关,
# 比多查一次严重——所以宁可漏,不可错。
_NUM_CHARS = set("0123456789零〇一二三四五六七八九十百千万两几第")


def matched_nouns(text: str) -> list[str]:
    lowered = text.lower()
    hits = []
    for word in load_nouns():
        needle = word.lower()
        start = lowered.find(needle)
        while start >= 0:
            if start == 0 or lowered[start - 1] not in _NUM_CHARS:
                hits.append(word)
                break
            start = lowered.find(needle, start + 1)
    return hits


# ---------------------------------------------------------------------------
# 闸一:这句话值不值得查
# ---------------------------------------------------------------------------
def build_query(text: str, kind: str, meta: dict | None = None) -> tuple[str | None, str]:
    """→ (要检索的原文, 跳过原因)。query 为 None 时原因非空。

    query 直接用原文——服务端有 jieba + BM25 + 向量融合,比我在这边自己切词强。
    这里只负责判断「查不查」,并且**说清楚为什么不查**:光看"这轮没浮"没法调参,
    得知道是被哪道门槛拦的。
    """
    if kind not in ("user", "voice"):
        return None, "not_her_message"
    # 系统帧(desire-pulse/night-watch/moments-event/timer-event/ask-event/
    # calendar-remind/garden-wake/reading-event/reply-missing)也是 kind="user"
    # 落的库,只有 meta.user 能把它们跟她本人的话分开。它们不是她说的话,拿
    # `<reply-missing message_id="10773" …>` 去检索只会捞回一堆无关旧事——
    # 日志里真发生过,那一次浮了 8 条。认 meta 而不是认帧名:以后加新帧自动覆盖。
    if (meta or {}).get("user") == "system":
        return None, "system_frame"
    text = (text or "").strip()
    if not text:
        return None, "empty"

    # 纯附件 / 纯表情 / 纯数字:没有可检索的语义
    if not _HAN.search(text) and not _ASCII_WORD.search(text):
        return None, "no_searchable_text"

    nouns = matched_nouns(text)
    han_count = len(_HAN.findall(text))
    if han_count < _MIN_HAN_TO_QUERY and not nouns:
        return None, "too_short"

    if not nouns:
        stripped = _TIME_NOISE.sub("", text)
        for word in _STOPWORDS:
            stripped = stripped.replace(word, "")
        stripped = _PARTICLES.sub("", stripped)
        if len(_HAN.findall(stripped)) < _MIN_HAN_AFTER_STRIP and not _ASCII_WORD.search(stripped):
            return None, "stopwords_only"

    return text[:_QUERY_MAX_CHARS], ""


def slot_count(text: str) -> int:
    han = len(_HAN.findall(text or ""))
    for threshold, slots in _LADDER:
        if han < threshold:
            return slots
    return _LADDER_MAX


# ---------------------------------------------------------------------------
# 冷却状态 —— 只在 relay 这边记,不碰 ombre 的桶
# ---------------------------------------------------------------------------
def init_db(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recall_state (
            bucket_id     TEXT PRIMARY KEY,
            last_surfaced TEXT NOT NULL,
            surface_count INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    # 召回日志:每一轮的完整决策链,给调门控用。
    # 光知道「浮了几条」没法判断参数对不对——要看的是**在哪一步被砍掉的**:
    # 闸一拦太多说明停用词表过激;冷却砍太多说明冷却期太长;候选够多但最终浮得少
    # 说明近重合并太狠。所以每一级的数量都单独记一列。
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recall_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT NOT NULL,
            msg_id     INTEGER,
            query      TEXT NOT NULL DEFAULT '',
            skipped    TEXT NOT NULL DEFAULT '',   -- 非空 = 没查,值是原因
            nouns      TEXT NOT NULL DEFAULT '',   -- 命中的白名单词,逗号分隔
            slots      INTEGER NOT NULL DEFAULT 0, -- 条数阶梯给的名额
            candidates INTEGER NOT NULL DEFAULT 0, -- 服务端回了几条
            after_cool INTEGER NOT NULL DEFAULT 0, -- 过完冷却剩几条
            after_dedup INTEGER NOT NULL DEFAULT 0,-- 过完近重合并剩几条
            surfaced   INTEGER NOT NULL DEFAULT 0, -- 最终浮了几条
            elapsed_ms INTEGER NOT NULL DEFAULT 0,
            degraded   TEXT NOT NULL DEFAULT '',   -- semantic_unavailable 等
            cards      TEXT NOT NULL DEFAULT '[]'  -- 浮起那几条的 id/name/score/semantic
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recall_log_ts ON recall_log(ts)")
    # 后加的列。**degraded 和 failure 是两件事,混在一起会把故障读成"库里没有"**:
    #   degraded = 服务端自报的降级(如向量通道挂了走 BM25)——**有结果**,只是打了折
    #   failure  = relay 压根没拿到结果(超时/网络/5xx)——**无结果**
    # 「向量挂了 + BM25 也没找到相关的」是 degraded 非空但确实 no_candidates,
    # 靠 degraded 反推故障会把这种情况误判成故障。
    for col, decl in (
        ("failure", "TEXT NOT NULL DEFAULT ''"),
        ("trace_id", "TEXT NOT NULL DEFAULT ''"),   # 跟服务端日志对帐用
        ("timings", "TEXT NOT NULL DEFAULT '{}'"),  # 服务端分段耗时 JSON
        # --- 影子模式(2026-08-31)---------------------------------------
        # **surfaced 这一列的语义不许改**:它始终是「真的注入给模型几条」。
        # 影子轮次一律写 0,想知道"当时本来会浮几条"看 would_surface。
        # 混写会把统计污染掉——精度分母里混进从没被人看见的轮次,
        # 而那正是这次要测的东西。
        ("shadow", "INTEGER NOT NULL DEFAULT 0"),            # 1 = 影子轮次
        ("would_surface", "INTEGER NOT NULL DEFAULT 0"),     # 影子下"本来会浮几条"
        # 服务端回了几条(= candidates,但显式留一列:candidates 在只读路径上
        # 语义容易漂,这一列固定指"过完服务端准入之后交到 relay 手里的条数")
        ("server_candidates", "INTEGER NOT NULL DEFAULT 0"),
        # **整池快照,冷却/近重/名额三刀之前**。这是影子模式唯一真正的产出:
        # 只存活下来的那几条(cards 列)等于只存了旧排序的结论,拿它调排序是
        # 循环论证。要离线重排就必须有被砍掉的那些。
        ("pool", "TEXT NOT NULL DEFAULT '[]'"),
        # 影子用 9s 预算,所以"成功"里混着一批**将来实时时会超时**的。这一列把
        # 它们标出来:1 = 这轮虽然查成了,但耗时超过实时预算(RECALL_TIMEOUT)。
        # 没有它,影子期的成功率会系统性地比真实上线后好看。
        ("miss_live_budget", "INTEGER NOT NULL DEFAULT 0"),
    ):
        try:
            conn.execute(f"ALTER TABLE recall_log ADD COLUMN {col} {decl}")
        except sqlite3.OperationalError:
            pass  # 已经有了


def _card_row(card: dict) -> dict:
    """一条卡在日志里的样子。cards 和 pool 必须用同一个形状——两边字段不一样的话,
    离线重排时「存活的」和「被砍的」就没法放进同一张表比。"""
    return {
        "id": card.get("id"),
        "name": card.get("name"),
        "score": card.get("score"),
        "semantic": card.get("semantic"),
        "vec": bool(card.get("vector_match")),
        "drift": bool(card.get("drift")),
        # 分车道原始证据(ombre 2026-08-30 起返回)。定绝对支持门
        # 全靠它——score 是排序分,过门要看这里的绝对值。
        "parts": card.get("score_parts") or {},
        # **完整正文,不截断**——存的必须正好是这轮注入给我的
        # 那些字。人工裁决判的是「模型当时看到这段,该不该浮」,
        # 少存一个字,标注看到的就是另一份材料。
        # 更要紧的是别事后回补:记忆会被 grow 合并/手工编辑,而
        # ombre 的 metadata 没有内容修改时间戳(只有 created/
        # last_active,后者召回也会 bump),事后取回的是「现在这版」,
        # 无从判断跟当时是否一致。当场存下就没有这个问题。
        # 日志只留 14 天,这点体积不心疼。
        "text": str(card.get("content") or ""),
    }


def log_round(conn: sqlite3.Connection, **row) -> None:
    """记一轮召回的决策链。日志写不进去绝不能影响浮现本身。"""
    try:
        cards = row.get("cards") or []
        pool = row.get("pool") or []
        is_shadow = bool(row.get("shadow"))
        # 影子轮次一个字都没进模型,surfaced 必须是 0;"本来会浮几条"另记一列。
        survived = len(cards)
        # 整池快照里标出哪些活到了最后,离线重排要靠它对齐旧结论
        kept = {c.get("id") for c in cards if c.get("id")}
        pool_rows = []
        for card in pool:
            entry = _card_row(card)
            entry["would"] = entry["id"] in kept
            pool_rows.append(entry)
        conn.execute(
            """
            INSERT INTO recall_log (
                ts, msg_id, query, skipped, nouns, slots, candidates,
                after_cool, after_dedup, surfaced, elapsed_ms, degraded, cards,
                failure, trace_id, timings,
                shadow, would_surface, server_candidates, pool, miss_live_budget
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                datetime.now(timezone.utc).isoformat(),
                row.get("msg_id"),
                str(row.get("query") or "")[:500],
                str(row.get("skipped") or ""),
                ",".join(row.get("nouns") or []),
                int(row.get("slots") or 0),
                int(row.get("candidates") or 0),
                int(row.get("after_cool") or 0),
                int(row.get("after_dedup") or 0),
                0 if is_shadow else survived,
                int(row.get("elapsed_ms") or 0),
                str(row.get("degraded") or ""),
                json.dumps([_card_row(c) for c in cards], ensure_ascii=False),
                str(row.get("failure") or ""),
                str(row.get("trace_id") or ""),
                json.dumps(row.get("timings") or {}, ensure_ascii=False),
                1 if is_shadow else 0,
                survived if is_shadow else 0,
                int(row.get("server_candidates") or row.get("candidates") or 0),
                json.dumps(pool_rows, ensure_ascii=False),
                1 if row.get("miss_live_budget") else 0,
            ),
        )
        conn.commit()
    except sqlite3.Error as exc:
        print(f"[recall] log failed: {type(exc).__name__}: {exc}")


def prune_log(conn: sqlite3.Connection) -> int:
    """只留最近 RECALL_LOG_DAYS 天——这是诊断数据,不是需要长期保存的记忆。"""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=RECALL_LOG_DAYS)).isoformat()
    cur = conn.execute("DELETE FROM recall_log WHERE ts < ?", (cutoff,))
    conn.commit()
    return cur.rowcount or 0


def _cooldown_seconds(surface_count: int) -> int:
    steps = max(0, int(surface_count)) // _COOLDOWN_STEP_EVERY
    return min(_COOLDOWN_MAX_SEC, _COOLDOWN_BASE_SEC + steps * _COOLDOWN_STEP_SEC)


def _is_cooling(row: sqlite3.Row | None, now_ts: float) -> bool:
    if row is None:
        return False
    try:
        last = datetime.fromisoformat(row["last_surfaced"]).timestamp()
    except (TypeError, ValueError):
        return False
    return (now_ts - last) < _cooldown_seconds(row["surface_count"])


def filter_cooling(conn: sqlite3.Connection, cards: list[dict]) -> list[dict]:
    """挡掉刚浮过的。pinned 不受冷却约束——核心准则本来就该常在。"""
    ids = [c["id"] for c in cards if c.get("id")]
    if not ids:
        return []
    now_ts = datetime.now(timezone.utc).timestamp()
    placeholders = ",".join("?" * len(ids))
    rows = {
        row["bucket_id"]: row
        for row in conn.execute(
            f"SELECT * FROM recall_state WHERE bucket_id IN ({placeholders})", ids
        )
    }
    return [
        c for c in cards
        if c.get("pinned") or not _is_cooling(rows.get(c["id"]), now_ts)
    ]


def mark_surfaced(conn: sqlite3.Connection, cards: list[dict]) -> None:
    now = datetime.now(timezone.utc).isoformat()
    for card in cards:
        conn.execute(
            """
            INSERT INTO recall_state (bucket_id, last_surfaced, surface_count)
            VALUES (?, ?, 1)
            ON CONFLICT(bucket_id) DO UPDATE SET
                last_surfaced = excluded.last_surfaced,
                surface_count = recall_state.surface_count + 1
            """,
            (card["id"], now),
        )
    conn.commit()


# ---------------------------------------------------------------------------
# 闸二:近重合并 + U 型重排
# ---------------------------------------------------------------------------
def _ngrams(text: str, n: int = _NGRAM) -> set[str]:
    compact = re.sub(r"\s+", "", text or "")
    if len(compact) <= n:
        return {compact} if compact else set()
    return {compact[i:i + n] for i in range(len(compact) - n + 1)}


def drop_near_dupes(cards: list[dict]) -> list[dict]:
    """同一次浮起里两条讲的是同一件事时,只留前面那条,把名额腾给别的。"""
    kept: list[dict] = []
    kept_grams: list[set[str]] = []
    for card in cards:
        grams = _ngrams(card.get("content", ""))
        if grams and any(
            len(grams & prev) / max(1, min(len(grams), len(prev))) > _NEAR_DUP_RATIO
            for prev in kept_grams if prev
        ):
            continue
        kept.append(card)
        kept_grams.append(grams)
    return kept


def u_shape_reorder(cards: list[dict]) -> list[dict]:
    """最重要的放头尾,次要的塞中间——对抗 LLM 的 lost-in-the-middle。

    第 0 重要的落位置 0,第 1 重要的落末位,第 2 重要的落位置 1,依此类推。
    """
    out: list[dict | None] = [None] * len(cards)
    head, tail = 0, len(cards) - 1
    for index, card in enumerate(cards):
        if index % 2 == 0:
            out[head] = card
            head += 1
        else:
            out[tail] = card
            tail -= 1
    return [c for c in out if c is not None]


# ---------------------------------------------------------------------------
# HTTP —— 一条长期保活的连接
#
# 每次新建连接要付 ~0.87s 的 TLS 握手,复用之后只剩 ~0.28s 纯 RTT(实测)。
# 省下的 0.6s 全都让给检索。keepalive_expiry 拉到 10 分钟:聊天的间隔常常
# 超过 httpx 默认的 5s,不然每隔几句就重新握手一次,等于没复用。
# ---------------------------------------------------------------------------
_client: httpx.Client | None = None
_client_lock = threading.Lock()


def _http() -> httpx.Client:
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                _client = httpx.Client(
                    base_url=RECALL_URL,
                    headers={"Authorization": f"Bearer {RECALL_TOKEN}"},
                    limits=httpx.Limits(max_keepalive_connections=2, keepalive_expiry=600.0),
                )
    return _client


def _post(path: str, payload: dict, timeout: float) -> tuple[int, dict | None]:
    """→ (status_code, body)。**故意不 raise_for_status**:服务端报错时 body 里
    带着 trace_id 和分段耗时,那正是最该留下来的诊断信息,不能连同异常一起丢掉。"""
    response = _http().post(path, json=payload, timeout=timeout)
    data = response.json() if response.content.strip() else None
    return response.status_code, (data if isinstance(data, dict) else None)


@dataclass
class FetchResult:
    """一次 /api/recall 的结果。

    **degraded 与 failure 是两件事,绝不能合并**(见 init_db 里那段注释):
    degraded 意味着拿到了结果只是打了折,failure 意味着压根没拿到。
    合并的话,「向量挂了 + 库里确实没相关的」会被读成故障,反过来
    故障也会被读成「库里没有」——我们已经为此误读了 164 轮。
    """

    cards: list
    degraded: str = ""
    failure: str = ""
    trace_id: str = ""
    timings: dict = field(default_factory=dict)


async def fetch_cards(query: str, max_results: int, drift: bool) -> FetchResult:
    # **trace_id 必须由这边生成**,不能等服务端在响应里带回来:我们的预算是 2s、
    # 服务端是 8s,超时那几轮根本收不到响应——而那恰恰是唯一需要对账的场景
    # (「我放弃了,它究竟跑了多久、卡在哪一段?」)。本地先有 id,失败路径也留得住。
    trace_id = os.urandom(4).hex()
    # 影子不在投递路径上,不该用"别让她等"的预算去截断数据
    budget = RECALL_SHADOW_TIMEOUT if shadow() else RECALL_TIMEOUT
    try:
        status, data = await asyncio.wait_for(
            asyncio.to_thread(
                _post,
                "/api/recall",
                {
                    "query": query,
                    # 多要一些候选:冷却和近重会吃掉一部分,不然过滤完就空了。
                    # 影子模式固定顶格要 20 条:这批数据是拿去离线重排的,
                    # 按名额裁剪等于提前替新排序做了决定。
                    "max_results": (
                        _SHADOW_MAX_RESULTS if shadow()
                        else min(20, max_results * 2 + 4)
                    ),
                    "max_chars": _SHADOW_MAX_CHARS if shadow() else 4000,
                    "drift": drift,
                    "trace_id": trace_id,
                },
                budget,
            ),
            timeout=budget,
        )
    except (asyncio.TimeoutError, httpx.HTTPError, OSError, ValueError) as exc:
        # 超时/网络断/响应不是 JSON:都当这轮没想起什么——绝不让她等我查记忆。
        # 注意这是 **failure** 不是 degraded:什么都没拿到,不是拿到了打折的。
        print(f"[recall] fetch failed: {type(exc).__name__}: {exc} trace={trace_id}")
        return FetchResult([], failure=type(exc).__name__, trace_id=trace_id)
    except Exception as exc:  # noqa: BLE001 — 记忆浮现永远不该弄坏投递
        print(f"[recall] unexpected: {type(exc).__name__}: {exc} trace={trace_id}")
        return FetchResult([], failure=type(exc).__name__, trace_id=trace_id)

    timings = (data or {}).get("timings") or {}
    if status >= 400 or not isinstance(data, dict):
        # 服务端明确报错(含它自己 8s 超时的 504)。body 里的 timings 要留住:
        # 那是唯一能说明「它卡在哪一段」的证据。
        print(f"[recall] server said HTTP {status} trace={trace_id}")
        return FetchResult(
            [], failure=f"http_{status}" if status else "bad_response",
            trace_id=trace_id, timings=timings,
        )

    cards = data.get("cards")
    good = [c for c in cards if isinstance(c, dict) and c.get("id")] if isinstance(cards, list) else []
    return FetchResult(
        good,
        degraded=str(data.get("degraded") or ""),
        trace_id=trace_id,   # 本地生成的那个,服务端只是复用
        timings=timings,
    )


async def warmup() -> None:
    """启动时先把 TLS 握手付掉。

    不预热的话,relay 重启后的头一两条消息会卡在建连上(实测冷启动 ~0.9s,
    加上检索必然顶穿超时)——她刚回来说的第一句话反而想不起任何事,
    正好是最不该忘的时候。
    """
    if not enabled():
        return
    try:
        # 打一个必然被拒的空 query:只为把连接建起来,不消耗服务端检索
        await asyncio.to_thread(_post, "/api/recall", {"query": ""}, 10.0)
    except Exception as exc:  # noqa: BLE001 — 预热失败不影响启动
        print(f"[recall] warmup: {type(exc).__name__} (连接已尝试建立)")


async def prune_log_on_start(conn_factory) -> None:
    """启动时清一次过期日志。跟预热一样是后台活,不阻塞启动。"""
    try:
        def _run():
            with conn_factory() as conn:
                init_db(conn)
                return prune_log(conn)
        removed = await asyncio.to_thread(_run)
        if removed:
            print(f"[recall] 清掉 {removed} 条超过 {RECALL_LOG_DAYS} 天的召回日志")
    except Exception as exc:  # noqa: BLE001
        print(f"[recall] prune failed: {type(exc).__name__}: {exc}")


def confirm(ids: list[str]) -> None:
    """回报「这几条真的浮到眼前了」,让 ombre 那边加固。fire-and-forget。

    **默认不发**(RECALL_CONFIRM 关着)。加固走的是 ombre 的 touch 语义:刷新
    last_active、累加 activation_count,而这两个都是打分输入(time 1.5 + touch 1.0,
    占总分 18.5%)。于是"被浮过"成了"更容易再被浮"的理由——自动召回这条路上
    没有任何东西打断这个回路。实测每张浮出来的卡都是 touch=1.0、time≈0.984 双双
    饱和,123 次浮现集中在 8 个条目上(62%)。精度是 0% 的时候,这个回路每转一圈
    都在加固噪音。等重新标定出正精度再打开。
    """
    if not ids:
        return
    if not RECALL_CONFIRM:
        return
    try:
        status, _ = _post("/api/recall/confirm", {"ids": ids}, 5.0)
        if status >= 400:
            # _post 不再 raise,服务端拒绝要自己看——不然加固悄悄失败没人知道
            print(f"[recall] confirm rejected: HTTP {status}")
    except Exception as exc:  # noqa: BLE001
        print(f"[recall] confirm failed: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# 注入块
# ---------------------------------------------------------------------------
def render_prefix(cards: list[dict]) -> str:
    """拼成垫在她这句话前面的背景。

    开头那句话是必须的:没有它,我会把三个月前的记忆当成她刚说的话去接。
    """
    lines = [
        "[心里浮起来的旧记忆——这些是过去的事,不是她现在说的话,",
        "垫在心里当背景就好,别当成她刚提起的话题去回应]",
    ]
    for card in cards:
        name = str(card.get("name") or "").strip()
        created = str(card.get("created") or "")[:10]
        tag = "·".join(x for x in (created, name) if x)
        mark = "📌" if card.get("pinned") else ("~" if card.get("drift") else "")
        lines.append(f"{mark}({tag}) {card.get('content', '').strip()}")
    lines.append("[以上是旧记忆,下面才是她说的话]")
    return "\n".join(lines) + "\n"


def _log_safely(conn_factory, **row) -> None:
    """给没拿到连接的分支用(闸一拦下、没候选)。写日志失败绝不影响浮现。"""
    try:
        with conn_factory() as conn:
            init_db(conn)
            log_round(conn, **row)
    except sqlite3.Error as exc:
        print(f"[recall] log failed: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# 总入口
# ---------------------------------------------------------------------------
async def recall_prefix(text: str, kind: str, meta: dict, conn_factory, msg_id=None) -> str:
    """她的一条消息 → 要垫在前面的旧记忆(可能是空字符串)。

    conn_factory: 拿一个 sqlite 连接的可调用对象(relay 的 db)。
    msg_id: 这轮的入站消息 id,用来给 thinking 卡片挂「浮现 N 条」的徽章。

    这个函数在投递路径上,**任何情况下都不许抛异常**:记忆浮现失败最多是这轮
    没想起什么,绝不能让她的消息送不到我这儿。
    """
    try:
        if shadow():
            # **影子绝不许阻塞投递**。既然一个字都不注入,让她等 2 秒再把结果
            # 丢掉是纯亏——止血却还在收利息。这里立刻返回空串,采集丢后台。
            _spawn_shadow(text, kind, meta, conn_factory, msg_id)
            return ""
        return await _recall_prefix(text, kind, meta, conn_factory, msg_id)
    except Exception as exc:  # noqa: BLE001 — 投递优先于浮现
        print(f"[recall] bailed: {type(exc).__name__}: {exc}")
        return ""


def _spawn_shadow(text: str, kind: str, meta: dict, conn_factory, msg_id) -> None:
    """把这一轮的影子采集丢到后台。投递路径上只花一个 create_task 的时间。"""
    task = asyncio.create_task(_shadow_round(text, kind, meta, conn_factory, msg_id))
    _shadow_tasks.add(task)
    task.add_done_callback(_shadow_tasks.discard)


async def _shadow_round(text: str, kind: str, meta: dict, conn_factory, msg_id) -> None:
    """后台影子采集。名额满了就记一行丢弃,不排队。"""
    global _shadow_inflight
    if _shadow_inflight >= _SHADOW_MAX_INFLIGHT:
        # **丢弃必须留痕**:不记的话这一轮就从分母里凭空消失,可靠性会显得比实际好
        _log_safely(conn_factory, msg_id=msg_id, query=text,
                    skipped="shadow_busy", shadow=True)
        return
    _shadow_inflight += 1
    try:
        await _recall_prefix(text, kind, meta, conn_factory, msg_id)
    except Exception as exc:  # noqa: BLE001 — 后台任务的异常没人接,必须自己吞
        print(f"[recall] shadow round failed: {type(exc).__name__}: {exc}")
    finally:
        _shadow_inflight -= 1


async def _recall_prefix(text: str, kind: str, meta: dict, conn_factory, msg_id=None) -> str:
    if not enabled():
        return ""

    started = time.monotonic()
    query, skipped = build_query(text, kind, meta)
    if query is None:
        # 被闸一拦下的也要记:「这轮没浮」到底是没查还是查了没中,是两回事。
        # 不记的话,停用词表调过头了都看不出来。
        if skipped not in ("not_her_message", "empty"):
            _log_safely(conn_factory, msg_id=msg_id, query=text, skipped=skipped,
                        shadow=shadow())
        return ""

    nouns = matched_nouns(query)
    slots = slot_count(query)
    got = await fetch_cards(query, slots, drift=bool(nouns))
    cards, degraded = got.cards, got.degraded
    elapsed_ms = int((time.monotonic() - started) * 1000)
    candidates = len(cards)
    # **整池快照,趁三刀之前**。cards 下面会被 filter_cooling / drop_near_dupes /
    # [:slots] 就地换掉,那之后再存就只剩旧排序的结论了——拿存活者调排序是
    # 循环论证。这一份是影子模式真正的产出。
    pool = list(cards)
    # 每一轮都带上的诊断三件套,成功失败都要记。
    # miss_live_budget:影子用 9s 跑,这里标出"查是查成了,但换成实时的 2s 预算
    # 就会超时"的那些——不标的话影子期的成功率会系统性地好看。
    trace = {
        "failure": got.failure, "trace_id": got.trace_id, "timings": got.timings,
        "miss_live_budget": elapsed_ms > RECALL_TIMEOUT * 1000,
    }
    if not cards:
        # 空手回来有两种,含义完全相反:**真的查了但库里没相关的**(no_candidates,
        # 门控正常工作),和**根本没查成**(fetch_failed:超时/网络/服务端错)。
        # 判据是 got.failure 而不是 degraded——degraded 非空只说明打了折,
        # 「向量挂了但 BM25 查了、确实没有」仍然是 no_candidates。
        _log_safely(conn_factory, msg_id=msg_id, query=query, nouns=nouns, slots=slots,
                    skipped="fetch_failed" if got.failure else "no_candidates",
                    shadow=shadow(),
                    elapsed_ms=elapsed_ms, degraded=degraded, **trace)
        return ""

    try:
        with conn_factory() as conn:
            init_db(conn)
            cards = filter_cooling(conn, cards)
            after_cool = len(cards)
            cards = drop_near_dupes(cards)
            after_dedup = len(cards)
            if not cards:
                log_round(conn, msg_id=msg_id, query=query, nouns=nouns, slots=slots,
                          candidates=candidates, server_candidates=candidates,
                          after_cool=after_cool, after_dedup=after_dedup,
                          pool=pool, shadow=shadow(), skipped="all_filtered",
                          elapsed_ms=elapsed_ms, degraded=degraded, **trace)
                return ""
            # 白名单命中就洗牌:同一个名字每次浮起不同的记忆,而不是永远那几条
            if nouns:
                random.shuffle(cards)
            cards = cards[:slots]
            # 影子模式到此为止:**不 mark_surfaced**。冷却状态一动,下一轮的
            # would_surface 就变成"被我这次影子影响过的结果",而影子的全部意义
            # 是不改变任何东西。代价是冷却会随时间退化成空转(after_cool 逐渐
            # 等于 candidates),但冷却纯在 relay 侧、事后能在日志上离线重放,
            # 排序质量不能——所以宁可让候选流保持生的。
            if not shadow():
                mark_surfaced(conn, cards)
            log_round(conn, msg_id=msg_id, query=query, nouns=nouns, slots=slots,
                      candidates=candidates, server_candidates=candidates,
                      after_cool=after_cool, after_dedup=after_dedup,
                      cards=cards, pool=pool, shadow=shadow(),
                      elapsed_ms=elapsed_ms, degraded=degraded, **trace)
    except sqlite3.Error as exc:
        print(f"[recall] state failed: {type(exc).__name__}: {exc}")
        return ""

    if shadow():
        # 不加固、不挂徽章("浮现 N 条"会是假的)、不注入。数据已经落库了。
        print(f"[recall] shadow: 本来会浮 {len(cards)} 条(池 {candidates})trace={got.trace_id}")
        return ""

    asyncio.create_task(asyncio.to_thread(confirm, [c["id"] for c in cards]))
    note_recall(msg_id, len(cards))
    return render_prefix(u_shape_reorder(cards))
