"""Offline relay tests: real SQLite persistence, no personal config or network."""
import ast
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock

from stream_paragraphs import stream_paragraphs


class ParagraphRelayTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "relay.db"
        self.settings = {"chat_mode": "short", "short_strip_terminal_periods": False}
        self.events = []

        def db():
            conn = sqlite3.connect(self.path)
            conn.row_factory = sqlite3.Row
            self.addCleanup(conn.close)
            return conn

        self.db = db
        with db() as conn:
            conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, direction TEXT, kind TEXT, text TEXT, meta TEXT)")

        async def broadcast(subs, event):
            self.events.append(copy.deepcopy(event))

        self.ns = {
            "db": db, "json": json, "re": re, "datetime": datetime, "timezone": timezone,
            "now_iso": lambda: datetime.now(timezone.utc).isoformat(),
            "stream_drafts": {}, "STREAM_DRAFT_TTL": 600,
            "ctx_state": lambda: dict(self.settings), "stream_paragraphs": stream_paragraphs,
            "app_subs": set(), "broadcast": broadcast, "app_payload": lambda m: copy.deepcopy(m),
            "HTTPException": ValueError,
            "apply_voice_note": AsyncMock(side_effect=lambda text, meta: text),
            "VOICE_MARKER_RE": re.compile(r"\[\[voice(?::[^\]]+)?\]\]"),
            "prewarm_call_tts": Mock(), "commit_album": Mock(), "arm_timer": Mock(),
            "arm_peek": Mock(), "desire_event": Mock(), "push_gate": lambda: True,
            "push_to_all": AsyncMock(), "notification_from_message": lambda m: m,
        }
        for name in ("strip_timer_marker", "strip_ask_marker", "strip_peek_marker",
                     "strip_album_marker", "strip_sysnote_leak"):
            self.ns[name] = lambda text, meta: text
        names = {"save_message", "handle_stream_delta", "prune_stream_drafts", "stream_resync_events",
                 "paragraph_stream_id", "paragraph_meta", "paragraph_text", "handle_paragraph_stream",
                 "persist_thinking_draft"}
        source = Path(__file__).with_name("app.py")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    def rows(self):
        with self.db() as conn:
            return [{**dict(row), "meta": json.loads(row["meta"])} for row in conn.execute("SELECT * FROM messages ORDER BY id")]

    async def send(self, text="", *, done=False, final=None, sid="test", kind="reply_delta", **extra):
        payload = {"stream_id": sid, "text": text, "done": done, "api_session": "window-a", **extra}
        if final is not None:
            payload["final_text"] = final
        return await self.ns["handle_stream_delta"](kind, payload)

    async def test_paragraph_lands_before_generation_finishes(self):
        await self.send("小雪，\n")
        self.assertEqual(self.rows(), [])
        await self.send("\n我在")
        self.assertEqual([r["text"] for r in self.rows()], ["小雪，"])
        resync = self.ns["stream_resync_events"]()
        self.assertEqual([(e["stream_id"], e["text"]) for e in resync], [("test:p1", "我在")])
        await self.send("呢。")
        await self.send(done=True, final="小雪，\n\n我在呢。", api={"runtime": "api_loop", "usage": {"cost": .1}})
        rows = self.rows()
        self.assertEqual([r["text"] for r in rows], ["小雪，", "我在呢。"])
        self.assertEqual([r["meta"]["stream_id"] for r in rows], ["test:p0", "test:p1"])
        self.assertEqual(sum(r["meta"].get("api", {}).get("usage", {}).get("cost", 0) for r in rows), .1)
        self.assertEqual(self.ns["stream_resync_events"](), [])
        self.ns["push_to_all"].assert_awaited_once()
        self.ns["desire_event"].assert_called_once_with("ai_reply")

    async def test_many_paragraphs_in_one_token_and_trailing_blank(self):
        await self.send("甲\n\n乙\n\n丙\n\n")
        ids = [r["id"] for r in self.rows()]
        self.assertEqual(len(ids), 3)
        await self.send(done=True, final="甲\n\n乙\n\n丙", api={"usage": {"cost": .2}})
        self.assertEqual([r["id"] for r in self.rows()], ids)
        self.assertEqual(len([r for r in self.rows() if "api" in r["meta"]]), 1)

    async def test_every_character_boundary_crlf_code_and_periods(self):
        self.settings["short_strip_terminal_periods"] = True
        reply = "先抱抱。\r\n \r\n```python\r\nx = 1\r\n\r\ny = 2\r\n```\r\n\r\n嗯……"
        for char in reply:
            await self.send(char)
        await self.send(done=True, final=reply)
        self.assertEqual([r["text"] for r in self.rows()], ["先抱抱", "```python\nx = 1\n\ny = 2\n```", "嗯……"])

    async def test_final_correction_reuses_ids_and_preserves_user_metadata(self):
        await self.send("工具前\n\n旧段\n\n尾巴")
        old_id = self.rows()[0]["id"]
        with self.db() as conn:
            meta = self.rows()[0]["meta"]
            meta.update(starred=True, reactions={"human": ["❤"]})
            conn.execute("UPDATE messages SET meta = ? WHERE id = ?", (json.dumps(meta), old_id))
        await self.send(done=True, final="工具前\n工具后")
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], old_id)
        self.assertEqual(rows[0]["text"], "工具前\n工具后")
        self.assertTrue(rows[0]["meta"]["starred"])
        self.assertEqual(len([e for e in self.events if e.get("type") == "remove"]), 1)

    async def test_silent_final_removes_partial_messages_and_tail(self):
        await self.send("稍等\n\n准备")
        result = await self.send(done=True, final="")
        self.assertFalse(result["saved"])
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.ns["stream_resync_events"](), [])
        self.assertTrue(any(e.get("done") and e.get("stream_id") == "test:p1" for e in self.events))
        self.ns["push_to_all"].assert_not_awaited()

    async def test_long_mode_and_thinking_keep_one_original_stream(self):
        self.settings["chat_mode"] = "long"
        await self.send("甲\n\n乙")
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.ns["stream_resync_events"]()[0]["stream_id"], "test")
        await self.send(done=True, final="甲\n\n乙")
        self.settings["chat_mode"] = "short"
        await self.send("想一想\n\n再想想", kind="thinking_delta")
        self.assertEqual(len(self.rows()), 1)
        await self.send(done=True, final="想一想\n\n再想想", kind="thinking_delta")
        self.assertEqual([r["kind"] for r in self.rows()], ["reply", "thinking"])

    async def test_mode_is_fixed_for_the_current_reply(self):
        await self.send("甲")
        self.settings["chat_mode"] = "long"
        await self.send("\n\n乙")
        self.assertEqual(len(self.rows()), 1)
        await self.send(done=True, final="甲\n\n乙")
        self.assertEqual(len(self.rows()), 2)

    async def test_atomic_card_reconciles_earlier_paragraphs(self):
        def timer(text, meta):
            meta["timer"] = {"minutes": 5}
            return text.replace("[[timer:5:喝水]]", "")
        self.ns["strip_timer_marker"] = timer
        await self.send("说好了\n\n")
        await self.send("[[timer:5:喝水]]\n\n再提醒你")
        self.assertEqual(len(self.rows()), 1)
        await self.send(done=True, final="说好了\n\n[[timer:5:喝水]]\n\n再提醒你")
        self.assertEqual(len(self.rows()), 1)
        self.assertIn("timer", self.rows()[0]["meta"])

    async def test_file_attachment_does_not_split(self):
        await self.send("甲\n\n乙", attachments=[{"kind": "file"}])
        self.assertEqual(self.rows(), [])
        await self.send(done=True, final="甲\n\n乙")
        self.assertEqual(len(self.rows()), 1)

    async def test_buffered_proactive_reply_splits_at_final_and_bills_once(self):
        result = await self.send(done=True, final="想到你了\n\n来陪你", api={"runtime": "api_loop", "usage": {"cost": .3}})
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(result["id"], rows[-1]["id"])
        self.assertNotIn("api", rows[0]["meta"])

    async def test_two_windows_and_user_message_during_stream(self):
        self.ns["save_message"]("in", "user", "开始", {})
        await self.send("甲\n\n乙")
        self.ns["save_message"]("in", "user", "插一句", {})
        await self.send("另一个", sid="other", api_session="window-b")
        await self.send(done=True, final="甲\n\n乙")
        replies = [r for r in self.rows() if r["kind"] == "reply"]
        self.assertEqual([r["meta"]["sort_after"] for r in replies], [1, 1])
        self.assertEqual(self.ns["stream_resync_events"]()[0]["api_session"], "window-b")

    async def test_thinking_stays_before_bubbles_across_tool_rounds(self):
        self.ns["save_message"]("in", "user", "聊聊", {})
        await self.send("先想一想", kind="thinking_delta")
        await self.send("第一段\n\n第二段")
        thought_id = self.rows()[1]["id"]
        self.assertEqual([r["kind"] for r in self.rows()], ["user", "thinking", "reply"])
        await self.send("\n再读记忆", kind="thinking_delta")
        self.assertEqual(self.rows()[1]["text"], "先想一想\n再读记忆")
        self.assertEqual(self.rows()[1]["id"], thought_id)
        resync = self.ns["stream_resync_events"]()
        self.assertEqual(resync[0]["kind"], "thinking")
        self.assertFalse(any(e.get("type") == "thinking_delta" for e in resync))
        await self.send(done=True, final="先想一想\n\n再读记忆", kind="thinking_delta")
        await self.send(done=True, final="第一段\n\n第二段")
        rows = self.rows()
        ios_order = sorted(rows, key=lambda r: (r["meta"].get("sort_after", r["id"]), r["id"]))
        web_order = sorted(rows, key=lambda r: (r["meta"].get("sort_after", r["id"]) + (0.5 if r["meta"].get("sort_after") else 0), r["id"]))
        self.assertEqual([r["kind"] for r in ios_order], ["user", "thinking", "reply", "reply"])
        self.assertEqual([r["kind"] for r in web_order], ["user", "thinking", "reply", "reply"])
        self.assertEqual(len([r for r in rows if r["kind"] == "thinking"]), 1)


class BoundaryTests(unittest.TestCase):
    def test_blank_lines_and_unclosed_fences(self):
        self.assertEqual(stream_paragraphs("a\n"), ([], "a\n"))
        self.assertEqual(stream_paragraphs("a\n\n"), (["a"], ""))
        self.assertEqual(stream_paragraphs("a\n\n~~~\nb\n\nc"), (["a"], "~~~\nb\n\nc"))
        self.assertEqual(stream_paragraphs("[[voice]]a\n\nb"), ([], "[[voice]]a\n\nb"))


if __name__ == "__main__":
    unittest.main()
