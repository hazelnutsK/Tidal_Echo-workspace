"""Offline call lifecycle and tool checks; never contact a phone or model."""
import ast
from contextlib import contextmanager
import datetime as dt
import json
from pathlib import Path
import sqlite3
import sys
import unittest
from unittest.mock import AsyncMock
from fastapi import HTTPException

from call_tools import CALL_TURN, new_call_turn, request_call

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import call_state


class ToolTests(unittest.IsolatedAsyncioTestCase):
    async def test_preview_never_rings(self):
        send = AsyncMock()
        token = CALL_TURN.set(new_call_turn("a", False))
        try:
            self.assertFalse(json.loads(await request_call({}, send))["ok"])
            send.assert_not_awaited()
        finally:
            CALL_TURN.reset(token)

    async def test_retries_use_one_invitation_even_with_different_text(self):
        send = AsyncMock(return_value=(True, {"id": 5, "status": "ringing"}))
        token = CALL_TURN.set(new_call_turn("a", True))
        try:
            first = await request_call({"text": "想听你说话"}, send)
            second = await request_call({"text": "changed"}, send)
            self.assertEqual(first, second)
            send.assert_awaited_once()
            self.assertEqual(send.call_args.args[0]["api_session"], "a")
        finally:
            CALL_TURN.reset(token)

    async def test_uncertain_delivery_is_not_retried(self):
        send = AsyncMock(side_effect=TimeoutError)
        token = CALL_TURN.set(new_call_turn("a", True))
        try:
            self.assertFalse(json.loads(await request_call({}, send))["ok"])
            await request_call({}, send)
            send.assert_awaited_once()
        finally:
            CALL_TURN.reset(token)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, ts TEXT, direction TEXT, kind TEXT, text TEXT, meta TEXT)")
        self.addCleanup(self.conn.close)
        @contextmanager
        def db():
            yield self.conn
        def save(direction, kind, text, meta):
            cur = self.conn.execute("INSERT INTO messages(ts,direction,kind,text,meta) VALUES(?,?,?,?,?)",
                (dt.datetime.now(dt.timezone.utc).isoformat(), direction, kind, text, json.dumps(meta)))
            self.conn.commit()
            return {"id": cur.lastrowid, "text": text, "meta": meta, "kind": kind, "direction": direction}
        def rows_to_messages(rows):
            return [{**dict(row), "meta": json.loads(row["meta"])} for row in rows]
        self.ns = {"call_state": call_state, "db": db, "json": json, "HTTPException": HTTPException,
            "datetime": dt.datetime, "timezone": dt.timezone,
            "session_body": lambda session: "loop", "call_is_live": lambda: False,
            "save_message": save, "broadcast": AsyncMock(), "app_subs": set(), "app_payload": lambda x: x,
            "rows_to_messages": rows_to_messages, "HUMAN_NAME": "她", "mark_call": lambda active: None,
            "route_inbound": AsyncMock()}
        source = Path(__file__).resolve().parents[1] / "backend" / "app.py"
        names = {"request_api_call", "handle_api_call_event", "publish_api_call_transition"}
        tree = ast.parse(source.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name in names]
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)

    async def invite(self, request="r1", session="a"):
        return await self.ns["request_api_call"]({"api_session": session, "call_request_id": request, "text": "想你"})

    async def event(self, action, **kwargs):
        return await self.ns["handle_api_call_event"]({"action": action, "api_session": "a", "call_id": "c1", **kwargs})

    async def test_invite_answer_opening_end_and_duplicate_events(self):
        invite = await self.invite()
        self.ns["route_inbound"].assert_not_awaited()
        self.assertEqual((await self.invite())["id"], invite["id"])
        await self.event("start")  # Existing iOS build, without message_id.
        await self.event("start")
        self.ns["route_inbound"].assert_awaited_once()
        start = self.ns["route_inbound"].call_args.args[0]
        self.assertEqual(start["meta"]["api_session"], "a")
        self.assertEqual(start["meta"]["call"], "start")
        self.assertIn("请先开口", start["text"])
        await self.event("decline", message_id=invite["id"])
        self.assertEqual(self.ns["route_inbound"].await_count, 1)
        await self.event("end")
        await self.event("end")
        self.assertEqual(self.ns["route_inbound"].await_count, 2)
        self.assertEqual(json.loads(call_state.for_call(self.conn, "c1")["meta"])["call_status"], "ended")

    async def test_busy_and_wrong_window_do_not_ring_or_answer(self):
        invite = await self.invite()
        with self.assertRaises(HTTPException) as exc:
            await self.invite("r2", "b")
        self.assertEqual(exc.exception.status_code, 409)
        for extra in ({}, {"message_id": invite["id"]}):
            with self.assertRaises(HTTPException):
                await self.event("start", api_session="b", **extra)
        self.ns["route_inbound"].assert_not_awaited()

    async def test_decline_then_answer_cannot_reopen(self):
        invite = await self.invite()
        await self.event("decline", message_id=invite["id"])
        await self.event("decline", message_id=invite["id"])
        with self.assertRaises(HTTPException):
            await self.event("start", message_id=invite["id"])
        self.ns["route_inbound"].assert_awaited_once()
        self.assertEqual(self.ns["route_inbound"].call_args.args[0]["meta"]["call"], "decline")

    async def test_timeout_marks_missed_once_and_preserves_session(self):
        invite = await self.invite()
        self.conn.execute("UPDATE messages SET ts='2000-01-01T00:00:00+00:00' WHERE id=?", (invite["id"],))
        self.assertIsNone(call_state.pending(self.conn))
        self.assertEqual(len(call_state.expired(self.conn)), 1)
        row, changed = call_state.transition(self.conn, invite["id"], "missed")
        self.assertTrue(changed)
        await self.ns["publish_api_call_transition"](row, "missed")
        self.assertEqual(call_state.expired(self.conn), [])
        self.assertFalse(call_state.transition(self.conn, invite["id"], "missed")[1])
        self.assertEqual(self.ns["route_inbound"].call_args.args[0]["meta"]["api_session"], "a")


if __name__ == "__main__":
    unittest.main()
