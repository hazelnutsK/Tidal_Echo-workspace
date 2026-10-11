#!/usr/bin/env python3
"""人工裁决的取样器 —— 把召回日志切成三类可标注的样本。

    python recall_annotate.py                  看各类样本的分布
    python recall_annotate.py --md 标注/        导出待标注清单(默认 A30 / C20)
    python recall_annotate.py --md 标注/ --a 50 --c 30 --b 20
    python recall_annotate.py --merge 标注/     把 md 里勾的合并回 jsonl
    python recall_annotate.py --report 标注/    看结果

**裁决时只看她说的话和记忆正文,看不到任何分数。**
导出目录里四个文件:

    A.md / C.md         ← 标这两个,一条一屏,把 [ ] 改成 [x]
    清单.jsonl          ← --merge 把勾选按 key 合并到这里
    清单.scores.jsonl   ← 分数,事后 join 用。**标完再打开**

分开不是洁癖:我们标注的目的就是拿它去标定阈值。要是标注时先看见
bm25_raw=13.55,自然会想「这么高应该算该浮」——再拿这份标注反过来定阈值,
就成了循环论证,尺子提前知道了答案。所以物理上把它们分开放。
(分数仍然用于**分层抽样**,保证高低分都被覆盖到;那跟引导裁决是两回事。)

为什么要分三类:

  A 浮现精度 —— 真的浮出来了的条目。判「该浮/边缘/浮错/不该浮」。
    现在就能标:结论是**当前精度基线**,跟改造后的数字对比用。
    (标定绝对支持门要等 ombre 部署后的新数据——那批才有分车道 raw 分。)

  B 可靠性故障 —— relay 没拿到结果的轮次(超时/网络/5xx)。
    **绝不能算作语义漏召**:检索压根没跑完,不知道库里有没有相关的。
    它衡量可用性,不是召回质量。混进 omission 分母,就会把「服务端慢」
    记成「记忆库不行」,然后照着错误诊断去调阈值。
    要判 omission 得先人工检索一遍,所以这类只给查询原文和 trace_id。

  C 疑似漏召 —— 检索真跑完了但没浮:闸一拦下的,或查了库里没有的。
    这类才是真正的 omission 候选,人工检索确认库里确有相关记忆才算数。

标注纪律(照搬那份重建文档第六节):裁决口径先于数据划定,不由结果回推;
样本必须逐条人工过 —— 高频自动指标会掩盖精度问题,抽样人工裁决不会。
"""

import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

from recall_stats import col, conn, effective_skip

# 历史数据里的系统帧:第 2 刀之前它们还在走召回,日志里留着当时的浮现记录。
# 已经从源头挡掉了,再拿去标注既浪费人力,又会把「系统帧排除」的功劳算进
# 「绝对支持门」的账上 —— 两件事的效果必须分开量。
_SYS_FRAME = re.compile(r"^<[a-z][a-z-]{2,30}[\s>]")

_GATE = {"too_short", "stopwords_only", "no_searchable_text"}
_SEARCHED_EMPTY = {"no_candidates", "all_filtered"}

VERDICTS_A = ["该浮", "边缘", "浮错", "不该浮"]

# C 类四档。**「库里有」不等于 omission** —— 她说「在吃辣条了(」时库里可能真有
# 一条「她爱吃辣条」,但这轮没必要浮。把这种算成 omission,就会照着去放宽闸一,
# 结果制造更多噪音。所以「库里有没有」和「该不该浮」必须拆成两个维度问,
# 跟 A 类的「该浮/不该浮」对称。
VERDICTS_C = [
    "库里有,而且这轮该浮",      # ← 真正的 omission,只有这一档算
    "库里有,但这轮没必要浮",     # ← 闸一挡对了
    "库里没有相关的",           # ← 检索没问题,库里就是没有
    "不确定",
]
OMISSION = VERDICTS_C[0]

DEFAULT_N = {"A_precision": 30, "C_missed": 20, "B_reliability": 0}


def classify(row) -> str:
    if _SYS_FRAME.match((row["query"] or "").strip()):
        return "legacy_frame"
    reason = effective_skip(row)
    if not reason:
        return "A_precision" if row["surfaced"] else "C_missed"
    if reason == "fetch_failed":
        return "B_reliability"
    if reason in _GATE or reason in _SEARCHED_EMPTY:
        return "C_missed"
    return "skip"          # system_frame / not_her_message:不是她说的话


def build(rows: list) -> tuple[dict, dict]:
    """→ (给人看的样本, 按 key 索引的分数 sidecar)"""
    blind: dict[str, list] = {"A_precision": [], "B_reliability": [], "C_missed": []}
    scores: dict[str, dict] = {}
    legacy = 0
    for row in rows:
        bucket = classify(row)
        if bucket == "legacy_frame":
            legacy += 1
            continue
        if bucket == "skip":
            continue
        base = {"log_id": row["id"], "ts": row["ts"], "她说的话": row["query"]}

        if bucket == "A_precision":
            for idx, card in enumerate(json.loads(row["cards"] or "[]")):
                key = f"{row['id']}#{idx}"
                blind["A_precision"].append({
                    **base,
                    "key": key,
                    "记忆标题": card.get("name"),
                    "记忆正文": card.get("text") or "(早于正文落库,需按 id 回查 ombre)",
                    "ver": card.get("ver") or "unknown",
                    "裁决": "",                      # ← VERDICTS_A 之一
                    "备注": "",
                })
                parts = card.get("parts") or {}
                scores[key] = {
                    "综合排序分": card.get("score"),   # 排序用,不是相关性
                    "semantic": card.get("semantic"),
                    "bm25_raw": parts.get("bm25_raw"),
                    "bm25_norm": parts.get("bm25_norm"),
                    "topic": parts.get("topic"),
                    "literal": parts.get("literal"),
                    "证据齐全": bool(parts),
                }
        elif bucket == "B_reliability":
            blind["B_reliability"].append({
                **base,
                "key": f"{row['id']}",
                "故障": col(row, "failure") or row["degraded"],
                "trace_id": col(row, "trace_id"),
                "relay墙钟ms": row["elapsed_ms"],
                "服务端分段": col(row, "timings", "{}"),
                "备注": "可用性问题,不是漏召。要判 omission 必须先人工检索。",
                "人工检索后判定": "",
            })
        else:
            blind["C_missed"].append({
                **base,
                "key": f"{row['id']}",
                "为什么没浮": effective_skip(row) or "查了但一条都没留下",
                "裁决": "",                          # ← VERDICTS_C 之一
                "备注": "",
            })
    blind["_legacy_frames"] = legacy
    return blind, scores


def has_body(item: dict) -> bool:
    """正文取不到的样本不能进抽样 —— 只有标题判不了「这条该不该为这句话浮」,
    标注者只能瞎猜或跳过,白占一个名额。"""
    text = str(item.get("记忆正文") or "")
    return bool(text) and not text.startswith("(")


def version_ok(item: dict) -> bool:
    """只有能确认「跟当时注入的是同一版」的才进抽样。

    历史日志的正文是事后回填的,取回的是**现在这版**;ombre 没有内容修改时间戳,
    所以只能靠 7-19 备份做充分条件判断(见 recall_verify_version.py)。
    拿一份可能被改过的正文去标「该不该浮」,标的是不存在的历史。
    """
    return item.get("ver") == "ok"


def stratified(items: list, scores: dict, n: int) -> list:
    """按综合分三等分分层抽样 —— 只为覆盖面,分数不进标注文件。

    纯随机抽 30 条很可能全落在中间段,而阈值恰恰要靠两端的样本才定得准。
    """
    if not n or len(items) <= n:
        return items
    ranked = sorted(items, key=lambda i: scores.get(i["key"], {}).get("综合排序分") or 0)
    if not any(scores.get(i["key"], {}).get("综合排序分") for i in ranked):
        return random.sample(items, n)          # 没分数可分层,退回随机
    third = max(1, len(ranked) // 3)
    bands = [ranked[:third], ranked[third:2 * third], ranked[2 * third:]]
    per, out = n // 3, []
    for band in bands:
        out += random.sample(band, min(per, len(band)))
    rest = [i for i in ranked if i not in out]
    out += random.sample(rest, min(n - len(out), len(rest)))
    return out


def show_report(path: Path) -> None:
    items = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
    graded = [i for i in items if i.get("类") == "A_precision" and i.get("裁决")]
    if not graded:
        print("A 类还没有标注。")
        return
    tally = Counter(i["裁决"] for i in graded)
    n = len(graded)
    strict = tally["该浮"] / n
    loose = (tally["该浮"] + tally["边缘"]) / n
    print(f"A 类已标 {n} 条:  " + "  ".join(f"{k}={v}" for k, v in tally.items()))
    print(f"  严格精度(只算「该浮」)      {tally['该浮']}/{n} = {strict:.1%}")
    print(f"  宽松精度(该浮+边缘)         {tally['该浮'] + tally['边缘']}/{n} = {loose:.1%}")
    print("  两个都报:严格反映「浮得准不准」,宽松反映「有没有添乱」,")
    print("  调门控时看严格,判会不会惹人烦看宽松。")

    missed = Counter(i["裁决"] for i in items if i.get("类") == "C_missed" and i.get("裁决"))
    if missed:
        total = sum(missed.values())
        om = missed.get(OMISSION, 0)
        no_need = missed.get(VERDICTS_C[1], 0)
        absent = missed.get(VERDICTS_C[2], 0)
        print(f"\nC 类已标 {total} 轮:")
        for k, v in missed.most_common():
            print(f"    {k:<22} {v}")
        print(f"  omission 率        {om}/{total} = {om/total:.1%}"
              f"   ← 只有这一档算,该想起而没想起")
        print(f"  闸一挡对了         {no_need + absent}/{total} = {(no_need + absent)/total:.1%}"
              f"   (没必要浮 {no_need} + 库里本来没有 {absent})")
        if no_need > om:
            print("  ↑ 「没必要浮」明显多过真漏召 —— 说明闸一没挡过头,别急着放宽门槛")

    rel = [i for i in items if i.get("类") == "B_reliability"]
    if rel:
        done = sum(1 for i in rel if i.get("人工检索后判定"))
        print(f"\nB 类 {len(rel)} 轮(已查 {done}) —— 不计入上面任何比例,它是可用性指标")

    sidecar = path.with_suffix(".scores.jsonl")
    if sidecar.exists() and graded:
        by_key = {}
        for line in sidecar.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rec = json.loads(line)
                by_key[rec.pop("key")] = rec
        print("\n--- 标定用:裁决 × 分车道原始分 ---")
        for verdict in VERDICTS_A:
            vals = [by_key.get(i["key"], {}) for i in graded if i["裁决"] == verdict]
            raws = [v["bm25_raw"] for v in vals if isinstance(v.get("bm25_raw"), (int, float))]
            sems = [v["semantic"] for v in vals if isinstance(v.get("semantic"), (int, float))]
            if not vals:
                continue
            bits = [f"n={len(vals)}"]
            if raws:
                bits.append(f"bm25_raw 中位={sorted(raws)[len(raws)//2]:.2f}")
            if sems:
                bits.append(f"semantic 中位={sorted(sems)[len(sems)//2]:.3f}")
            print(f"    {verdict:<8} " + "  ".join(bits))
        print("    ↑ 「该浮」与「不该浮」的分布分开了,门就画在中间;没分开说明这条车道不够用。")


def quote(text: str) -> str:
    """渲染成 markdown 引用块（每行都要前缀，空行也要，否则块会断开）。"""
    lines = str(text or "").strip().splitlines() or [""]
    return "\n".join("> " + ln if ln.strip() else ">" for ln in lines)


_A_INTRO = """# A 类 · 浮现精度

这些记忆**当时真的浮到我眼前了**。要判断的是：在她说出那句话的当下，这条该不该浮。

- **该浮** —— 确实相关，浮出来对接话有帮助
- **边缘** —— 沾点边，浮出来不算错，但也没什么用
- **浮错** —— 不相关，纯噪音
- **不该浮** —— 不但不相关，还可能引起误会或尴尬

只看「她说的话」和「记忆正文」。**别去翻分数** —— 那正是要用这份标注来校准的东西，
先看了就成了循环论证（分数在 `.scores.jsonl` 里，标完再看）。

正文是**完整的、当时注入给模型的那一版**，没有截断。ombre 没有内容修改时间戳，
所以这批样本已经用 2026-07-19 的备份快照做过筛选：只保留了「备份至今未变」的条目，
无法确认版本的（7-19 之后新建、或确实改过的）都排除了——拿一份可能被改过的正文
去标「该不该浮」，标的是不存在的历史。

勾选方式：把 `- [ ]` 改成 `- [x]`，每条勾**一个**。拿不准就勾「边缘」并在备注里写一句。
"""

_C_INTRO = """# C 类 · 疑似漏召

这些轮次**检索真的跑完了，但一条都没浮**（被闸一拦下，或查了库里没有）。
要判断的是：库里到底有没有相关记忆，以及那条该不该在这轮浮出来。

**「库里有」不等于漏召。** 她说「在吃辣条了（」，库里可能真有一条「她爱吃辣条」，
但这轮没必要浮——把这种算成漏召，就会照着去放宽闸一，结果制造更多噪音。
所以两个维度分开问：

- **库里有，而且这轮该浮** —— 真正的漏召，只有这一档进 omission 率
- **库里有，但这轮没必要浮** —— 闸一挡对了，这是好事
- **库里没有相关的** —— 检索没毛病，库里就是没有
- **不确定** —— 搜不动或判不了，别硬填

判之前**先去 ombre 搜一次**（`breath_search` 或她 App 的记忆库），
不搜就填等于猜。搜完在备注里写一句你搜到了什么，方便回溯。
"""


def render_md(kind: str, items: list) -> str:
    """一条一屏的 markdown。**绝不写入任何分数、排名或车道值。**"""
    intro = _A_INTRO if kind == "A" else _C_INTRO
    verdicts = VERDICTS_A if kind == "A" else VERDICTS_C
    out = [intro, f"\n共 {len(items)} 条。\n\n---\n"]
    for i, item in enumerate(items, 1):
        out.append(f"\n## {kind}-{i:02d}\n")
        # key 是稳定标识，合并脚本靠它回填；序号只是方便口头指认
        out.append(f"`key: {item['key']}`　·　log_id {item['log_id']}　·　{str(item['ts'])[:16]}\n")
        out.append("\n**她说的话**\n\n" + quote(item["她说的话"]) + "\n")
        if kind == "A":
            out.append(f"\n**浮出来的记忆** — {item['记忆标题']}\n\n"
                       + quote(item["记忆正文"]) + "\n")
        else:
            out.append(f"\n**为什么没浮**：`{item['为什么没浮']}`\n")
        out.append("\n**裁决**（勾一个）\n\n")
        out.extend(f"- [ ] {v}\n" for v in verdicts)
        out.append("\n**备注**：\n\n---\n")
    return "".join(out)


_KEY_RE = re.compile(r"^`key:\s*([^`]+)`")
_TICK_RE = re.compile(r"^\s*-\s*\[[xX]\]\s*(.+?)\s*$")


def parse_md(path: Path) -> tuple[dict, list]:
    """→ ({key: 裁决}, [问题])。勾了多个或一个没勾都要报出来，不能静默。"""
    picks: dict[str, list] = {}
    key = None
    for line in path.read_text(encoding="utf-8").splitlines():
        m = _KEY_RE.match(line)
        if m:
            key = m.group(1).strip()
            picks.setdefault(key, [])
            continue
        m = _TICK_RE.match(line)
        if m and key:
            picks[key].append(m.group(1).strip())
    problems = [f"{k} 勾了 {len(v)} 个：{v}" for k, v in picks.items() if len(v) > 1]
    return {k: v[0] for k, v in picks.items() if len(v) == 1}, problems


def do_merge(folder: Path) -> None:
    """把 markdown 里的勾选合并回 jsonl（按 key 对齐，不依赖顺序）。"""
    listing = folder / "清单.jsonl"
    if not listing.exists():
        print(f"找不到 {listing}")
        return
    verdicts: dict[str, str] = {}
    for name in ("A.md", "C.md"):
        path = folder / name
        if not path.exists():
            continue
        got, problems = parse_md(path)
        verdicts.update(got)
        print(f"  {name}: 读到 {len(got)} 条裁决" + (f"，{len(problems)} 条有问题" if problems else ""))
        for p in problems:
            print(f"      ⚠ {p}")

    rows = [json.loads(l) for l in listing.read_text(encoding="utf-8").splitlines() if l.strip()]
    filled = 0
    for row in rows:
        v = verdicts.get(row.get("key"))
        if v:
            row["裁决" if row["类"] != "B_reliability" else "人工检索后判定"] = v
            filled += 1
    listing.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    todo = sum(1 for r in rows if r["类"] in ("A_precision", "C_missed") and not r.get("裁决"))
    print(f"\n合并回 {listing}：填了 {filled} 条，还有 {todo} 条没标")
    if filled:
        print(f"\n看结果：python recall_annotate.py --report {listing}")


def main() -> None:
    args = sys.argv[1:]
    if "--report" in args:
        target = Path(args[args.index("--report") + 1])
        show_report(target / "清单.jsonl" if target.is_dir() else target)
        return
    if "--merge" in args:
        do_merge(Path(args[args.index("--merge") + 1]))
        return

    db = conn()
    if db is None:
        return
    rows = list(db.execute("SELECT * FROM recall_log ORDER BY id"))
    blind, scores = build(rows)

    print(f"=== 可标注样本({len(rows)} 轮日志) ===\n")
    withev = sum(1 for i in blind["A_precision"] if scores.get(i["key"], {}).get("证据齐全"))
    print(f"  A 浮现精度      {len(blind['A_precision']):>4} 条   判该浮/边缘/浮错/不该浮")
    print(f"       其中带 raw 分 {withev:>4} 条   (标定阈值要用它,拿基线不用)")
    print(f"  B 可靠性故障    {len(blind['B_reliability']):>4} 轮   **不算漏召**,需人工检索后另判")
    print(f"  C 疑似漏召      {len(blind['C_missed']):>4} 轮   人工检索确认库里有没有")
    if blind.get("_legacy_frames"):
        print(f"\n  (另剔除 {blind['_legacy_frames']} 轮历史系统帧 —— 已由闸一从源头解决,")
        print("   不进样本;它们的改善要单独记在「系统帧排除」账上,别混进阈值的效果)")

    if "--md" not in args:
        print(f"\n  导出:--md 目录   (默认抽 A{DEFAULT_N['A_precision']} / "
              f"C{DEFAULT_N['C_missed']},B 类用 --b N 单独抽)")
        return

    folder = Path(args[args.index("--md") + 1])
    folder.mkdir(parents=True, exist_ok=True)
    want = dict(DEFAULT_N)
    for flag, key in (("--a", "A_precision"), ("--b", "B_reliability"), ("--c", "C_missed")):
        if flag in args:
            want[key] = int(args[args.index(flag) + 1])

    chosen: dict[str, list] = {}
    for name, items in blind.items():
        if name.startswith("_") or not want[name]:
            continue
        n = want[name]
        # 正文取不到的不进抽样:只有标题判不了,白占名额
        if name == "A_precision":
            pool = [i for i in items if has_body(i) and version_ok(i)]
        else:
            pool = list(items)
        dropped = len(items) - len(pool)
        picked = (stratified(pool, scores, n) if name == "A_precision"
                  else (random.sample(pool, min(n, len(pool))) if n < len(pool) else pool))
        chosen[name] = picked
        note = f"（另有 {dropped} 条正文缺失或版本无法确认，已排除）" if dropped else ""
        print(f"\n  {name}: 抽了 {len(picked)} / {len(pool)} {note}")

    (folder / "A.md").write_text(render_md("A", chosen.get("A_precision", [])), encoding="utf-8")
    (folder / "C.md").write_text(render_md("C", chosen.get("C_missed", [])), encoding="utf-8")

    picked_keys = set()
    with (folder / "清单.jsonl").open("w", encoding="utf-8") as fh:
        for name, picked in chosen.items():
            for item in picked:
                picked_keys.add(item["key"])
                fh.write(json.dumps({"类": name, **item}, ensure_ascii=False) + "\n")

    with (folder / "清单.scores.jsonl").open("w", encoding="utf-8") as fh:
        for key, rec in scores.items():
            if key in picked_keys:
                fh.write(json.dumps({"key": key, **rec}, ensure_ascii=False) + "\n")

    print(f"\n已导出 → {folder}")
    print("    A.md / C.md          ← 标这两个，勾 [x]")
    print("    清单.jsonl           ← 合并后的结果落在这")
    print("    清单.scores.jsonl    ← **标完再看**")
    print(f"\n  标完:  python recall_annotate.py --merge {folder}")
    print(f"  看结果:python recall_annotate.py --report {folder}")


if __name__ == "__main__":
    main()
