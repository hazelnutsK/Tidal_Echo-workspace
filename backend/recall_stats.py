#!/usr/bin/env python3
"""看召回日志 —— 门控调得对不对,全靠这里的数字说话。

    python recall_stats.py              最近 20 轮明细
    python recall_stats.py 50           最近 50 轮明细
    python recall_stats.py --summary    聚合(默认 7 天)
    python recall_stats.py --summary 30 聚合(30 天)

读的是 relay.db 的 recall_log 表,只读不写。

怎么看这些数字:
  · 「被闸一拦下」占比过高 → 停用词表或长度门槛过激,她正常说话都被挡了
  · 「查了没候选」占比高   → 记忆库里确实没相关的,不是门控的问题
  · candidates 够多但 surfaced 少 → 冷却期太长 或 近重合并太狠
  · score 普遍很低         → 浮上来的多半不相关,该在服务端加相关度阈值
  · elapsed_ms 的 p90 顶到超时 → 该调 RECALL_TIMEOUT 或换更近的部署
"""

import json
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB = Path(__file__).parent / "relay.db"


def conn() -> sqlite3.Connection | None:
    """表要等 relay 起来才建。没有就好好说一句,别甩栈。"""
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    exists = c.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='recall_log'"
    ).fetchone()
    if not exists:
        print("recall_log 表还不存在——relay 起来跑过一轮召回之后才会建。")
        return None
    return c


def pct(part: int, total: int) -> str:
    return f"{100 * part / total:4.0f}%" if total else "   -"


# 闸一拦下的(压根没发起检索)——算浮现率时要从分母里去掉,它们不是"没召回",
# 是"没必要召回"。
_GATE_REASONS = {
    "too_short", "stopwords_only", "no_searchable_text",
    "system_frame", "not_her_message", "empty",
}


# 老代码把异常类名(TimeoutError/ConnectError/…)塞进 degraded 列;新代码塞进
# failure 列,degraded 只留给服务端自报的降级词(semantic_unavailable)。
# 所以「degraded 里装着一个异常名」就是那个年代的故障记录 —— 这个判据比按日期
# 切更稳:重启发生在哪一刻没人记得,而异常名的长相是确定的。
_LOOKS_LIKE_EXC = re.compile(r"(Error|Exception|Timeout)$")


def col(row, name: str, default=""):
    """老库可能还没 ALTER 出这几列,取不到就给默认值。"""
    return row[name] if name in row.keys() else default


def effective_skip(row) -> str:
    """真实的跳过原因。

    2026-08-30 之前超时一律记成 no_candidates(见 recall.py 那段注释),那批行
    只能靠 degraded 非空反推。不做这个映射,旧数据里 164 次故障会继续冒充
    "库里没有"——而这批数据正要拿去做人工标注,污染的分母会一路传下去。

    新数据不能用同一套反推:degraded 非空只表示打了折,
    「向量通道挂了 → 走 BM25 → 确实没找到相关的」是**真的** no_candidates。
    两代数据靠 degraded 里装的是不是异常名来分辨。
    """
    reason = row["skipped"] or ""
    if reason != "no_candidates":
        return reason
    if col(row, "failure"):
        return "fetch_failed"                       # 新数据:failure 列说了算
    if _LOOKS_LIKE_EXC.search(row["degraded"] or ""):
        return "fetch_failed"                       # 老数据:异常名躲在 degraded 里
    return "no_candidates"


def quantile(values: list, q: float):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def show_detail(limit: int) -> None:
    db = conn()
    if db is None:
        return
    rows = list(db.execute(
        "SELECT * FROM recall_log ORDER BY id DESC LIMIT ?", (limit,)
    ))
    if not rows:
        print("还没有召回记录。")
        return
    for row in reversed(rows):
        stamp = str(row["ts"])[11:19]
        query = (row["query"] or "").replace("\n", " ")[:34]
        skipped = effective_skip(row)   # 明细也要走历史映射,否则老行还在冒充 no_candidates
        if skipped:
            why = col(row, "failure") or row["degraded"] or ""
            tail = f" ({why})" if skipped == "fetch_failed" and why else ""
            print(f"{stamp}  —  {skipped:<16}{tail} {query}")
            continue
        funnel = f"{row['candidates']}→{row['after_cool']}→{row['after_dedup']}→{row['surfaced']}"
        noun = f" [{row['nouns']}]" if row["nouns"] else ""
        deg = f" ⚠{row['degraded']}" if row["degraded"] else ""
        print(f"{stamp}  {row['surfaced']}条  {funnel:<12} {row['elapsed_ms']:>5}ms{noun}{deg}  {query}")
        for card in json.loads(row["cards"] or "[]"):
            score = card.get("score")
            sem = card.get("semantic")
            bits = f"score={score:.2f}" if isinstance(score, (int, float)) else "score=?"
            if isinstance(sem, (int, float)):
                bits += f" sem={sem:.3f}"
            if card.get("vec"):
                bits += " 语义命中"
            if card.get("drift"):
                bits += " 漂浮"
            print(f"            · {str(card.get('name'))[:26]:<26} {bits}")


def surfaced_of(row) -> int:
    """这一轮"浮了几条"。影子轮次的 surfaced 恒为 0(它确实一个字都没进模型),
    要看的是 would_surface。**两者绝不能相加**:一个是真的被我看见了,另一个是
    "假如当时开着会看见"。混进同一个分母,精度就成了一个没人验证过的数。"""
    if col(row, "shadow", 0):
        return int(col(row, "would_surface", 0) or 0)
    return int(row["surfaced"] or 0)


def show_summary(days: int, scope: str = "auto", since: str = "") -> None:
    db = conn()
    if db is None:
        return
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    if since:
        cutoff = max(cutoff, since)
    allrows = list(db.execute(
        "SELECT * FROM recall_log WHERE ts >= ? ORDER BY id", (cutoff,)
    ))
    if not allrows:
        print(f"最近 {days} 天没有召回记录。")
        return

    shadow_rows = [r for r in allrows if col(r, "shadow", 0)]
    live_rows = [r for r in allrows if not col(r, "shadow", 0)]
    if shadow_rows and live_rows:
        print(f"※ 最近 {days} 天里 影子 {len(shadow_rows)} 轮 / 真实 {len(live_rows)} 轮 "
              f"—— 两者分开统计,不合并。\n")
    if scope == "auto":
        scope = "shadow" if len(shadow_rows) > len(live_rows) else "live"
    rows = shadow_rows if scope == "shadow" else live_rows
    if not rows:
        other = "真实" if scope == "shadow" else "影子"
        print(f"最近 {days} 天没有{'影子' if scope == 'shadow' else '真实'}轮次"
              f"(全是{other}的)。换 --scope 看另一边。")
        return
    if scope == "shadow":
        print("=== 影子模式 ===")
        print("这些轮次检索跑了、数据存了,但**一个字都没注入**。下面的「浮出来」")
        print("全部是 would_surface(假如开着会浮几条),不是我真的看见过的东西。")
        # cohort 边界:影子行是从上线那一刻才开始有的,所以 --shadow 本身就是
        # 一个干净的 cohort。但改过配置(超时/并发/权重)之后就不干净了——
        # 那时候要用 --since 手工切,别拿跨配置的混合数据判断可靠性。
        print(f"cohort 起点 {rows[0]['ts'][:19]}  ({len(rows)} 轮)")
        print("改过配置之后要用 --since <ISO时间> 重新切,别跨配置混着看。\n")

    total = len(rows)
    skipped = [r for r in rows if r["skipped"]]
    hit = [r for r in rows if not r["skipped"] and surfaced_of(r) > 0]
    print(f"=== 最近 {days} 天 · {total} 轮 ===\n")
    print(f"真的浮出来了   {len(hit):>4}  {pct(len(hit), total)}")
    print(f"没浮           {len(skipped):>4}  {pct(len(skipped), total)}")

    reasons = Counter(effective_skip(r) for r in skipped)
    label = {
        "too_short": "太短(<6 汉字)",
        "stopwords_only": "剥完停用词没内容",
        "no_searchable_text": "纯表情/附件",
        "no_candidates": "查了,库里没相关的",
        "all_filtered": "有候选,全被冷却/近重砍光",
        "system_frame": "系统帧(不是她说的话)",
        "not_her_message": "不是入站消息",
        "fetch_failed": "⚠ 根本没查成(故障)",
        "shadow_busy": "影子采集忙,这轮丢了",
    }
    for reason, count in reasons.most_common():
        print(f"    {label.get(reason, reason):<22} {count:>4}  {pct(count, total)}")

    # 口径:上面那个百分比的分母是"所有轮次",混了闸一拦下的和故障的,
    # 不能当召回率看。真正该问的是——**在成功发起的检索里**,浮出来多少。
    failed = reasons.get("fetch_failed", 0)
    gated = sum(c for r, c in reasons.items() if r in _GATE_REASONS)
    # 影子因忙丢弃的**压根没发起检索**,既不是闸一也不是故障,是我自己的采样损失。
    # 留在 queried 里会把分母撑大,浮现率显得偏低。
    busy = reasons.get("shadow_busy", 0)
    queried = total - gated - failed - busy
    print(f"\n--- 口径 ---")
    print(f"    闸一拦下(没必要查)  {gated:>4}")
    print(f"    故障(没查成)        {failed:>4}")
    if busy:
        print(f"    采集忙,没采         {busy:>4}")
    print(f"    真正查成            {queried:>4}  →  浮出来 {len(hit)} 轮 "
          f"({pct(len(hit), queried)})")
    if failed and failed / max(1, total) > 0.15:
        print(f"\n    ⚠ 故障率 {pct(failed, total).strip()} —— 这么高的时候,"
              f"上面任何比例都别当质量指标看,\n      先去「降级」段看是什么在失败。")

    if scope == "shadow":
        # 影子跑 9s 预算(盖住 ombre 自己的 8s),所以"没拿到结果"和"实时会超时"
        # 是**两件事**,再加上"因为忙压根没采"——三种混在一起看就是上一版
        # 「超时被记成 no_candidates」那个错误换个地方重演。
        real_fail = sum(1 for r in rows if effective_skip(r) == "fetch_failed")
        busy = sum(1 for r in rows if effective_skip(r) == "shadow_busy")
        over = sum(1 for r in rows
                   if col(r, "miss_live_budget", 0)
                   and effective_skip(r) != "fetch_failed")
        print("\n--- 可靠性(影子口径,三种分开) ---")
        print(f"    ① 真故障(9s 内也没拿到)      {real_fail:>4}  {pct(real_fail, total)}")
        print(f"    ② 拿到了但超实时预算(>2s)    {over:>4}  {pct(over, total)}")
        print(f"    ③ 采集忙,这轮没采           {busy:>4}  {pct(busy, total)}")
        print("    ① 才是服务端真的挂了;② 是「将来恢复注入后会浮不出来」的量,")
        print("    ③ 是我自己的采样损失,跟服务端无关——三个数别相加。")
        if busy and busy / max(1, total) > 0.2:
            print(f"    ⚠ 丢弃率 {pct(busy, total).strip()} 偏高,采集并发只有 1,"
                  f"样本会偏向「不连着说话」的轮次。\n      要么调高 "
                  f"_SHADOW_MAX_INFLIGHT,要么在结论里认这个偏差。")

    if hit:
        print("\n--- 漏斗(只算浮出来的那些轮) ---")
        for key, name in (("candidates", "服务端候选"), ("after_cool", "过冷却"),
                          ("after_dedup", "过近重"), ("surfaced", "最终浮起")):
            if key == "surfaced":
                avg = sum(surfaced_of(r) for r in hit) / len(hit)
                name = "本来会浮" if scope == "shadow" else name
            else:
                avg = sum(r[key] for r in hit) / len(hit)
            print(f"    {name:<12} 平均 {avg:5.1f}")
        if scope == "shadow":
            print("    ※ 影子下不写冷却状态,「过冷却」会随时间退化成空转"
                  "(逐渐等于候选数)。\n      冷却纯在 relay 侧,想看真实效果"
                  "拿日志离线重放就行,别照这个数调冷却期。")

        cool_killed = sum(r["candidates"] - r["after_cool"] for r in hit)
        dedup_killed = sum(r["after_cool"] - r["after_dedup"] for r in hit)
        cand_total = sum(r["candidates"] for r in hit)
        print(f"    冷却砍掉 {cool_killed}({pct(cool_killed, cand_total)})"
              f" · 近重砍掉 {dedup_killed}({pct(dedup_killed, cand_total)})")

        scores, sems = [], []
        for row in hit:
            for card in json.loads(row["cards"] or "[]"):
                if isinstance(card.get("score"), (int, float)):
                    scores.append(card["score"])
                if isinstance(card.get("semantic"), (int, float)):
                    sems.append(card["semantic"])
        if scores:
            print(f"\n--- 浮起来那些条的分数({len(scores)} 条) ---")
            print(f"    融合 score   p10={quantile(scores, .1):.2f}"
                  f"  中位={quantile(scores, .5):.2f}  p90={quantile(scores, .9):.2f}")
        if sems:
            print(f"    语义相似度   p10={quantile(sems, .1):.3f}"
                  f"  中位={quantile(sems, .5):.3f}  p90={quantile(sems, .9):.3f}"
                  f"   ({len(sems)}/{len(scores)} 条走了向量通道)")

        nouns = Counter(n for r in hit for n in (r["nouns"] or "").split(",") if n)
        if nouns:
            print("\n--- 白名单命中 ---")
            print("    " + " · ".join(f"{n}×{c}" for n, c in nouns.most_common(8)))

    # 下面几段跟「这轮有没有浮出来」无关 —— 一条都没浮的时候恰恰最该看它们,
    # 所以放在 if hit 外面(之前在里面,全灭的那几天什么诊断都看不到)。
    # 凡是真发起过检索的轮次都要计入(闸一拦下的 elapsed_ms=0,自动排除)。
    # 之前筛的是 `not skipped`,等于只统计成功浮出来的那些——把 164 轮顶到
    # 超时上限的全排除了,于是延迟看着永远贴着预算却从不超过。最该看的那部分
    # 恰好被筛掉,是这类统计最容易骗人的地方。
    times = [r["elapsed_ms"] for r in rows if (r["elapsed_ms"] or 0) > 0]
    if times:
        print("\n--- relay 墙钟耗时(所有实际发起的检索) ---")
        print(f"    中位={quantile(times, .5)}ms  p90={quantile(times, .9)}ms"
              f"  最慢={max(times)}ms  n={len(times)}")
        ok = [r["elapsed_ms"] for r in rows
              if (r["elapsed_ms"] or 0) > 0 and effective_skip(r) != "fetch_failed"]
        if ok and len(ok) != len(times):
            print(f"    其中没超时的 {len(ok)} 轮:中位={quantile(ok, .5)}ms"
                  f"  p90={quantile(ok, .9)}ms  最慢={max(ok)}ms")

    # 服务端分段(2026-08-30 埋点之后的行才有)。按中位数倒排,谁是大头一眼看见。
    stages: dict[str, list] = {}
    for r in rows:
        try:
            parsed = json.loads(col(r, "timings", "{}") or "{}")
        except (ValueError, TypeError):
            continue
        for key, val in (parsed or {}).items():
            if isinstance(val, (int, float)) and key.endswith("_ms"):
                stages.setdefault(key, []).append(val)
    if stages:
        print("\n--- 服务端分段(中位 / p90) ---")
        for key in sorted(stages, key=lambda k: -quantile(stages[k], .5)):
            vals = stages[key]
            print(f"    {key:<18} {quantile(vals, .5):>5}ms / "
                  f"{quantile(vals, .9):>5}ms   n={len(vals)}")

    failures = Counter()
    for r in rows:
        if effective_skip(r) == "fetch_failed":
            failures[col(r, "failure") or r["degraded"] or "?"] += 1
    if failures:
        print("\n--- 故障(什么都没拿到) ---")
        for name, count in failures.most_common():
            print(f"    {name}: {count}")

    # 降级 ≠ 故障:这些轮次是**拿到结果的**,只是少走了一条车道
    degraded = Counter(
        r["degraded"] for r in rows
        if r["degraded"] and effective_skip(r) != "fetch_failed"
    )
    if degraded:
        print("\n--- 降级(有结果,只是打了折) ---")
        for name, count in degraded.most_common():
            print(f"    {name}: {count}")


def main() -> None:
    args = [a for a in sys.argv[1:]]
    # 只给 shadow / live 两档,**故意不提供 "all"**:一旦允许合并,
    # 「真的浮出来过」和「假如开着会浮」就会进同一个分母。
    scope = "auto"
    for name in ("shadow", "live"):
        if f"--{name}" in args:
            args.remove(f"--{name}")
            scope = name
    if "--scope" in args:
        i = args.index("--scope")
        args.pop(i)
        if i < len(args):
            scope = args.pop(i)
    since = ""
    if "--since" in args:
        i = args.index("--since")
        args.pop(i)
        if i < len(args):
            since = args.pop(i)
    if "--summary" in args:
        args.remove("--summary")
        show_summary(int(args[0]) if args else 7, scope, since)
    else:
        show_detail(int(args[0]) if args else 20)


if __name__ == "__main__":
    main()
