"""Offline integration tests. Temporary relay/config only; no private data or APIs."""
import ast
import asyncio
import copy
from contextvars import ContextVar
from contextlib import closing
import datetime as dt
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
from typing import Any
import unittest
from unittest.mock import AsyncMock

from conversation_memory import ConversationMemory, settings, data_message
from call_tools import CALL_TURN


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.relay = root / "relay.db"
        self.forge = root / "forge"
        self.forge.mkdir()
        with closing(sqlite3.connect(self.relay)) as conn, conn:
            conn.execute("CREATE TABLE messages(id INTEGER PRIMARY KEY,ts TEXT,direction TEXT,kind TEXT,text TEXT,meta TEXT)")
        self.memory = ConversationMemory(root / "memory.sqlite3", self.relay, self.forge)
        self.cfg = {"sessions": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}],
                    "summaries": {}, "history_anchors": {}}
        self.ns = {
            "CALL_TURN": CALL_TURN,
            "Any": Any, "json": json, "dt": dt, "sqlite3": sqlite3, "re": __import__("re"), "closing": closing,
            "MEMORY": self.memory, "MEMORY_TURN": ContextVar("test_turn", default=None),
            "MCP_RESULT_MAX": 20000, "MEMORY_BRIEF_TOOLS": {"breath", "breath_search", "breath_advanced"},
            "data_message": data_message, "PERSONA": "persona", "MEMORY_BRIEF_HEADER": "old brief",
            "memory_brief": lambda _: "", "session_summary": lambda key: self.cfg["summaries"].get(key, {}).get("text", ""),
            "load_config": lambda: copy.deepcopy(self.cfg), "history_turns": lambda: 100,
            "RELAY_DB": str(self.relay), "_assistant_trace": lambda _: "", "_image_parts_from_meta": lambda _: [],
            "_WEEKDAYS": ["一", "二", "三", "四", "五", "六", "日"],
            "relay_rows": self.rows, "relay_row_meta": lambda mid: self.row(mid).get("meta"),
            "relay_msg_ts": lambda mid: self.row(mid).get("ts", ""),
        }
        names = {"build_messages", "_parse_meta", "inbound_source_prefix", "time_context", "_wrap_content",
                 "summary_lines", "remember_memory_result"}
        source = Path(__file__).with_name("api_loop.py")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    def add(self, source, text, direction="in", **meta):
        with closing(sqlite3.connect(self.relay)) as conn, conn:
            return conn.execute("INSERT INTO messages(ts,direction,kind,text,meta) VALUES(?,?,?,?,?)",
                                ("2026-10-03T10:00:00+08:00", direction, "user" if direction == "in" else "reply", text,
                                 json.dumps({"api_session": source, **meta}))).lastrowid

    def row(self, mid):
        with closing(sqlite3.connect(self.relay)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM messages WHERE id=?", (mid,)).fetchone()
            return dict(row) if row else {}

    def rows(self, before, session, limit):
        with closing(sqlite3.connect(self.relay)) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(r) for r in conn.execute(
                "SELECT * FROM messages WHERE id<? AND json_extract(meta,'$.api_session')=? ORDER BY id",
                (before or 2**63 - 1, session))]

    def prompt(self, session, mid):
        self.memory.prepare(session, mid, self.cfg)
        return self.ns["build_messages"](self.row(mid)["text"], before_id=mid, session_id=session)

    def test_api_to_api_keeps_own_summary_and_latest_raw(self):
        covered = self.add("a", "旧对话")
        self.cfg["summaries"]["a"] = {"text": "A 自己记下的约定", "covers_to": covered}
        self.add("a", "面试改到周五")
        self.cfg["summaries"]["b"] = {"text": "B 自己的旧事", "covers_to": 0}
        before = copy.deepcopy(self.cfg)
        prompt = self.prompt("b", self.add("b", "接着聊"))
        self.assertIn("A 自己记下的约定", str(prompt))
        self.assertIn("面试改到周五", str(prompt))
        self.assertIn("B 自己的旧事", str(prompt))
        self.assertEqual(before, self.cfg)

    def test_incremental_updates_are_anchored_and_prefix_stays_stable(self):
        self.add("a", "最初的近况")
        first = self.prompt("b", self.add("b", "第一句"))
        self.add("b", "回复", "out")
        second = self.prompt("b", self.add("b", "第二句"))
        self.assertEqual(first, second[:len(first)])
        self.add("a", "新进展：已经面完")
        third = self.prompt("b", self.add("b", "第三句"))
        self.assertEqual(second, third[:len(second)])
        self.assertEqual(str(third).count("新进展：已经面完"), 1)
        fourth = self.prompt("b", self.add("b", "第四句"))
        self.assertEqual(third, fourth[:len(third)])

    def test_desktop_summary_and_unsummarized_tail_are_both_visible(self):
        (self.forge / "summary.md").write_text("桌面摘要：上周的约定", encoding="utf-8")
        (self.forge / "note.md").write_text("她当时担心面试", encoding="utf-8")
        self.add("", "桌面刚聊完的新话题")
        prompt = self.prompt("b", self.add("b", "回来啦"))
        self.assertIn("上周的约定", str(prompt))
        self.assertIn("桌面刚聊完的新话题", str(prompt))
        self.assertIn("非此刻", str(prompt))

    def test_handoff_is_not_local_summary_input_or_reexported(self):
        self.add("a", "只属于 A 的原始事件")
        mid = self.add("b", "B 原话")
        self.prompt("b", mid)
        lines = self.ns["summary_lines"]("b", 0, mid)
        self.assertIn("B 原话", str(lines))
        self.assertNotIn("只属于 A", str(lines))
        # Delete A from source registry: B cannot launder its imported snapshot
        # into a third window's source material.
        self.cfg["sessions"] = [{"id": "b"}, {"id": "c"}]
        prompt = self.prompt("c", self.add("c", "新窗"))
        self.assertNotIn("只属于 A", str(prompt))

    def test_later_reads_survive_restart_and_join_summary_with_original_reference(self):
        first = self.add("b", "第一次读")
        self.memory.record("b", first, "breath", "首次记忆")
        second = self.add("b", "再查")
        eid = self.memory.record("b", second, "breath_advanced", "之后才查到的关键约定")
        restarted = ConversationMemory(self.memory.path, self.relay, self.forge)
        self.assertIn("关键约定", restarted.read("b", eid))
        third = self.add("b", "下一轮")
        prompt = self.prompt("b", third)
        self.assertIn("首次记忆", str(prompt))
        self.assertIn("之后才查到", str(prompt))
        lines = self.ns["summary_lines"]("b", first, second)
        self.assertIn(f"memory_read id={eid}", str(lines))
        self.assertIn("之后才查到", str(lines))
        self.cfg["summaries"]["b"] = {"text": "已压进摘要", "covers_to": second}
        _, events = self.memory.context("b", self.cfg, third)
        self.assertNotIn("之后才查到", str(events))
        self.assertIn("之后才查到", restarted.read("b", eid))

    def test_retry_dedup_dry_run_and_window_isolation(self):
        mid = self.add("b", "read")
        token = self.ns["MEMORY_TURN"].set({"session": "b", "message_id": mid, "write": True})
        try:
            for _ in range(2):
                self.ns["remember_memory_result"]("b", "breath_advanced", "同一份结果")
            self.ns["remember_memory_result"](None, "breath", "dry result")
        finally:
            self.ns["MEMORY_TURN"].reset(token)
        reads = self.memory.reads("b")
        self.assertEqual(len(reads), 1)
        self.assertNotIn("同一份结果", self.memory.read("a", reads[0]["id"]))

    def test_long_read_is_lossless_on_disk_and_can_be_paged(self):
        text = "原" * 21000 + "最后的约定"
        mid = self.add("b", "read")
        eid = self.memory.record("b", mid, "breath", text)
        self.assertEqual(self.memory.reads("b")[0]["content"], text)
        self.assertIn("offset=16000", self.memory.read("b", eid))
        self.assertIn("最后的约定", self.memory.read("b", eid, 16000))

    def test_hidden_failed_future_and_unknown_sources_do_not_leak(self):
        self.add("a", "隐藏的系统帧", hidden=True)
        self.add("a", "模型失败输出", "out", api={"error": "failed"})
        self.add("not-registered", "其他身体")
        mid = self.add("b", "现在")
        self.add("a", "未来消息")
        prompt = self.prompt("b", mid)
        for value in ("隐藏的系统帧", "模型失败输出", "其他身体", "未来消息"):
            self.assertNotIn(value, str(prompt))

    def test_fresh_and_isolated_and_deletion(self):
        self.add("a", "共享事实")
        self.cfg["sessions"][1]["handoff_mode"] = "fresh"
        prompt = self.prompt("b", self.add("b", "新话题"))
        self.assertIn("不继承", str(prompt))
        self.cfg["sessions"][1]["handoff_mode"] = "isolated"
        prompt = self.prompt("b", self.add("b", "隔离窗"))
        self.assertNotIn("共享事实", str(prompt))
        self.memory.record("b", 1, "breath", "记忆")
        self.memory.delete("b")
        self.assertEqual(self.memory.reads("b"), [])
        self.assertEqual(self.memory.context("b", self.cfg), ("", []))

    def test_page_refresh_replaces_snapshot_without_mutating_summary(self):
        self.add("a", "旧近况")
        self.prompt("b", self.add("b", "第一句"))
        self.add("a", "新近况")
        self.cfg["history_anchors"]["b"] = 2
        self.cfg["summaries"]["b"] = {"text": "B 摘要不被覆盖", "covers_to": 2}
        prompt = self.prompt("b", self.add("b", "翻页"))
        self.assertIn("新近况", str(prompt))
        self.assertEqual(self.cfg["summaries"]["b"]["text"], "B 摘要不被覆盖")

    def test_settings_are_bounded(self):
        self.assertEqual(settings({"handoff_chars": 999999})["handoff_chars"], 30000)
        with self.assertRaises(ValueError):
            settings({"enabled": "false"})

    def test_both_tool_loops_save_before_model_failure_but_not_tool_error(self):
        source = Path(__file__).with_name("api_loop.py")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, ast.AsyncFunctionDef)
                 and n.name in {"run_route_native", "run_route_openai"}]
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)
        self.ns.update({
            "mcp_tool_defs": AsyncMock(return_value=[]), "to_anthropic": lambda m: ([], list(m)),
            "mark_cache": lambda *a: None, "msg_cache_budget": lambda _: 0,
            "native_body": lambda *a: {}, "MCP_TOOL_ROUNDS": 8, "act_step": lambda *a: {},
        })
        async def run():
            for native in (True, False):
                for failed in (False, True):
                    with self.subTest(native=native, tool_error=failed):
                        mid = self.add("b", "查阅")
                        content = f"本次查阅 {native} {failed}"
                        self.ns["call_tool"] = AsyncMock(side_effect=RuntimeError("tool error")) if failed else AsyncMock(return_value=content)
                        first = ({"content": [{"type": "tool_use", "id": "t", "name": "breath_advanced", "input": {}}]}
                                 if native else {"tool_calls": [{"id": "t", "function": {"name": "breath_advanced", "arguments": "{}"}}]})
                        self.ns["native_complete" if native else "complete_chat"] = AsyncMock(side_effect=[first, RuntimeError("model failed")])
                        token = self.ns["MEMORY_TURN"].set({"session": "b", "message_id": mid, "write": True})
                        try:
                            with self.assertRaisesRegex(RuntimeError, "model failed"):
                                await self.ns["run_route_native" if native else "run_route_openai"]({}, [], session_id="b")
                        finally:
                            self.ns["MEMORY_TURN"].reset(token)
                        events = self.memory.reads("b", mid - 1, mid)
                        self.assertEqual(len(events), 0 if failed else 1)
                        if events:
                            self.assertEqual(events[0]["content"], content)
        asyncio.run(run())

    def test_unchanged_preview_reads_do_not_advance_handoff(self):
        self.add("a", "旧进展")
        first = self.add("b", "现在")
        self.prompt("b", first)
        self.add("a", "预览时尚未同步的新事")
        with closing(self.memory.connect()) as conn:
            before = list(conn.execute("SELECT * FROM handoffs"))
        self.memory.context("b", self.cfg)
        with closing(self.memory.connect()) as conn:
            after = list(conn.execute("SELECT * FROM handoffs"))
        self.assertEqual([tuple(r) for r in before], [tuple(r) for r in after])
        self.assertIn("预览时尚未同步的新事", str(self.prompt("b", self.add("b", "正式回来"))))

    def test_isolated_source_not_exported_and_directory_is_session_scoped(self):
        self.cfg["sessions"][0]["handoff_mode"] = "isolated"
        self.add("a", "独立窗秘密")
        self.assertNotIn("独立窗秘密", str(self.prompt("b", self.add("b", "hello"))))
        self.memory.record("a", 1, "breath", "A 的原文")
        eid = self.memory.record("b", 2, "breath", "B 的原文")
        listing = self.memory.read("b", 0)
        self.assertNotIn("A 的原文", listing)
        self.assertIn(f"id={eid}", listing)


if __name__ == "__main__":
    unittest.main()
