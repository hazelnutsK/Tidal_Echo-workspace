"""Offline regressions for bubble counting and atomic history/summary paging."""
import ast
import asyncio
import copy
from contextlib import closing
import datetime as dt
import json
from pathlib import Path
import re
import sqlite3
import tempfile
from typing import Any
import unittest
from unittest.mock import AsyncMock
from unittest.mock import Mock

from conversation_memory import ConversationMemory, data_message


class HistoryCacheTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.db = root / 'relay.db'
        with closing(sqlite3.connect(self.db)) as c, c:
            c.execute('CREATE TABLE messages(id INTEGER PRIMARY KEY,ts TEXT,direction TEXT,kind TEXT,text TEXT,meta TEXT)')
        self.memory = ConversationMemory(root / 'memory.db', self.db, root / 'forge')
        self.cfg = {'sessions': [{'id': 'a', 'title': 'A'}], 'history_anchors': {},
                    'summaries': {}, 'history_turns': 2}
        self.saved = []

        def save(cfg):
            self.cfg = copy.deepcopy(cfg)
            self.saved.append(copy.deepcopy(cfg))

        self.fold = AsyncMock(return_value='new summary')
        self.ns = {
            'Any': Any, 'Path': Path, 'sqlite3': sqlite3, 'closing': closing,
            'json': json, 'asyncio': asyncio, 'dt': dt, 're': re,
            'RELAY_DB': str(self.db), 'HISTORY_N': 48, 'HISTORY_LOCKS': {},
            'SUMMARY_INFLIGHT': set(), 'load_config': lambda: copy.deepcopy(self.cfg),
            'SUMMARY_RETRY_AFTER': {}, 'SUMMARY_TIMEOUT_SECONDS': 180,
            'SUMMARY_RETRY_COOLDOWN_SECONDS': 600, 'time': Mock(monotonic=Mock(return_value=1000)),
            'save_config': save, 'fold_summary': self.fold, 'summary_route': lambda: {'model': 'fake'},
            'now_iso': lambda: '2026-10-04T00:00:00+00:00', 'MEMORY': self.memory,
            'PERSONA': 'fixed persona', 'memory_brief': lambda _: '', 'data_message': data_message,
            'MEMORY_BRIEF_HEADER': 'brief', '_assistant_trace': lambda _: '',
            '_image_parts_from_meta': lambda _: [], '_WEEKDAYS': ['一'] * 7,
        }
        names = {'history_n', 'history_turns', 'relay_rows', 'history_rounds', 'prepare_history',
                 'summary_lines', 'session_summary', '_parse_meta', 'build_messages',
                 'time_context', 'relay_msg_ts', 'relay_row_meta', '_wrap_content', 'inbound_source_prefix',
                 'record_summary_event'}
        path = Path(__file__).with_name('api_loop.py')
        tree = ast.parse(path.read_text(encoding='utf-8'))
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
        self.assertEqual({n.name for n in nodes}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), self.ns)

    def add(self, direction, text, **meta):
        with closing(sqlite3.connect(self.db)) as c, c:
            return c.execute('INSERT INTO messages(ts,direction,kind,text,meta) VALUES(?,?,?,?,?)',
                             ('2026-10-04T00:00:00+00:00', direction,
                              'user' if direction == 'in' else 'reply', text,
                              json.dumps({'api_session': 'a', **meta}))).lastrowid

    def turn(self, number, bubbles=1):
        start = self.add('in', f'user {number}', reply_bundle_id=f'b{number}')
        for i in range(bubbles):
            self.add('out', f'reply {number} paragraph {i}',
                     stream_parent=f's{number}', stream_id=f's{number}:p{i}')
        return start

    def rows(self):
        return self.ns['relay_rows'](None, 'a', 2)

    def prompt(self):
        return self.ns['build_messages']('next', session_id='a')

    async def test_bubbles_and_inbound_bundle_count_as_one_turn(self):
        self.add('in', 'first', reply_bundle_id='b')
        self.add('in', 'second', reply_bundle_id='b')
        for i in range(20):
            self.add('out', str(i), stream_parent='same', stream_id=f'same:p{i}')
        self.assertEqual(len(self.ns['history_rounds'](self.rows())), 1)
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.fold.assert_not_awaited()

    async def test_proactive_generations_are_separate_turns(self):
        self.turn(1, 3)
        for name in ['proactive-1', 'proactive-2']:
            for i in range(3):
                self.add('out', name, stream_parent=name, stream_id=f'{name}:p{i}', is_push=True)
        self.assertEqual([len(r) for r in self.ns['history_rounds'](self.rows())], [4, 3, 3])

    async def test_legacy_unsplit_messages_count_as_pairs(self):
        for _ in range(4):
            self.add('in', 'hello')
            self.add('out', 'reply')
        self.assertEqual(len(self.ns['history_rounds'](self.rows())), 4)

    async def test_heartbeat_and_preview_reads_never_page(self):
        for i in range(6):
            self.turn(i, 3)
        before = copy.deepcopy(self.cfg)
        prompt = self.prompt()
        self.assertEqual(prompt, self.prompt())
        self.assertEqual(self.cfg, before)
        self.assertEqual(len(self.rows()), 24)
        self.fold.assert_not_awaited()

    async def test_summary_and_anchor_commit_together_and_keep_whole_turns(self):
        starts = [self.turn(i, 4) for i in range(4)]
        self.assertTrue(await self.ns['prepare_history']('a', None))
        self.assertEqual(len(self.saved), 1)
        self.assertEqual(self.cfg['history_anchors']['a'], starts[2] - 1)
        self.assertEqual(self.cfg['summaries']['a']['covers_to'], starts[2] - 1)
        self.assertEqual(len(self.rows()), 10)
        self.assertEqual(self.rows()[0]['text'], 'user 2')
        self.assertEqual(self.rows()[-1]['text'], 'reply 3 paragraph 3')
        self.assertIn('reply 1 paragraph 3', str(self.fold.call_args))
        self.assertNotIn('user 2', str(self.fold.call_args))
        with closing(self.memory.connect()) as c:
            self.assertEqual(c.execute('SELECT page FROM handoffs WHERE session="a"').fetchone()[0], starts[2] - 1)
        stable = self.prompt()
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.assertEqual(stable, self.prompt())
        self.fold.assert_awaited_once()

    async def test_old_context_survives_while_summary_is_in_flight(self):
        for i in range(4):
            self.turn(i)
        entered, release = asyncio.Event(), asyncio.Event()
        async def delayed(*args):
            entered.set()
            await release.wait()
            return 'new summary'
        self.fold.side_effect = delayed
        before = self.prompt()
        task = asyncio.create_task(self.ns['prepare_history']('a', None))
        await entered.wait()
        self.assertEqual(self.prompt(), before)
        self.assertEqual(self.saved, [])
        release.set()
        await task
        self.assertIn('new summary', str(self.prompt()))
        self.assertNotIn('user 0', str(self.prompt()))

    async def test_summary_failure_preserves_all_history_and_prefix(self):
        for i in range(4):
            self.turn(i, 3)
        before = self.prompt()
        self.fold.side_effect = RuntimeError('offline failure')
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.assertEqual(self.prompt(), before)
        self.assertEqual(self.saved, [])
        self.assertEqual(len(self.rows()), 16)

    async def test_concurrent_preparations_do_not_double_summarize(self):
        for i in range(4):
            self.turn(i)
        result = await asyncio.gather(*(self.ns['prepare_history']('a', None) for _ in range(2)))
        self.assertEqual(result, [True, False])
        self.fold.assert_awaited_once()
        events = self.cfg['summary_events']
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['at'], self.cfg['summaries']['a']['updated_at'])
        self.assertEqual(events[0]['covers_to'], self.cfg['summaries']['a']['covers_to'])
        self.assertEqual(events[0]['reason'], 'compact')

    async def test_timeout_cooldown_skips_retry_then_recovers(self):
        for i in range(4):
            self.turn(i)
        before = self.prompt()
        self.fold.side_effect = TimeoutError()
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.ns['time'].monotonic.return_value = 1599
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.fold.assert_awaited_once()
        self.assertEqual(self.prompt(), before)
        self.assertEqual(self.saved, [])
        self.ns['time'].monotonic.return_value = 1600
        self.fold.side_effect = None
        self.assertTrue(await self.ns['prepare_history']('a', None))
        self.assertEqual(self.fold.await_count, 2)
        self.assertNotIn('a', self.ns['SUMMARY_RETRY_AFTER'])

    async def test_other_session_cooldown_does_not_block_compaction(self):
        for i in range(4):
            self.turn(i)
        self.ns['SUMMARY_RETRY_AFTER']['other'] = 2000
        self.assertTrue(await self.ns['prepare_history']('a', None))

    async def test_current_input_not_included_or_summarized(self):
        for i in range(4):
            self.turn(i, 2)
        current = self.add('in', 'current secret text')
        await self.ns['prepare_history']('a', current)
        self.assertNotIn('current secret text', str(self.fold.call_args))
        self.assertNotIn('current secret text', str(self.ns['relay_rows'](current, 'a', 2)))

    async def test_legacy_pending_summary_repaired_before_next_chat(self):
        starts = [self.turn(i) for i in range(3)]
        cut = starts[1] - 1
        self.cfg['history_anchors']['a'] = cut
        self.cfg['pending_summary'] = {'a': {'from': 0, 'to': cut}}
        self.assertTrue(await self.ns['prepare_history']('a', None))
        self.assertEqual(self.cfg['summaries']['a']['covers_to'], cut)
        self.assertEqual(self.cfg['pending_summary'], {})

    async def test_failed_handoff_does_not_publish_half_page(self):
        for i in range(4):
            self.turn(i)
        before = copy.deepcopy(self.cfg)
        self.memory.prepare = lambda *args: (_ for _ in ()).throw(OSError('offline failure'))
        self.assertFalse(await self.ns['prepare_history']('a', None))
        self.assertEqual(self.cfg, before)

    async def test_legacy_capacity_converts_without_doubling(self):
        self.cfg.pop('history_turns')
        self.assertEqual(self.ns['history_turns'](), 24)
        self.cfg['history_n'] = 24
        self.assertEqual(self.ns['history_turns'](), 12)
        self.cfg['history_n'] = 0
        self.assertEqual(self.ns['history_turns'](), 0)
        self.cfg['history_turns'] = 48
        self.assertEqual(self.ns['history_turns'](), 48)


if __name__ == '__main__':
    unittest.main()
