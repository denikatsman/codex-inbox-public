"""Focused regressions for the confirmed synthesis; synthetic files only."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch as mock
import collector


class SourceFixture:
    def __init__(self, root):
        self.root = Path(root)
        self.state = sqlite3.connect(self.root / 'state_5.sqlite')
        self.state.executescript('CREATE TABLE threads(id TEXT,name TEXT,title TEXT,updated_at INTEGER,archived INTEGER);')
        self.db = sqlite3.connect(self.root / 'thread_history_1.sqlite')
        self.db.executescript('''PRAGMA journal_mode=WAL;
        CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER);
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER,PRIMARY KEY(thread_id,turn_id,item_id));
        CREATE INDEX updates ON thread_items(thread_id,updated_at_ordinal);
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,error_json TEXT,completed_at INTEGER,rollout_end_ordinal INTEGER,PRIMARY KEY(thread_id,turn_id));
        CREATE INDEX ends ON thread_turns(thread_id,rollout_end_ordinal,turn_id);
        ''')
    def task(self, task='task', high=200):
        self.state.execute('INSERT INTO threads VALUES (?,?,?,?,?)', (task, None, task, 1, 0)); self.state.commit()
        self.db.execute('INSERT INTO thread_history_projection_state VALUES (?,?)', (task, high)); self.db.commit()
    def item(self, ordinal, updated=None, item=None, task='task', turn='turn'):
        item = item or {'id': str(ordinal), 'type': 'userMessage', 'content': [{'type': 'text', 'text': 'reply'}]}
        self.db.execute('INSERT INTO thread_items VALUES (?,?,?,?,?,?,?,?)', (task, turn, item['id'], ordinal, 1000, json.dumps(item), item['type'], updated if updated is not None else ordinal))
        self.db.commit()
    def turn(self, end, task='task', tid='turn', status='completed', error=None):
        self.db.execute('INSERT INTO thread_turns VALUES (?,?,?,?,?,?,?)', (task, tid, 1, status, error, 2, end)); self.db.commit()
    def close(self):
        self.state.close(); self.db.close()


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.source = SourceFixture(self.temp.name); self.addCleanup(self.source.close)
        self.source.task()
        self.messages = []
        self.addCleanup(mock.stopall)
        mock('collector.emit', lambda kind, **value: self.messages.append(dict(type=kind, **value))).start()
        self.observer = collector.Observer(self.temp.name, 999999)
    def change(self, change, task='task', host='local'):
        self.observer.message(dict(type='broadcast', method='thread-stream-state-changed', version=11, params=dict(hostId=host, conversationId=task, change=change)))
    def test_startup_recovery_is_silent_but_current_poll_events_announce(self):
        self.observer.since = 0
        self.observer.started = 100
        self.source.item(1, item={'id': 'missed-question', 'type': 'agentMessage', 'delivery': 'async', 'text': 'Question'})
        self.source.turn(2)
        self.observer.read_history()
        events = [m for m in self.messages if m['type'] == 'event']
        self.assertEqual(len(events), 2)
        self.assertTrue(all(not m['announce'] for m in events))
        self.assertTrue(all(not m['event']['historical'] for m in events))
        self.messages.clear()
        self.source.db.execute("UPDATE thread_turns SET completed_at=101,rollout_end_ordinal=201 WHERE thread_id='task'")
        self.source.db.execute("UPDATE thread_history_projection_state SET next_rollout_ordinal=202 WHERE thread_id='task'")
        self.source.db.commit()
        self.observer.read_history()
        self.assertTrue(next(m for m in self.messages if m['type'] == 'event')['announce'])

    def test_initial_and_resync_snapshots_are_silent_live_requests_announce(self):
        request = {'id': 'r', 'method': 'item/commandExecution/requestApproval', 'params': {}}
        state = {'requests': [request], 'turns': [{'turnId': 'old', 'status': 'completed', 'items': [], 'turnStartedAtMs': 1000, 'durationMs': 10}]}
        self.change(dict(type='snapshot', revision=1, conversationState=state))
        self.assertTrue(all(not m['announce'] for m in self.messages if m['type'] in ('event', 'requests')))
        self.messages.clear()
        self.change(dict(type='patches', baseRevision=1, revision=2, patches=[dict(op='add', path=['requests', 1], value=dict(request, id='new'))]))
        self.assertTrue(next(m for m in self.messages if m['type'] == 'requests')['announce'])
        self.messages.clear()
        self.change(dict(type='snapshot', revision=3, conversationState=state))
        self.assertFalse(next(m for m in self.messages if m['type'] == 'requests')['announce'])

    def test_async_snapshot_is_silent_even_with_a_recent_source_time(self):
        item = {'id': 'question', 'type': 'agentMessage', 'delivery': 'async', 'text': 'Question'}
        self.observer.item('task', 'turn', item, created=self.observer.started + 1)
        self.assertFalse(self.messages[-1]['announce'])
        self.observer.item('task', 'turn', dict(item, id='live-question'), live=True)
        self.assertTrue(self.messages[-1]['announce'])
    def test_poison_restart_and_terminal_normalization_CN001_011_021(self):
        for i, raw in enumerate(['null', '[null]', '{"questionItemId":"q","answer":null}', '3', '[{"questionItemId":[],"answer":"yes"}]']):
            self.source.item(i+1, item={'id': str(i), 'type': 'userMessage', 'content': [{'type': 'text', 'text': '<send_user_message_question_reply>'+raw+'</send_user_message_question_reply>'}]})
        self.source.task('healthy'); self.source.turn(100, task='healthy', status='failed')
        for _ in range(2):
            collector.Observer(self.temp.name, 0).read_history()
        self.assertTrue(any(m.get('event', {}).get('kind') == 'error' and m['event']['thread'] == 'healthy' for m in self.messages))
        self.assertFalse(any(m.get('reply', {}).get('answeredQuestionIDs') for m in self.messages))
        self.messages.clear()
        for error in [{'message': 'Oops'}, '{"message":"Oops"}', {'message': 'Oops'}, '{"message":"Changed"}']:
            self.observer.completed('task', 't', error=error, status='failed')
        self.assertEqual([m['event']['body'] for m in self.messages], ['Oops', 'Changed'])
        for status, expected in [('failed', 'error'), ('interrupted', 'error'), ('completed', 'completion')]:
            self.observer.completed('task', status, status=status)
            self.assertEqual(self.messages[-1]['event']['kind'], expected)
    def test_pages_both_streams_update_vs_original_CN002(self):
        self.observer.cursors['task'] = 100
        self.source.item(5, 105)
        for i in range(110, 180): self.source.item(i, 180)
        self.source.turn(190)
        self.observer.read_history()
        replies = [m['reply'] for m in self.messages if m['type'] == 'reply']
        self.assertEqual(len(replies), 71)
        self.assertEqual(replies[0]['sourceOrdinal'], 5)
        event = next(m['event'] for m in self.messages if m['type'] == 'event')
        self.assertEqual(event['sourceOrdinal'], 190)
        checkpoint = next(i for i, m in enumerate(self.messages) if m['type'] == 'cursor')
        self.assertEqual(self.messages[checkpoint], dict(type='cursor', thread='task', ordinal=200))
        self.assertTrue(all(i < checkpoint for i, m in enumerate(self.messages) if m['type'] in ('event', 'reply')))
        self.assertEqual(len(self.observer.replies)+len(self.observer.sent), 0)
    def test_snapshot_then_later_final_edit_CN002(self):
        self.source.item(5, item={'id':'5','type':'agentMessage','phase':'final_answer','text':'Before'})
        self.source.turn(20)
        original = self.observer.checked_item
        changed = False
        def read(*args):
            nonlocal changed
            if not changed:
                changed = True
                self.source.db.execute('UPDATE thread_items SET item_json=?,updated_at_ordinal=205', (json.dumps({'id':'5','type':'agentMessage','text':'After'}),))
                self.source.db.execute('UPDATE thread_history_projection_state SET next_rollout_ordinal=206'); self.source.db.commit()
            return original(*args)
        self.observer.checked_item = read
        self.observer.read_history()
        self.assertTrue(all(m['event']['body'] == 'Before' for m in self.messages if m['type']=='event'))
        self.messages.clear(); self.observer.read_history()
        self.assertTrue(any(m.get('event', {}).get('body') == 'After' and m['event']['sourceOrdinal'] == 20 for m in self.messages))
    def test_window_failures_and_oversize_do_not_ack_CN002(self):
        self.source.item(5); self.source.turn(20)
        with mock.object(self.observer, 'history_completion', side_effect=ValueError('decode')):
            with self.assertRaises(ValueError): self.observer.read_history()
        self.assertNotIn('task', self.observer.cursors)
        self.assertFalse(any(m['type']=='cursor' for m in self.messages))
        self.source.db.execute('UPDATE thread_items SET item_json=?', ('x'*(collector.MAX_RECORD_BYTES+1),)); self.source.db.commit()
        self.observer.read_history()
        self.assertIn('16 MiB', self.observer.warning)
        self.assertNotIn('task', self.observer.cursors)
    def test_atomic_root_aggregate_and_freshness_CN004_007_008_009(self):
        state = {'title':'Before','requests':[], 'turns':[{'id':'t','status':'inProgress','items':[]}]}
        self.change(dict(type='snapshot', conversationState=state, revision=1)); self.messages.clear()
        self.change(dict(type='patches',baseRevision=1,revision=2,patches=[dict(op='replace',path=['title'],value='Wrong'),dict(op='remove',path=['missing'])]))
        self.assertEqual(self.observer.states[('local','task')]['title'], 'Before')
        self.assertEqual(self.observer.revisions[('local','task')],1)
        self.change(dict(type='patches',baseRevision=1,revision=3,patches=[dict(op='replace',path=['title'],value='Still wrong')]))
        self.assertEqual(len(self.messages), 1)
        self.assertEqual(self.messages[0]['type'], 'runtime')
        self.assertEqual(self.messages[0]['runtime']['source'], 'unconfirmed')
        self.change(dict(type='snapshot',conversationState=state,revision=4))
        item = {'id':'old','type':'userMessage','content':[{'text':'old'}]}
        state['turns'][0]['items'] = [item]
        self.change(dict(type='patches',baseRevision=4,revision=5,patches=[dict(op='replace',path=[],value=state)]))
        self.assertEqual(next(m['reply'] for m in self.messages if m['type']=='reply')['provenance'],'discovery')
        self.change(dict(type='patches',baseRevision=5,revision=6,patches=[dict(op='add',path=['turns',0,'items',1],value=dict(item,id='new'))]))
        self.assertEqual([m['reply'] for m in self.messages if m['type']=='reply'][-1]['provenance'],'new_action')
    def test_send_failure_preserves_history_CN010(self):
        self.source.item(5)
        self.observer.client = 'observer'
        with mock.object(self.observer, 'send', side_effect=TimeoutError()): self.observer.read_history()
        self.assertTrue(self.observer.history_ok)
        self.assertEqual(self.observer.cursors['task'],200)
        self.assertIsNone(self.observer.client)
    def test_all_active_tasks_survive_retirement_CN016(self):
        for i in range(35):
            self.source.task(str(i)); self.source.turn(0,task=str(i),status='inProgress' if i<20 else 'completed')
        for i in range(15):
            self.change(dict(type='snapshot',revision=1,conversationState={'turns':[{'id':'t','status':'inProgress','items':[]}],'requests':[]}),task='r'+str(i),host='remote')
        self.observer.read_history()
        self.assertTrue(all(('local',str(i)) in self.observer.wanted for i in range(20)))
        self.assertTrue(all(('remote','r'+str(i)) in self.observer.wanted for i in range(15)))
        self.observer.disconnect(); self.observer.read_history()
        self.assertTrue(all(('remote','r'+str(i)) in self.observer.wanted for i in range(15)))
        for i in range(15):
            self.change(dict(type='snapshot',revision=2,conversationState={'turns':[{'id':'t','status':'completed','items':[]}],'requests':[]}),task='r'+str(i),host='remote')
        self.observer.sync_subscriptions()
        self.assertFalse(any(k[0]=='remote' for k in self.observer.wanted))
    def test_authoritative_idle_suppresses_stale_history_until_advance_CN016(self):
        self.source.turn(0,status='inProgress')
        self.change(dict(type='snapshot',revision=1,conversationState={'threadRuntimeStatus':'idle','turns':[],'requests':[]}))
        self.observer.read_history()
        self.assertNotIn(('local','task'),self.observer.active)
        self.observer.read_history()
        self.assertNotIn(('local','task'),self.observer.active)
        self.source.db.execute('UPDATE thread_history_projection_state SET next_rollout_ordinal=201');self.source.db.commit()
        self.observer.read_history()
        self.assertIn(('local','task'),self.observer.active)

    def test_history_terminal_retires_same_stale_turn_only_CN016(self):
        self.source.turn(50)
        self.change(dict(type='snapshot',revision=1,conversationState={'turns':[{'id':'turn','status':'inProgress','items':[]}],'requests':[]}))
        self.observer.read_history()
        self.assertNotIn(('local','task'),self.observer.active)
        self.change(dict(type='snapshot',revision=2,conversationState={'turns':[{'id':'newer','status':'inProgress','items':[]}],'requests':[]}))
        self.observer.read_history()
        self.assertIn(('local','task'),self.observer.active)
        frames=[];self.observer.client='observer';self.observer.send=frames.append
        self.change(dict(type='snapshot',revision=1,conversationState={'turns':[{'id':'r','status':'inProgress','items':[]}],'requests':[]}),task='remote-task',host='remote')
        self.observer.message(dict(type='broadcast',method='thread-stream-following-changed',sourceClientId='other',params=dict(hostId='remote',conversationId='remote-task',following=False)))
        self.observer.sync_subscriptions()
        self.assertIn(('remote','remote-task'),self.observer.subscribed)
        self.change(dict(type='snapshot',revision=2,conversationState={'turns':[{'id':'r','status':'completed','items':[]}],'requests':[]}),task='remote-task',host='remote')
        self.observer.sync_subscriptions()
        self.assertTrue(any(f.get('params',{}).get('following') is False and f['params']['conversationId']=='remote-task' for f in frames))

    def test_reply_aliases_and_remote_title_CN006_019(self):
        self.observer.item('task','t', {'id':'s','type':'steeringUserMessage','status':'accepted','serverUserMessageId':'u','clientUserMessageId':'c','input':[{'text':'yes'}]})
        self.assertIn('server:u',self.messages[-1]['reply']['aliases'])
        self.change(dict(type='snapshot',revision=1,conversationState={'title':'Old'}),host='remote')
        self.change(dict(type='patches',baseRevision=1,revision=2,patches=[dict(op='replace',path=['title'],value='New')]),host='remote')
        self.assertTrue(any(m['type']=='task_title' and m['title']=='New' for m in self.messages))
    def test_recovery_memory_plateaus_CN002(self):
        code = r"""
import collector, json, resource, subprocess, sys, tempfile
from test_repairs import SourceFixture
with tempfile.TemporaryDirectory() as directory:
    source = SourceFixture(directory); source.task(high=int(sys.argv[1])+1)
    for i in range(1,int(sys.argv[1])+1):
        item={'id':str(i),'type':'userMessage','content':[{'text':'x'*4096}]}
        source.db.execute('INSERT INTO thread_items VALUES (?,?,?,?,?,?,?,?)',('task','t',str(i),i,1000,json.dumps(item),'userMessage',i))
    source.db.commit()
    source.close()
    # Measure a fresh reader process; creating one huge writer transaction is
    # deliberately outside the recovery memory measurement.
    probe = "import collector,json,resource,sys; observer=collector.Observer(sys.argv[1],0); collector.emit=lambda *args,**kwargs:None\nwhile observer.cursors.get('task',0)<int(sys.argv[2])+1: observer.read_history()\nprint(json.dumps({'rss':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'cached':len(observer.sent)+len(observer.replies)}))"
    print(subprocess.run([sys.executable,'-c',probe,directory,sys.argv[1]],capture_output=True,text=True,check=True).stdout.strip())
"""
        sizes = []
        for count in (1000,10000):
            result = subprocess.run([sys.executable,'-c',code,str(count)],capture_output=True,text=True,check=True)
            sizes.append(json.loads(result.stdout))
        self.assertEqual([v['cached'] for v in sizes],[0,0])
        allowance = 24*1024*1024 if sys.platform == 'darwin' else 24*1024
        self.assertLess(sizes[1]['rss']-sizes[0]['rss'], allowance, sizes)
        print('Recovery memory (1000/10000 records):', sizes, file=sys.stderr)

    def test_quiet_child_exits_when_parent_dies_CN017(self):
        pidfile = Path(self.temp.name)/'pid'
        code = '''import subprocess,sys,time
p=subprocess.Popen([sys.executable,'collector.py','--home',sys.argv[1],'--parent-lifetime'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
open(sys.argv[2],'w').write(str(p.pid))
time.sleep(30)
'''
        parent = subprocess.Popen([sys.executable,'-c',code,self.temp.name,str(pidfile)])
        child = None
        try:
            for _ in range(100):
                if pidfile.exists(): break
                time.sleep(.02)
            child = int(pidfile.read_text()); parent.kill(); parent.wait()
            for _ in range(100):
                state = subprocess.run(['ps','-p',str(child),'-o','stat='],capture_output=True,text=True).stdout.strip()
                if not state or state.startswith('Z'): break
                time.sleep(.03)
            self.assertTrue(not state or state.startswith('Z'),state)
        finally:
            if parent.poll() is None: parent.kill(); parent.wait()
            if child:
                try: os.kill(child,signal.SIGTERM)
                except ProcessLookupError: pass

if __name__ == '__main__': unittest.main()
