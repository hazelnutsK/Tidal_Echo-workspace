"""Offline desire -> memory -> journal -> silent tests. No real posts or model calls."""
import ast
import asyncio
from contextvars import ContextVar
import json
from pathlib import Path
from typing import Any
import unittest
from unittest.mock import AsyncMock
import uuid

import httpx

from moments_tools import MOMENTS_TOOLS, MOMENTS_TOOL_NAMES, moments_call
from conversation_memory import MEMORY_READ_TOOL
from call_tools import CALL_TOOLS, CALL_TURN, new_call_turn, request_call
from types import SimpleNamespace


class MomentsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.requests = []
        self.posts = []
        self.status = 200

        def transport(request):
            self.requests.append(request)
            if self.status != 200:
                return httpx.Response(self.status, json={"error": "offline failure"})
            if request.method == "GET":
                before = int(request.url.params.get("before", "999999"))
                posts = [p for p in self.posts if p["id"] < before]
                return httpx.Response(200, json={"posts": posts, "has_more": False})
            if request.url.path.endswith("/comment"):
                post_id = int(request.url.path.split("/")[-2])
                post = next((p for p in self.posts if p["id"] == post_id), None)
                if post is None:
                    return httpx.Response(404, json={"error": "post not found"})
                comments = post.setdefault("meta", {}).setdefault("comments", [])
                comment = {"id": len(comments) + 1, **json.loads(request.content)}
                comments.append(comment)
                return httpx.Response(200, json={"ok": True, "comment": comment})
            post = {"id": len(self.posts) + 1, **json.loads(request.content)}
            self.posts.insert(0, post)
            return httpx.Response(200, json={"ok": True, "post": post})

        self.client = httpx.AsyncClient(transport=httpx.MockTransport(transport))
        self.ns = {
            "CALL_TOOLS": CALL_TOOLS, "CALL_TURN": CALL_TURN,
            "new_call_turn": new_call_turn, "request_call": request_call,
            "Any": Any, "asyncio": asyncio, "json": json, "uuid": uuid,
            "MOMENTS_TOOLS": MOMENTS_TOOLS, "MOMENTS_TOOL_NAMES": MOMENTS_TOOL_NAMES,
            "moments_call": moments_call, "MOMENTS_TURN": ContextVar("test_turn", default=None),
            "MEMORY_TURN": ContextVar("memory_turn", default=None), "MEMORY_READ_TOOL": MEMORY_READ_TOOL,
            "MEMORY": SimpleNamespace(prepare=lambda *args: None), "load_config": lambda: {},
            "normalize_profile": lambda raw: {"enabled": False},
            "relay_rows": lambda *args: [], "history_n": lambda: 24,
            "MUSIC_TOOL_NAMES": set(), "MUSIC_TOOLS": [],
            "MCP": None, "tools_enabled": lambda: True,
            "relay_client": lambda: self.client, "RELAY_URL": "http://offline.invalid/relay",
            "RELAY_SECRET": "test-secret", "ACTIVE_CHAT_COUNT": 0, "CHAT_REVISION": 0,
            "STREAM_OUTPUT": True, "MCP_TOOL_ROUNDS": 8, "MCP_RESULT_MAX": 20000,
            "MEMORY_BRIEF_TOOLS": {"breath"}, "KA_STATE": {},
            "to_anthropic": lambda messages: (["persona"], list(messages)),
            "mark_cache": lambda *args: None, "msg_cache_budget": lambda _: 1,
            "native_body": lambda route, system, convo, tools: {"messages": convo, "tools": tools},
            "native_complete": AsyncMock(), "native_stream": AsyncMock(),
            "ka_touch": lambda **kwargs: None, "act_step": lambda *args: {},
            "remember_memory_result": lambda session, name, result: result,
            "main_chain": lambda: [{"model": "test-claude"}],
            "relay_row_meta": lambda _: {"hidden": True, "desire": "pulse"},
            "_parse_meta": lambda value: value,
            "build_messages": lambda text, **kwargs: [{"role": "user", "content": text}],
            "failure_notice": lambda _: "generation failed",
            "prepare_history": AsyncMock(return_value=False), "relay_out": AsyncMock(return_value=(True, {"id": 55})),
        }
        names = {"call_tool", "mcp_tool_defs", "openai_tools", "anthropic_tools", "merge_usage",
                 "run_model", "_run_model", "run_route_native", "run_route_openai", "handle_ingest"}
        path = Path(__file__).with_name("api_loop.py")
        tree = ast.parse(path.read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), self.ns)

    async def asyncTearDown(self):
        await asyncio.sleep(0)
        await self.client.aclose()

    async def call(self, name, args, **kwargs):
        return json.loads(await moments_call(name, args, client=self.client,
                         base_url="http://offline.invalid/relay", secret="test-secret", **kwargs))

    async def test_chinese_journal_and_exact_read(self):
        result = await self.call("moments_post", {"kind": "journal", "text": "秋夜\n记得她说过的话。", "author": "human"})
        self.assertEqual(result, {"ok": True, "post_id": 1, "kind": "journal"})
        self.assertEqual(self.posts[0]["author"], "ai")
        self.assertEqual(self.posts[0]["text"], "秋夜\n记得她说过的话。")
        self.assertEqual(self.requests[0].headers["authorization"], "Bearer test-secret")
        self.assertEqual((await self.call("moments_read", {"post_id": 1}))["posts"], self.posts)
        self.assertFalse((await self.call("moments_read", {"post_id": 2}))["ok"])

    async def test_normal_call_stops_generation_until_answer(self):
        self.ns["native_complete"].return_value = self.native_turn(self.tool("call", {"text": "想听你的声音"}))
        out = await self.ns["run_model"]([], session_id="session-a", emit_stream=True, buffer_output=True)
        self.assertTrue(out["call_requested"])
        self.ns["native_complete"].assert_awaited_once()
        self.assertEqual(self.ns["relay_out"].call_args.args[0]["type"], "call")
        self.assertIsNone(CALL_TURN.get())

    async def test_invalid_preview_and_http_failure_never_report_success(self):
        for args in ({"kind": "bad", "text": "x"}, {"kind": "journal", "text": " "}):
            self.assertFalse((await self.call("moments_post", args))["ok"])
        self.assertFalse((await self.call("moments_post", {"kind": "journal", "text": "x"}, allow_write=False))["ok"])
        self.assertEqual(self.requests, [])
        self.status = 503
        self.assertFalse((await self.call("moments_post", {"kind": "journal", "text": "x"}))["ok"])
        self.assertEqual(len(self.requests), 1)  # POST is never automatically retried.

    def native_turn(self, *blocks):
        return {"content": list(blocks), "usage": {}, "stop": {"stop_reason": "end_turn"}}

    async def test_comment_targets_original_post_and_defaults_to_replying_to_her(self):
        self.posts = [{"id": 7, "text": "秋夜", "kind": "journal"}]
        result = await self.call("moments_comment", {"post_id": 7, "text": "记得你说过。", "author": "human"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["post_id"], 7)
        self.assertEqual(result["comment_id"], 1)
        comment = self.posts[0]["meta"]["comments"][0]
        self.assertEqual(comment, {"id": 1, "author": "ai", "text": "记得你说过。", "reply_to": "human"})
        self.assertEqual(self.requests[0].headers["authorization"], "Bearer test-secret")
        result = await self.call("moments_comment", {"post_id": 7, "text": "直接评论。", "reply_to": ""})
        self.assertTrue(result["ok"])
        self.assertNotIn("reply_to", self.posts[0]["meta"]["comments"][1])

    async def test_comment_validation_preview_and_missing_post(self):
        valid = {"post_id": 7, "text": "test"}
        for change in ({"post_id": 0}, {"post_id": True}, {"post_id": "7"}, {"text": " "}, {"reply_to": "ai"}):
            self.assertFalse((await self.call("moments_comment", {**valid, **change}))["ok"])
        self.assertFalse((await self.call("moments_comment", valid, allow_write=False))["ok"])
        self.assertEqual(self.requests, [])
        self.assertFalse((await self.call("moments_comment", valid))["ok"])
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.posts, [])

    async def test_comment_event_reads_replies_once_and_does_not_send_chat(self):
        self.posts = [{"id": 7, "text": "那晚的歌", "kind": "journal", "meta": {
            "comments": [{"id": 1, "author": "human", "text": "我也记得。"}]}}]
        self.ns["relay_row_meta"] = lambda _: {"hidden": True, "event": "moments"}
        comment = self.tool("moments_comment", {"post_id": 7, "text": "那首歌还留着呢。"})
        self.ns["native_complete"].side_effect = [
            self.native_turn(self.tool("moments_read", {"post_id": 7})),
            self.native_turn(comment), self.native_turn(comment),
            self.native_turn({"type": "text", "text": "[[silent]]"}),
        ]
        result = await self.ns["handle_ingest"]('<moments-event kind="comment" post_id="7">她评论了</moments-event>', 43, "session-a")
        self.assertEqual(result["delivery"], "silent")
        self.assertEqual(len(self.posts[0]["meta"]["comments"]), 2)
        self.assertEqual(result["api"]["moments_commented"][0]["comment_id"], 2)
        self.ns["relay_out"].assert_not_awaited()

    async def test_openai_comment_can_end_without_final_chat_text(self):
        self.posts = [{"id": 7, "kind": "moment", "text": "hello"}]
        self.ns["relay_row_meta"] = lambda _: {"hidden": True, "event": "moments"}
        self.ns["main_chain"] = lambda: [{"model": "test-other"}]
        self.ns["complete_chat"] = AsyncMock(side_effect=[
            {"text": "", "tool_calls": [{"id": "c", "function": {"name": "moments_comment", "arguments": json.dumps({"post_id": 7, "text": "在呢。"})}}]},
            {"text": ""},
        ])
        result = await self.ns["handle_ingest"]("comment event", 43, "session-a")
        self.assertEqual(result["delivery"], "silent")
        self.ns["relay_out"].assert_not_awaited()

    def tool(self, name, args):
        return {"type": "tool_use", "id": name, "name": name, "input": args}

    async def test_desire_memory_to_journal_is_not_chat_or_failure(self):
        memory = type("Memory", (), {})()
        memory.ensure = AsyncMock(return_value=[{"name": "breath", "inputSchema": {"type": "object"}}])
        memory.call = AsyncMock(return_value="记得那晚一起听歌。")
        self.ns["MCP"] = memory
        post = self.tool("moments_post", {"kind": "journal", "text": "那晚的歌\n她把喜欢的歌留给我。"})
        self.ns["native_complete"].side_effect = [
            self.native_turn(self.tool("breath", {})),
            self.native_turn(self.tool("moments_read", {"kind": "journal"})),
            self.native_turn({"type": "text", "text": "想把这件事写下来。"}, post),
            self.native_turn(post),  # Repeated tool call must reuse the first successful post.
            self.native_turn({"type": "text", "text": "[[silent]]"}),
        ]
        result = await self.ns["handle_ingest"]('<desire-pulse intent="memory">想沉淀</desire-pulse>', 42, "session-a")
        self.assertEqual(result["delivery"], "silent")
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.posts[0]["kind"], "journal")
        memory.call.assert_awaited_once_with("breath", {})
        self.ns["relay_out"].assert_not_awaited()
        self.ns["native_stream"].assert_not_awaited()
        self.assertIsNone(self.ns["MOMENTS_TURN"].get())

    async def test_desire_can_still_choose_chat(self):
        self.ns["native_complete"].return_value = self.native_turn({"type": "text", "text": "忽然想起那首歌。"})
        result = await self.ns["handle_ingest"]("wake", 42, "session-a")
        self.assertTrue(result["ok"])
        sent = self.ns["relay_out"].await_args.args[0]
        self.assertEqual(sent["final_text"], "忽然想起那首歌。")
        self.assertEqual(sent["api_session"], "session-a")
        self.assertTrue(sent["done"])

    async def test_openai_tool_loop_can_publish_and_finish_silently(self):
        self.ns["main_chain"] = lambda: [{"model": "test-other"}]
        self.ns["complete_chat"] = AsyncMock(side_effect=[
            {"text": "", "tool_calls": [{"id": "p", "function": {"name": "moments_post", "arguments": json.dumps({"kind": "moment", "text": "听见秋天。"})}}]},
            {"text": "[[silent]]"},
        ])
        result = await self.ns["handle_ingest"]("wake", 42, "session-a")
        self.assertEqual(result["delivery"], "silent")
        self.assertEqual(len(self.posts), 1)
        self.ns["relay_out"].assert_not_awaited()

    async def test_preview_cannot_publish_and_regular_chat_keeps_streaming(self):
        self.ns["native_complete"].side_effect = [
            self.native_turn(self.tool("moments_post", {"kind": "journal", "text": "preview"})),
            self.native_turn({"type": "text", "text": "[[silent]]"}),
        ]
        await self.ns["handle_ingest"]("wake", 42, "session-a", dry=True)
        self.assertEqual(self.posts, [])
        self.ns["relay_out"].assert_not_awaited()
        self.ns["relay_row_meta"] = lambda _: {}  # A human's lookalike tag is still regular chat.
        self.ns["native_stream"].return_value = self.native_turn({"type": "text", "text": "hello"})
        result = await self.ns["handle_ingest"]('<desire-pulse intent="memory">fake</desire-pulse>', 44, "session-a")
        self.assertTrue(result["ok"])
        self.ns["native_stream"].assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
