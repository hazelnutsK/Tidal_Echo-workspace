# 快速冒烟：recall 的两道闸是否按设计拦对了东西（跑完即弃，不进正式测试）
#
# 这个功能的成败全在门控上——检索准不准是 ombre 的事，这边要保证的是
# "不该查的别查、刚浮过的别再浮、短消息别刷屏"。
import json
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import recall

out = []

# Fixed fixture vocabulary; never require the private runtime noun list.
with patch.object(recall, "load_nouns", return_value=["小雪", "十九"]):
    # --- 闸一：这句话值不值得查 ------------------------------------------------
    def gate(text, kind="user"):
        return recall.build_query(text, kind, {})


    assert gate("嗯") == (None, "too_short"), "太短的不该查"
    assert gate("哈哈哈哈") == (None, "too_short"), "纯笑声不该查"
    assert gate("晚安") == (None, "too_short"), "停用词不该查"
    assert gate("你知道现在几点了吗")[1] == "stopwords_only", "剥完停用词没实质内容"
    assert gate("😊🐱")[1] == "no_searchable_text", "纯表情没有可检索语义"
    assert gate("我今天去买了一只很丑的猫杯子")[0] is not None
    assert gate("在想你", "reply") == (None, "not_her_message"), "只查她说的话，不查我自己的"

    # 系统帧：desire-pulse / night-watch / reply-missing 这些也是 kind="user" 落的库，
    # 只有 meta.user 能把它们跟她本人的话分开。拿 `<reply-missing message_id=…>` 去检索
    # 只会捞回一堆无关旧事（日志里真发生过，那次浮了 8 条）。
    SYS = {"user": "system", "hidden": True}
    for frame in (
        '<desire-pulse intent="explore" drive="curiosity">想去看看外面。</desire-pulse>',
        '<night-watch hour="3" total_min="42" top="小红书">她还醒着。</night-watch>',
        '<reply-missing message_id="10773" waited_sec="240">还没回她。</reply-missing>',
        '<moments-event kind="comment" post="12">她评论了。</moments-event>',
        '<reading-event kind="note" chapter="3">她划了一句。</reading-event>',
        '<calendar-remind title="私密" kind="schedule">到点了。</calendar-remind>',
        '<calendar-created id="16">她刚记下一条日程。</calendar-created>',
        '<timer-event kind="done" item="去睡觉">她按了搞定。</timer-event>',
        '<ask-event kind="pick" id="9">她选了 B。</ask-event>',
        '<garden-wake reason="reply">有人回你帖子了。</garden-wake>',
    ):
        assert recall.build_query(frame, "user", SYS) == (None, "system_frame"), frame[:30]
    # 认 meta 而不是认帧名——她自己聊起这个词的时候必须照常查
    assert recall.build_query("那个 <desire-pulse> 是什么东西啊 你刚才说的那个", "user", {})[0]

    # 跳过原因必须能区分——「这轮没浮」是没查还是查了没中，是两回事，
    # 混在一起就没法判断停用词表是不是调过头了。
    assert gate("嗯")[1] != gate("你知道现在几点了吗")[1]

    # 白名单：短消息也放行（提到名字就值得翻翻）
    short_with_noun, why = gate("小雪")
    assert short_with_noun == "小雪" and why == "", "白名单命中时短消息也要查"
    assert recall.matched_nouns("刚才小雪说她困了") == ["小雪"]

    # 数字前缀保护：「十九」是猫，「二十九度」不是。白名单命中会触发洗牌
    # （随机取代替按相关度取），误命中会让浮出来的东西变不相关——宁可漏不可错。
    for text in ("十九今天又踩我肚子了", "刚喂完十九", "十九是不是又胖了", "我十九号要去面试"):
        assert recall.matched_nouns(text), f"该命中却没中：{text}"
    for text in ("今天二十九度", "第十九章看完了", "一百一十九块"):
        assert not recall.matched_nouns(text), f"数字里的「十九」不该命中：{text}"
    out.append(("gate1", "短消息/停用词已拦，白名单放行，数字前缀已挡"))

# --- 条数阶梯 --------------------------------------------------------------
# --- 召回日志：每一级的数量要能分别看到 --------------------------------------
log_db = Path(tempfile.mkdtemp()) / "log.db"
lc = sqlite3.connect(log_db)
lc.row_factory = sqlite3.Row
recall.init_db(lc)
recall.log_round(
    lc, msg_id=7, query="十九最近还好吗", nouns=["十九"], slots=3,
    candidates=8, after_cool=5, after_dedup=4, elapsed_ms=930, degraded="",
    cards=[{"id": "cat", "name": "猫咪十九", "score": 8.75, "semantic": 0.81,
            "vector_match": True, "drift": False}],
)
recall.log_round(lc, msg_id=8, query="嗯", skipped="too_short")
rows = list(lc.execute("SELECT * FROM recall_log ORDER BY id"))
assert len(rows) == 2
hit = rows[0]
assert (hit["candidates"], hit["after_cool"], hit["after_dedup"], hit["surfaced"]) == (8, 5, 4, 1), \
    "漏斗每一级都要单独记，否则看不出是被哪一步砍掉的"
assert hit["nouns"] == "十九" and hit["elapsed_ms"] == 930
card = json.loads(hit["cards"])[0]
assert card["score"] == 8.75 and card["semantic"] == 0.81, "分数要落库，调阈值全靠它"
assert rows[1]["skipped"] == "too_short" and rows[1]["surfaced"] == 0
out.append(("log", f"{len(rows)} 行；漏斗 8→5→4→1"))


# 过期清理
old_ts = (datetime.now(timezone.utc) - timedelta(days=recall.RECALL_LOG_DAYS + 1)).isoformat()
lc.execute("INSERT INTO recall_log (ts, query) VALUES (?, ?)", (old_ts, "很久以前"))
lc.commit()
assert recall.prune_log(lc) == 1, "超过保留期的该被清掉"
assert lc.execute("SELECT count(*) c FROM recall_log").fetchone()["c"] == 2, "没过期的不能误删"
# --- 分车道原始证据 + 正文要落库 --------------------------------------------
# score 是 7 维加权归一后的排序分（含 emotion/time/importance/touch 这些与查询
# 无关的维度），拿它当相关性阈值是错的。浮不浮只能看 parts 里的绝对值。
recall.log_round(
    lc, msg_id=9, query="酸奶拿铁", candidates=1, after_cool=1, after_dedup=1,
    cards=[{
        "id": "latte", "name": "拿铁", "score": 62.5, "semantic": 0.71,
        "content": "今天确认喝的是真拿铁，不会再把酸奶倒进咖啡" * 20,  # 420 字，会被截
        "score_parts": {"topic": 0.83, "semantic": 0.71, "bm25_norm": 1.0,
                        "bm25_raw": 13.55, "literal": False,
                        "emotion": 0.5, "time": 0.42, "importance": 0.5, "touch": 0.3},
    }],
)
evidence = json.loads(
    lc.execute("SELECT cards FROM recall_log WHERE msg_id=9").fetchone()["cards"]
)[0]
assert evidence["parts"]["bm25_raw"] == 13.55, "raw 分必须落库——绝对支持门全靠它"
assert evidence["parts"]["bm25_norm"] == 1.0, "norm 也要留着，排序用的是它"
# 正文必须**整条**落库：人工裁决判的是「模型当时看到这段该不该浮」，
# 少一个字标注看到的就是另一份材料；而且事后回补取到的是「现在这版」，
# ombre 没有内容修改时间戳，无从判断跟当时是否一致。
assert len(evidence["text"]) == 420, f"正文不该被截断，得到 {len(evidence['text'])}"
assert evidence["text"].startswith("今天确认喝的是真拿铁"), "人工裁决时得看得见正文"
out.append(("evidence", f"bm25 raw={evidence['parts']['bm25_raw']} norm={evidence['parts']['bm25_norm']}"))

# --- degraded ≠ failure ------------------------------------------------------
# 把这两个概念合并，正是 164 次超时冒充「库里没相关的」的原因。
# degraded = 拿到结果了只是打了折；failure = 什么都没拿到。
import recall_stats

recall.log_round(lc, msg_id=10, query="超时那轮", skipped="fetch_failed",
                 failure="TimeoutError", trace_id="ab12cd34",
                 timings={"semantic_ms": 1400, "server_total_ms": 2600}, elapsed_ms=2000)
recall.log_round(lc, msg_id=11, query="向量挂了但确实没有", skipped="no_candidates",
                 degraded="semantic_unavailable", elapsed_ms=800)
by_msg = {r["msg_id"]: r for r in lc.execute("SELECT * FROM recall_log")}

assert by_msg[10]["failure"] == "TimeoutError" and by_msg[10]["trace_id"] == "ab12cd34"
assert json.loads(by_msg[10]["timings"])["semantic_ms"] == 1400, "分段耗时要落库"
assert recall_stats.effective_skip(by_msg[10]) == "fetch_failed"
# 关键一条：向量通道挂了但 BM25 查过了、确实没找到 —— 这是真的 no_candidates，
# 不是故障。靠 degraded 非空反推会把它误判成故障。
assert recall_stats.effective_skip(by_msg[11]) == "no_candidates", \
    "degraded 非空 ≠ 故障，别再把「打了折但查了」读成「没查成」"

# 老数据兼容：那时候超时被记成 no_candidates，异常名躲在 degraded 列里
lc.execute(
    "INSERT INTO recall_log (ts, query, skipped, degraded) VALUES (?,?,?,?)",
    ("2026-08-20T10:00:00+00:00", "老的超时行", "no_candidates", "TimeoutError"),
)
lc.commit()
legacy = lc.execute("SELECT * FROM recall_log WHERE query='老的超时行'").fetchone()
assert recall_stats.effective_skip(legacy) == "fetch_failed", \
    "老行的故障必须还原，否则拿去标注时分母是脏的"
out.append(("failure_vs_degraded", "两代数据都能正确归类"))

lc.close()
out.append(("prune", f"保留 {recall.RECALL_LOG_DAYS} 天"))

# --- 条数阶梯 --------------------------------------------------------------
assert recall.slot_count("今天有点累") == 3
assert recall.slot_count("今" * 20) == 5
assert recall.slot_count("今" * 40) == 8
out.append(("ladder", [recall.slot_count("今" * n) for n in (5, 20, 40)]))

# --- 冷却 ------------------------------------------------------------------
db_path = Path(tempfile.mkdtemp()) / "t.db"
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
recall.init_db(conn)

now = datetime.now(timezone.utc)
cards = [
    {"id": "fresh", "content": "从没浮过", "pinned": False},
    {"id": "just", "content": "五分钟前刚浮过", "pinned": False},
    {"id": "old", "content": "两小时前浮过", "pinned": False},
    {"id": "hot", "content": "浮过很多次的", "pinned": False},
    {"id": "core", "content": "核心准则", "pinned": True},
]
conn.executemany(
    "INSERT INTO recall_state (bucket_id, last_surfaced, surface_count) VALUES (?,?,?)",
    [
        ("just", (now - timedelta(minutes=5)).isoformat(), 1),
        ("old", (now - timedelta(hours=2)).isoformat(), 1),
        # surface_count=11 → 冷却 30min + 2*30min = 90min，1 小时前那次还没凉
        ("hot", (now - timedelta(minutes=60)).isoformat(), 11),
        ("core", (now - timedelta(minutes=1)).isoformat(), 50),
    ],
)
conn.commit()

survivors = [c["id"] for c in recall.filter_cooling(conn, cards)]
assert "fresh" in survivors, "没浮过的该放行"
assert "just" not in survivors, "五分钟前刚浮过的必须拦住"
assert "old" in survivors, "两小时前的已经凉了"
assert "hot" not in survivors, "浮得越勤，冷却越长"
assert "core" in survivors, "pinned 不受冷却约束"
out.append(("cooldown", survivors))

assert recall._cooldown_seconds(0) == 30 * 60
assert recall._cooldown_seconds(11) == 90 * 60
assert recall._cooldown_seconds(999) == 3 * 3600, "冷却上限 3h"

# mark_surfaced 累加而不是覆盖
recall.mark_surfaced(conn, [{"id": "just"}, {"id": "brand_new"}])
rows = {r["bucket_id"]: r["surface_count"] for r in conn.execute("SELECT * FROM recall_state")}
assert rows["just"] == 2, "已有的该 +1"
assert rows["brand_new"] == 1, "新的从 1 开始"
out.append(("mark", rows))

# --- 近重合并 --------------------------------------------------------------
dupes = [
    {"id": "a", "content": "她说她床上只放一个娃娃，别叫错名字"},
    {"id": "b", "content": "她说她床上只放一个娃娃，别叫错名字了"},
    {"id": "c", "content": "她讨厌夏天，喜欢凉爽的秋天"},
]
kept = [c["id"] for c in recall.drop_near_dupes(dupes)]
assert kept == ["a", "c"], f"讲同一件事的只留一条，得到 {kept}"
out.append(("near_dup", kept))

# --- U 型重排：最重要的落头尾 ----------------------------------------------
ordered = recall.u_shape_reorder([{"id": str(i)} for i in range(5)])
assert [c["id"] for c in ordered] == ["0", "2", "4", "3", "1"], [c["id"] for c in ordered]
assert recall.u_shape_reorder([]) == []
assert len(recall.u_shape_reorder([{"id": "x"}])) == 1
out.append(("u_shape", [c["id"] for c in ordered]))

# --- 注入块：必须写明"这是旧的" --------------------------------------------
prefix = recall.render_prefix([
    {"id": "a", "name": "秋天", "created": "2026-07-01T00:00:00", "content": "她喜欢秋天", "pinned": True},
    {"id": "b", "name": "猫", "created": "2026-08-01T00:00:00", "content": "她想养猫", "drift": True},
])
assert "不是她现在说的话" in prefix, "少这句我会把旧记忆当成她刚说的"
assert "📌" in prefix and "她喜欢秋天" in prefix
assert prefix.endswith("\n")
out.append(("prefix", prefix))

# --- 没配 token 时整个功能静默关闭 -----------------------------------------
assert recall.enabled() is (bool(recall.RECALL_URL) and bool(recall.RECALL_TOKEN))

# --- 投递优先：浮现出任何岔子都只能返回空串，不能把消息卡住 ------------------
import asyncio


def _exploding_conn():
    raise RuntimeError("db is on fire")


async def _check_bail():
    original_fetch = recall.fetch_cards
    recall.RECALL_URL = recall.RECALL_URL or "https://example.invalid"
    recall.RECALL_TOKEN = recall.RECALL_TOKEN or "x"

    async def fake_fetch(*_args, **_kwargs):
        return recall.FetchResult([{"id": "a", "content": "记忆", "pinned": False}])

    recall.fetch_cards = fake_fetch
    try:
        got = await recall.recall_prefix("我今天买了只很丑的猫杯子", "user", {}, _exploding_conn)
        assert got == "", f"数据库炸了也必须返回空串，得到 {got!r}"
    finally:
        recall.fetch_cards = original_fetch


asyncio.run(_check_bail())
out.append(("bail_out", "数据库异常时静默降级，投递不受影响"))

# --- 超时也必须留下 trace_id ------------------------------------------------
# trace_id 由 relay 生成、随请求下传，服务端只是复用。反过来做（服务端生成、
# 随响应返回）在最需要它的场景下恰好失效：我们的预算 2s、服务端 8s，超时那几轮
# 根本收不到响应——而那正是唯一需要对账的场景（「我放弃了，它跑了多久？」）。
async def _check_trace_survives_timeout():
    recall.RECALL_URL = recall.RECALL_URL or "https://example.invalid"
    recall.RECALL_TOKEN = recall.RECALL_TOKEN or "x"
    sent = {}

    def fake_post(_path, payload, _timeout):
        sent.update(payload)
        raise TimeoutError("服务端还在跑，我等不及了")

    original = recall._post
    recall._post = fake_post
    try:
        got = await recall.fetch_cards("她刚才说了句挺长的话", 3, drift=False)
    finally:
        recall._post = original

    assert got.cards == [] and got.failure == "TimeoutError", "超时算 failure 不算 degraded"
    assert not got.degraded, "什么都没拿到，谈不上「降级」"
    assert got.trace_id, "超时也必须有 trace_id，否则跟服务端日志永远对不上账"
    assert sent.get("trace_id") == got.trace_id, "同一个 id 必须已经随请求发出去了"
    return got.trace_id


timeout_trace = asyncio.run(_check_trace_survives_timeout())

# 而且要能落库——对账靠的是日志里那一行，不是内存里的对象
tc_db = Path(tempfile.mkdtemp()) / "trace.db"
tc = sqlite3.connect(tc_db)
tc.row_factory = sqlite3.Row
recall.init_db(tc)
recall.log_round(tc, msg_id=99, query="超时那轮", skipped="fetch_failed",
                 failure="TimeoutError", trace_id=timeout_trace, elapsed_ms=2000)
saved = tc.execute("SELECT * FROM recall_log WHERE msg_id=99").fetchone()
assert saved["trace_id"] == timeout_trace, "超时轮次的 trace_id 要落库"
assert recall_stats.effective_skip(saved) == "fetch_failed"
tc.close()
out.append(("trace_on_timeout", f"trace={timeout_trace} 已随请求下传并落库"))

conn.close()
for label, value in out:
    print(f"{label}: {value}")
print("\nALL RECALL GATE CHECKS PASSED")
