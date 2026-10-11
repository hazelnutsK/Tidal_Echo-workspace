"""Offline heartbeat tests; no private config, model requests, or real messages."""
import ast
import asyncio
import copy
from contextlib import closing
from contextvars import ContextVar
import datetime as dt
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
from typing import Any
import unittest
from unittest.mock import AsyncMock
import uuid
import httpx
from fastapi import HTTPException
from call_tools import CALL_TURN, new_call_turn, request_call


SOURCE = Path(__file__).with_name("api_loop.py")


class ProactiveTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.messages = [
            {"role": "system", "content": "fixed persona"},
            {"role": "system", "content": "fixed summary"},
            {"role": "system", "content": "fixed memory"},
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "previous reply"},
        ]
        self.route = {"url": "https://openrouter.ai/api/v1", "model": "anthropic/claude-fable-5"}
        self.out = {
            "content": [{"type": "text", "text": "刚刚想到你说的那件小事，想来陪你聊两句。"}],
            "stop": {"stop_reason": "end_turn"},
            "usage": {"cache_read_input_tokens": 18000, "cache_creation_input_tokens": 100,
                      "output_tokens": 40, "cost": .025},
        }
        self.sent = []
        self.bodies = []
        self.touches = []
        self.cfg = {}

        async def complete(route, body):
            self.bodies.append(copy.deepcopy(body))
            return copy.deepcopy(self.out)

        async def send(payload):
            self.sent.append(payload)
            return True, {"id": 123, "saved": True}

        self.ns = {
            "CALL_TURN": CALL_TURN, "new_call_turn": new_call_turn,
            "MEMORY_TURN": ContextVar("memory_turn", default=None),
            "json": json, "MCP_TOOL_ROUNDS": 8,
            "remember_memory_result": lambda session, name, result: result,
            "call_tool": AsyncMock(return_value="ok"),
            "MOMENTS_TURN": ContextVar("moments_turn", default=None),
            "Any": Any, "asyncio": asyncio, "dt": dt, "uuid": uuid, "httpx": httpx,
            "KA_STATE": {"last_real": 9500, "last_touch": 6900, "last_prefix": 18000, "bad": 0,
                         "events": [], "retry_count": 0, "next_retry_at": None},
            "KA_LOCK": asyncio.Lock(), "HISTORY_LOCKS": {}, "ACTIVE_CHAT_COUNT": 0, "CHAT_REVISION": 0,
            "KEEPALIVE_PROACTIVE": True, "KEEPALIVE_TEXT": "cache only",
            "KEEPALIVE_AFTER_MIN": 50, "KEEPALIVE_MAX_IDLE_H": 10,
            "KEEPALIVE_RETRY_DELAYS": (30, 60, 120),
            "CACHE_TTL": "1h", "CACHE_BREAKPOINTS_MAX": 4, "CACHE_MILESTONE_STEP": 16,
            "MAX_TOKENS": 2000, "THINKING_BUDGET": 1024, "TEMPERATURE": .7,
            "effort": lambda: "high", "time": SimpleNamespace(time=lambda: 10000),
            "keepalive_enabled": lambda: True, "main_chain": lambda: [self.route],
            "active_session_id": lambda: "session-a", "session_message_version": lambda _: 42,
            "relay_brain": AsyncMock(return_value="loop"), "now_iso": lambda: "now",
            "proactive_screen_context": lambda: "近一小时，已接入 App 记录到手机使用约 12.5 分钟",
            "build_messages": lambda text, **_: copy.deepcopy(self.messages) + [{"role": "user", "content": text}],
            "mcp_tool_defs": AsyncMock(return_value=[{"name": "memory"}]),
            "anthropic_tools": lambda defs: defs,
            "native_complete": complete, "relay_out": send,
            "reported_cost": lambda usage: usage.get("cost"),
            "load_config": lambda: copy.deepcopy(self.cfg),
            "save_config": lambda cfg: setattr(self, "cfg", copy.deepcopy(cfg)),
        }
        names = {"proactive_trigger", "proactive_reply", "keepalive_due", "keepalive_beat",
                 "_keepalive_beat", "_content_to_anthropic_blocks", "to_anthropic",
                 "mark_cache", "msg_cache_budget", "native_body", "run_model", "proactive_tools", "merge_usage",
                 "ka_load", "ka_touch", "keepalive_watcher", "heartbeat_error", "upstream_detail"}
        tree = ast.parse(SOURCE.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), "exec"), self.ns)
        touch = self.ns["ka_touch"]
        def record_touch(**kwargs):
            self.touches.append(kwargs)
            touch(**kwargs)
        self.ns["ka_touch"] = record_touch

    async def beat(self):
        return await self.ns["keepalive_beat"]()

    async def test_compaction_in_progress_skips_even_forced_heartbeat(self):
        lock = asyncio.Lock()
        self.ns["HISTORY_LOCKS"]["session-a"] = lock
        async with lock:
            self.assertEqual(await self.ns["keepalive_due"](), "busy")
            self.assertEqual(await self.ns["keepalive_beat"](force=True), {"ok": False, "reason": "busy"})
        self.assertEqual(self.bodies, [])

    async def test_delivery_preserves_prefix_settings_and_renews_window(self):
        result = await self.beat()
        self.assertEqual(result["delivery"], "sent")
        self.assertTrue(self.touches[-1]["real"])
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["api_session"], "session-a")
        self.assertTrue(self.sent[0]["is_push"])
        self.assertNotIn("system_trigger", self.sent[0]["final_text"])
        body = self.bodies[0]
        system, convo = self.ns["to_anthropic"](copy.deepcopy(self.messages))
        self.ns["mark_cache"](convo, self.ns["msg_cache_budget"](system))
        expected = self.ns["native_body"](self.route, system, convo, [{"name": "memory"}])
        for key in ("system", "tools", "thinking", "output_config", "provider", "max_tokens"):
            self.assertEqual(body[key], expected[key])
        self.assertEqual(body["messages"][:-1], expected["messages"])
        self.assertNotIn("cache_control", body["messages"][-1]["content"][-1])
        self.assertIn("手机使用约 12.5 分钟", body["messages"][-1]["content"][-1]["text"])
        self.assertEqual(body["messages"][-2]["content"][-1]["cache_control"]["ttl"], "1h")

    async def test_consecutive_user_keeps_shadow_outside_cache_boundary(self):
        self.messages.pop()
        await self.beat()
        blocks = self.bodies[0]["messages"][-1]["content"]
        self.assertIn("cache_control", blocks[-2])
        self.assertNotIn("cache_control", blocks[-1])

    async def test_silence_renews_without_delivery(self):
        self.out["content"][0]["text"] = "[[silent]]"
        result = await self.beat()
        self.assertEqual(result["delivery"], "silent")
        self.assertTrue(self.touches[-1]["real"])
        self.assertFalse(self.sent)

    async def test_new_input_during_generation_discards_reply(self):
        original = self.ns["native_complete"]

        async def changed(*args):
            out = await original(*args)
            self.ns["session_message_version"] = lambda _: 43
            return out

        self.ns["native_complete"] = changed
        result = await self.beat()
        self.assertEqual(result["delivery"], "superseded")
        self.assertFalse(self.sent)
        self.assertFalse(self.touches[-1]["real"])

    async def test_switching_session_during_generation_discards_reply(self):
        original = self.ns["native_complete"]

        async def changed(*args):
            out = await original(*args)
            self.ns["active_session_id"] = lambda: "session-b"
            return out

        self.ns["native_complete"] = changed
        self.assertEqual((await self.beat())["delivery"], "superseded")
        self.assertFalse(self.sent)

    async def test_concurrent_beats_only_generate_once(self):
        entered, release = asyncio.Event(), asyncio.Event()
        original = self.ns["native_complete"]

        async def delayed(*args):
            entered.set()
            await release.wait()
            return await original(*args)

        self.ns["native_complete"] = delayed
        first = asyncio.create_task(self.beat())
        await entered.wait()
        self.assertEqual((await self.beat())["reason"], "busy")
        release.set()
        await first
        self.assertEqual(len(self.sent), 1)

    async def test_active_normal_chat_skips_even_forced_beat(self):
        self.ns["ACTIVE_CHAT_COUNT"] = 1
        result = await self.ns["keepalive_beat"](force=True)
        self.assertEqual(result["reason"], "busy")
        self.assertFalse(self.bodies)

    async def test_delivery_error_does_not_renew_or_retry(self):
        self.ns["relay_out"] = AsyncMock(side_effect=TimeoutError)
        result = await self.beat()
        self.assertEqual(result["delivery"], "delivery_failed")
        self.assertFalse(self.touches[-1]["real"])
        self.ns["relay_out"].assert_awaited_once()

    async def test_upstream_error_releases_lock_and_records_failure(self):
        self.ns["native_complete"] = AsyncMock(side_effect=TimeoutError)
        self.assertFalse((await self.beat())["ok"])
        self.assertFalse(self.ns["KA_LOCK"].locked())
        self.assertEqual(self.ns["KA_STATE"]["bad"], 1)
        self.assertFalse(self.touches[-1]["real"])

    async def test_transport_failure_retries_three_times_then_stops(self):
        self.ns["native_complete"] = AsyncMock(side_effect=httpx.ReadError("disconnected"))
        now = 10000
        for attempt, delay in enumerate((30, 60, 120)):
            result = await self.beat()
            self.assertEqual(result["retry_attempt"], attempt)
            self.assertEqual(result["retry_in_s"], delay)
            self.assertEqual(await self.ns["keepalive_due"](), "retry_wait")
            self.assertEqual((await self.beat())["reason"], "retry_wait")
            now += delay
            self.ns["time"].time = lambda: now
            self.assertEqual(await self.ns["keepalive_due"](), "")
        self.assertTrue((await self.beat())["retry_exhausted"])
        self.assertEqual(await self.ns["keepalive_due"](), "circuit_broken")
        self.ns["native_complete"].assert_awaited()
        self.assertEqual(self.ns["native_complete"].await_count, 4)
        self.assertFalse(self.sent)
        # Restart must preserve both pending retries and the exhausted budget.
        self.ns["KA_STATE"].clear()
        self.ns["ka_load"]()
        self.assertEqual(await self.ns["keepalive_due"](), "circuit_broken")

    async def test_pending_retry_survives_restart_and_success_resets_schedule(self):
        self.ns["native_complete"] = AsyncMock(side_effect=[httpx.ReadError("disconnect"), self.out])
        await self.beat()
        self.ns["KA_STATE"].clear()
        self.ns["ka_load"]()
        self.assertEqual(self.ns["KA_STATE"]["retry_count"], 1)
        self.assertEqual(await self.ns["keepalive_due"](), "retry_wait")
        self.ns["time"].time = lambda: 10030
        self.assertEqual((await self.beat())["delivery"], "sent")
        self.assertEqual(self.ns["KA_STATE"]["retry_count"], 0)
        self.assertIsNone(self.ns["KA_STATE"]["next_retry_at"])
        self.assertEqual(await self.ns["keepalive_due"](), "not_due")
        self.ns["time"].time = lambda: 13029
        self.assertEqual(await self.ns["keepalive_due"](), "not_due")
        self.ns["time"].time = lambda: 13030
        self.assertEqual(await self.ns["keepalive_due"](), "")
        self.assertEqual(len(self.sent), 1)

    async def test_upgrade_recovers_legacy_failure_but_not_after_new_chat(self):
        event = {"at": dt.datetime.fromtimestamp(10000, dt.timezone.utc).isoformat(),
                 "status": "error", "error": "ReadError: "}
        for last_real, last_touch, expected in ((9500, 10000, 10030), (10020, 10020, None)):
            with self.subTest(last_real=last_real):
                self.cfg = {"ka_state": {"last_real": last_real, "last_touch": last_touch,
                                         "last_prefix": 18000, "events": [event]}}
                self.ns["ka_load"]()
                self.assertEqual(self.ns["KA_STATE"]["next_retry_at"], expected)

    async def test_real_chat_cancels_pending_retry_and_unblocks_exhaustion(self):
        self.ns["native_complete"] = AsyncMock(side_effect=TimeoutError)
        await self.beat()
        self.ns["ACTIVE_CHAT_COUNT"] = 1
        self.ns["time"].time = lambda: 10040
        self.assertEqual((await self.beat())["reason"], "busy")
        self.ns["ka_touch"](real=True)
        self.ns["ACTIVE_CHAT_COUNT"] = 0
        self.assertEqual(await self.ns["keepalive_due"](), "not_due")
        self.assertEqual(self.ns["KA_STATE"]["retry_count"], 0)
        self.assertIsNone(self.ns["KA_STATE"]["next_retry_at"])
        self.assertEqual(self.ns["KA_STATE"]["bad"], 0)

    async def test_stale_failure_does_not_overwrite_new_chat_schedule(self):
        async def fail_after_chat(*args):
            self.ns["CHAT_REVISION"] += 1
            self.ns["ka_touch"](real=True)
            raise httpx.ReadError("disconnected")
        self.ns["native_complete"] = fail_after_chat
        self.assertEqual((await self.beat())["reason"], "superseded")
        self.assertEqual(self.ns["KA_STATE"]["bad"], 0)
        self.assertIsNone(self.ns["KA_STATE"]["next_retry_at"])

    async def test_tool_stage_failure_does_not_schedule_replay(self):
        self.ns["proactive_tools"] = AsyncMock(side_effect=httpx.ReadError("after action"))
        result = await self.beat()
        self.assertEqual(result["status"], "error")
        self.assertNotIn("retry_in_s", result)
        self.assertIsNone(self.ns["KA_STATE"]["next_retry_at"])

    async def test_http_transient_errors_retry_but_auth_errors_do_not(self):
        for code in (400, 408, 409, 429, 503, 401, 403, 404):
            with self.subTest(code=code):
                self.ns["KA_STATE"].update(bad=0, retry_count=0, next_retry_at=None, last_touch=6900)
                response = httpx.Response(code, request=httpx.Request("POST", "https://example.test/messages"))
                self.ns["native_complete"] = AsyncMock(side_effect=httpx.HTTPStatusError("error", request=response.request, response=response))
                result = await self.beat()
                self.assertEqual("retry_in_s" in result, code in (400, 408, 409, 429, 503))
                self.assertEqual(result["http_status"], code)

    async def test_400_retry_recovers_and_saves_upstream_reason(self):
        response = httpx.Response(400, request=httpx.Request("POST", "https://example.test/messages"),
                                  json={"error": {"message": "Provider returned error", "metadata": {
                                      "raw": '{"error":{"message":"temporary validation failure"}}'}}})
        error = httpx.HTTPStatusError("bad request", request=response.request, response=response)
        self.ns["native_complete"] = AsyncMock(side_effect=[error, self.out])
        result = await self.beat()
        self.assertEqual(result["retry_in_s"], 30)
        saved = self.cfg["ka_state"]["events"][-1]
        self.assertEqual(saved["http_status"], 400)
        self.assertIn("temporary validation failure", saved["error_detail"])
        self.ns["time"].time = lambda: 10030
        self.assertEqual((await self.beat())["delivery"], "sent")
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.ns["KA_STATE"]["bad"], 0)

    async def test_persistent_400_stops_after_three_retries(self):
        response = httpx.Response(400, request=httpx.Request("POST", "https://example.test/messages"),
                                  json={"error": {"message": "invalid request"}})
        self.ns["native_complete"] = AsyncMock(side_effect=httpx.HTTPStatusError("bad", request=response.request, response=response))
        now = 10000
        for delay in (30, 60, 120):
            self.assertEqual((await self.beat())["retry_in_s"], delay)
            now += delay
            self.ns["time"].time = lambda: now
        self.assertTrue((await self.beat())["retry_exhausted"])
        self.assertEqual(await self.ns["keepalive_due"](), "circuit_broken")
        self.assertEqual(self.ns["native_complete"].await_count, 4)

    def test_error_details_preserve_http_exception_and_bound_redact_text(self):
        result = self.ns["heartbeat_error"](HTTPException(503, detail="provider unavailable"), self.route)
        self.assertEqual(result["http_status"], 503)
        self.assertEqual(result["error_detail"], "provider unavailable")
        response = httpx.Response(400, request=httpx.Request("POST", "https://example.test/messages"),
                                  text="echoed-test-key " + "x" * 2000)
        error = httpx.HTTPStatusError("bad", request=response.request, response=response)
        result = self.ns["heartbeat_error"](error, {"key": "echoed-test-key"})
        self.assertNotIn("echoed-test-key", result["error_detail"])
        self.assertLessEqual(len(result["error_detail"]), 1000)

    async def test_cache_only_success_clears_retry_state(self):
        self.ns["KEEPALIVE_PROACTIVE"] = False
        self.ns["native_complete"] = AsyncMock(side_effect=[TimeoutError(), self.out])
        await self.beat()
        self.ns["time"].time = lambda: 10030
        self.assertTrue((await self.beat())["ok"])
        self.assertIsNone(self.ns["KA_STATE"]["next_retry_at"])
        self.assertEqual(self.ns["KA_STATE"]["retry_count"], 0)
        self.assertEqual(await self.ns["keepalive_due"](), "not_due")

    async def test_watcher_checks_retry_deadline_every_ten_seconds(self):
        async def stop_after_one_poll(seconds):
            self.assertEqual(seconds, 10)
            raise asyncio.CancelledError
        self.ns["asyncio"] = SimpleNamespace(sleep=stop_after_one_poll)
        with self.assertRaises(asyncio.CancelledError):
            await self.ns["keepalive_watcher"]()

    async def test_normal_chat_counters_release_on_failure(self):
        self.ns["_run_model"] = AsyncMock(side_effect=TimeoutError)
        with self.assertRaises(TimeoutError):
            await self.ns["run_model"]([])
        self.assertEqual(self.ns["ACTIVE_CHAT_COUNT"], 0)
        self.assertEqual(self.ns["CHAT_REVISION"], 1)

    async def test_cache_only_mode_still_works(self):
        self.ns["KEEPALIVE_PROACTIVE"] = False
        result = await self.beat()
        self.assertEqual(result["status"], "hit")
        self.assertFalse(self.sent)
        self.assertFalse(self.touches[-1]["real"])

    async def test_call_is_available_without_prompt_nudging_and_rings_once(self):
        self.ns["mcp_tool_defs"] = AsyncMock(return_value=[{"name": "call"}])
        self.out["content"] = [{"type": "tool_use", "id": "c1", "name": "call", "input": {"text": "想听你说话"}}]
        self.out["stop"] = {"stop_reason": "tool_use"}
        async def call(name, args):
            return await request_call(args, self.ns["relay_out"])
        self.ns["call_tool"] = call
        result = await self.beat()
        self.assertEqual(result["delivery"], "call_requested")
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["type"], "call")
        self.assertEqual(self.sent[0]["api_session"], "session-a")
        self.assertNotIn("电话", self.ns["proactive_trigger"]())
        self.assertIsNone(CALL_TURN.get())

    async def test_stale_tool_decision_never_executes(self):
        self.out["content"] = [{"type": "tool_use", "id": "c1", "name": "memory", "input": {}}]
        self.out["stop"] = {"stop_reason": "tool_use"}
        original = self.ns["native_complete"]
        async def changed(*args):
            out = await original(*args)
            self.ns["CHAT_REVISION"] += 1
            return out
        self.ns["native_complete"] = changed
        self.assertEqual((await self.beat())["delivery"], "superseded")
        self.ns["call_tool"].assert_not_awaited()

    async def test_memory_tool_continues_to_plain_text(self):
        self.ns["native_complete"] = AsyncMock(side_effect=[
            {"content": [{"type": "tool_use", "id": "m1", "name": "memory", "input": {}}],
             "stop": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 5}}, self.out])
        result = await self.beat()
        self.assertEqual(result["delivery"], "sent")
        self.assertEqual(result["output"], 45)
        self.assertEqual(result["tools_used"], ["memory"])

    def test_incomplete_tool_and_action_outputs_are_not_delivered(self):
        variants = [
            {**self.out, "stop": {"stop_reason": "max_tokens"}},
            {**self.out, "content": [{"type": "tool_use", "name": "memory"}]},
            {**self.out, "content": [{"type": "text", "text": "[[timer:5]]"}]},
            {**self.out, "content": []},
            {**self.out, "content": [{"type": "text", "text": "OK"}]},
        ]
        for out in variants:
            with self.subTest(out=out):
                text, reason = self.ns["proactive_reply"](out)
                self.assertFalse(text)
                self.assertNotIn(reason, {"ready", "silent"})


class ScreenContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "relay.db"
        with closing(sqlite3.connect(self.path)) as conn, conn:
            conn.execute("CREATE TABLE screentime (id INTEGER PRIMARY KEY, ts TEXT, app TEXT, action TEXT)")
        self.now = dt.datetime(2026, 10, 3, 6, tzinfo=dt.timezone.utc)
        fixed_now = self.now

        class Clock(dt.datetime):
            @classmethod
            def now(cls, tz=None):
                return fixed_now.astimezone(tz)

        self.ns = {"dt": SimpleNamespace(datetime=Clock, timedelta=dt.timedelta, timezone=dt.timezone),
                   "sqlite3": sqlite3, "Path": Path, "RELAY_DB": str(self.path), "json": json,
                   "closing": closing}
        tree = ast.parse(SOURCE.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "proactive_screen_context"]
        self.assertEqual(len(nodes), 1)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), "exec"), self.ns)

    def events(self, *events):
        with closing(sqlite3.connect(self.path)) as conn, conn:
            conn.executemany("INSERT INTO screentime (ts, app, action) VALUES (?, ?, ?)",
                             [((self.now - dt.timedelta(minutes=ago)).isoformat(), name, action)
                              for ago, name, action in events])

    def summary(self):
        return self.ns["proactive_screen_context"]()

    def test_open_before_hour_is_not_carried_into_window(self):
        self.events((90, "阅读", "open"), (40, "阅读", "close"),
                    (30, "音乐", "open"), (25, "音乐", "close"))
        text = self.summary()
        self.assertIn("使用约 5.0 分钟", text)
        self.assertIn('最多是 "音乐"，约 5.0 分钟', text)

    def test_overlapping_sessions_do_not_double_total(self):
        self.events((60, "阅读", "open"), (45, "音乐", "open"),
                    (15, "音乐", "close"), (0, "阅读", "close"))
        text = self.summary()
        self.assertIn("使用约 60.0 分钟", text)
        self.assertIn('最多是 "阅读"，约 60.0 分钟', text)

    def test_unclosed_session_is_estimate_not_current_activity_claim(self):
        self.events((10, "阅读", "open"))
        text = self.summary()
        self.assertIn("使用约 10.0 分钟", text)
        self.assertIn("不能确定她此刻仍在使用", text)

    def test_stale_open_is_not_counted_as_current_hour(self):
        self.events((90, "阅读", "open"))
        self.assertIn("没有记录到", self.summary())

    def test_missing_and_empty_data_are_not_zero_usage(self):
        self.assertIn("不代表她没用手机", self.summary())
        with closing(sqlite3.connect(self.path)) as conn, conn:
            conn.execute("DROP TABLE screentime")
        self.assertIn("暂不可用", self.summary())
        self.path.unlink()
        self.assertIn("暂不可用", self.summary())
        self.assertFalse(self.path.exists())

    def test_subminute_activity_and_invalid_events(self):
        self.events((0.5, "阅读", "open"), (0, "阅读", "close"))
        with closing(sqlite3.connect(self.path)) as conn, conn:
            conn.execute("INSERT INTO screentime (ts, app, action) VALUES (?, ?, ?)",
                         ("2026-10-03T05:40:00", "bad", "open"))
        self.assertIn("使用约 0.5 分钟", self.summary())


if __name__ == "__main__":
    unittest.main()
