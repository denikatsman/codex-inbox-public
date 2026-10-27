"""Task observation checks use synthetic SQLite and in-memory socket frames only."""
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import collector
from test_repairs import SourceFixture


class TaskTrackingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.source = SourceFixture(self.temp.name); self.addCleanup(self.source.close)
        self.source.task()
        self.messages = []
        self.capture = patch('collector.emit', lambda kind, **data: self.messages.append(dict(type=kind, **data)))
        self.capture.start(); self.addCleanup(self.capture.stop)
        self.observer = collector.Observer(self.temp.name, 999999)

    def snapshot(self, state, host='local', thread='task', revision=1):
        self.observer.message(dict(type='broadcast', method='thread-stream-state-changed', version=11,
            params=dict(hostId=host, conversationId=thread, change=dict(type='snapshot', revision=revision, conversationState=state))))

    def events(self, kind):
        return [value for value in self.messages if value['type'] == kind]

    def test_dot_requires_origin_and_survives_idle(self):
        for value in [{'threadSource': 'aeon'}, {'title': 'Dot'}, {'source': {'custom': 'codex-cloud-agent'}}]:
            self.assertNotEqual(collector.task_origin(value)[0].get('origin'), 'dot')
        self.snapshot({'originator': 'orbit_cca_desktop', 'threadSource': 'aeon', 'threadRuntimeStatus': {'type': 'idle'}}, host='durable')
        task = self.events('tasks')[-1]['tasks'][0]
        self.assertEqual(task['origin'], 'dot')
        self.assertEqual(self.events('runtime')[-1]['runtime']['status'], 'idle')
        self.observer.sync_subscriptions()
        self.assertIn(('durable', 'task'), self.observer.wanted)

    def test_runtime_is_independent_of_notifications_and_request_loss(self):
        self.snapshot({'turns': [{'id': 't', 'status': 'inProgress', 'items': []}]})
        self.assertEqual(self.events('event'), [])
        self.assertEqual(self.events('runtime')[-1]['runtime']['status'], 'working')
        self.snapshot({'requests': [{'id': 'q', 'method': 'item/tool/requestUserInput', 'params': {}}]}, revision=2)
        self.assertEqual(self.events('runtime')[-1]['runtime']['status'], 'waiting_user')
        self.snapshot({'requests': []}, revision=3)
        self.assertEqual(self.events('runtime')[-1]['runtime']['source'], 'unconfirmed')
        self.assertNotIn(self.events('runtime')[-1]['runtime']['status'], ('finished', 'idle'))

    def test_parent_records_do_not_confuse_delegation_with_creation(self):
        for name, kind in [('create_thread', 'created'), ('send_message_to_thread', 'delegated')]:
            item = dict(type='functionCallOutput', id=name, namespace='codex_app', name=name,
                        output='<codex_delegation><source_thread_id>parent</source_thread_id><input>Text</input></codex_delegation>')
            self.observer.item('child', 'turn', item, host='remote')
            relation = self.events('relation')[-1]['relation']
            self.assertEqual((relation['thread'], relation['host'], relation['parentThread'], relation['parentHost'], relation['kind']), ('child', 'remote', 'parent', None, kind))
            item['type'] = 'userMessage'
            self.assertIsNone(collector.delegation_parent(item))
        self.observer.item('parent', 'turn', dict(type='subAgentActivity', id='spawn', kind='started', agentThreadId='child'), host='remote')
        self.assertEqual(self.events('relation')[-1]['relation']['kind'], 'delegated')
        self.assertIn(('remote', 'child'), self.observer.wanted)
        self.snapshot({'parentThreadId': 'origin', 'threadSource': 'agent_created_thread'}, host='durable', thread='created')
        self.assertIsNone(self.events('relation')[-1]['relation']['parentHost'])

    def test_created_task_result_reveals_remote_child(self):
        item = dict(type='mcpToolCall', id='call', server='codex_app', tool='create_thread', status='completed',
                    result={'content': [{'type': 'text', 'text': json.dumps({'threadId': 'child', 'hostId': 'durable'})}]})
        self.observer.relationship_item('parent', 'local', item)
        self.assertEqual(self.events('relation')[-1]['relation']['parentHost'], 'local')
        self.assertIn(('durable', 'child'), self.observer.remote_known)
        count = len(self.events('relation'))
        item['result'] = {'structuredContent': {'clientThreadId': 'pending'}}
        self.observer.relationship_item('parent', 'local', item)
        self.assertEqual(len(self.events('relation')), count)
        item['result'] = {'isError': True, 'structuredContent': {'threadId': 'invalid-child', 'hostId': 'local'}}
        self.observer.relationship_item('parent', 'local', item)
        self.assertEqual(len(self.events('relation')), count)

    def test_native_spawn_stays_followed_and_live_confirmation_is_renewed(self):
        self.observer.relationship_item('parent', 'local', dict(type='collabAgentToolCall', tool='spawnAgent', status='completed', receiverThreadIds=['child']))
        self.observer.sync_subscriptions()
        self.assertIn(('local', 'child'), self.observer.wanted)
        with patch('collector.time.monotonic', return_value=100): self.observer.runtime('child', 'local', 'working')
        count = len(self.events('runtime'))
        with patch('collector.time.monotonic', return_value=120): self.observer.runtime('child', 'local', 'working')
        self.assertEqual(len(self.events('runtime')), count)
        with patch('collector.time.monotonic', return_value=131): self.observer.runtime('child', 'local', 'working')
        self.assertEqual(len(self.events('runtime')), count + 1)

    def test_relationship_backfill_has_own_checkpoint_and_no_old_body_rewrite(self):
        self.source.item(50, item=dict(type='functionCallOutput', id='delegation', namespace='codex_app', name='create_thread',
            output='<codex_delegation><source_thread_id>parent</source_thread_id><input>hello</input></codex_delegation>'))
        self.source.turn(90, status='interrupted')
        self.observer.cursors['task'] = 200
        self.observer.read_history()
        self.assertEqual(self.observer.cursors['task'], 200)
        self.assertEqual(self.observer.relationship_cursors['task'], 200)
        self.assertEqual(len(self.events('relation')), 1)
        self.assertEqual(self.events('event'), [])
        self.assertEqual(self.events('outcome')[0]['terminalStatus'], 'interrupted')
        self.messages.clear(); self.observer.read_history()
        self.assertEqual(self.events('relation'), [])

    def test_bad_relationship_payload_does_not_ack_checkpoint(self):
        self.source.item(30, item={'id': 'bad', 'type': 'functionCallOutput'})
        self.source.db.execute("UPDATE thread_items SET item_json='{' WHERE item_id='bad'"); self.source.db.commit()
        with self.assertRaises(ValueError): self.observer.read_history()
        self.assertEqual(self.events('relationship_cursor'), [])
        self.assertNotIn('task', self.observer.relationship_cursors)

    def test_native_metadata_and_spawn_edges(self):
        self.source.state.executescript('ALTER TABLE threads ADD COLUMN source TEXT; ALTER TABLE threads ADD COLUMN thread_source TEXT; CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);')
        self.source.state.execute('UPDATE threads SET source=?,thread_source=?', (json.dumps({'subagent': {'thread_spawn': {'parent_thread_id': 'parent', 'agent_nickname': 'Ada', 'agent_role': 'reviewer'}}}), 'subagent'))
        self.source.state.execute("INSERT INTO thread_spawn_edges VALUES('parent','task','active')"); self.source.state.commit()
        self.observer.read_history()
        task = self.events('tasks')[0]['tasks'][0]
        self.assertEqual((task['origin'], task['agentNickname']), ('subagent', 'Ada'))
        self.assertTrue(all(r['relation']['parentHost'] == 'local' for r in self.events('relation')))

    def test_remote_inventory_and_relationship_cursor_restore(self):
        saved = Path(self.temp.name) / 'inbox.sqlite'
        with sqlite3.connect(saved) as db:
            db.executescript('CREATE TABLE meta(key TEXT,value TEXT); CREATE TABLE tasks(host TEXT,payload TEXT);')
            db.execute('INSERT INTO meta VALUES(?,?)', ('relationships:v2:task', '90'))
            db.execute('INSERT INTO meta VALUES(?,?)', ('relationships:v1:legacy', '80'))
            db.execute('INSERT INTO meta VALUES(?,?)', ('cursor:legacy', '120'))
            db.execute('INSERT INTO tasks VALUES(?,?)', ('durable', json.dumps(dict(thread='dot', host='durable', title='Dot', origin='dot'))))
        observer = collector.Observer(self.temp.name, 0, saved)
        self.assertEqual(observer.relationship_cursors['task'], 90)
        self.assertIn(('durable', 'dot'), observer.wanted)
        self.assertNotIn('legacy', observer.relationship_cursors)
        self.assertEqual(observer.cursors, {'legacy': 120})

    def test_interaction_is_not_a_spawn_but_explicit_spawn_is(self):
        self.observer.relationship_item('parent', 'local', dict(type='subAgentActivity', kind='interacted', agentThreadId='user-chat'))
        self.assertEqual(self.events('relation')[-1]['relation']['kind'], 'delegated')
        self.observer.relationship_item('parent', 'local', dict(type='collabAgentToolCall', tool='spawnAgent', status='completed', receiverThreadIds=['child']))
        relation = self.events('relation')[-1]['relation']
        self.assertEqual((relation['kind'], relation['sourceID']), ('subagent', 'spawn:parent'))

    def test_resync_warning_tracks_outstanding_tasks_and_clears_on_recovery(self):
        self.observer.follow = lambda *args, **kwargs: None
        self.snapshot({'turns': [{'id': 't', 'status': 'inProgress', 'items': []}]})
        self.observer.message(dict(type='broadcast', method='thread-stream-state-changed', version=11,
            params=dict(conversationId='task', change=dict(type='patches', baseRevision=1, revision=2,
                patches=[dict(op='remove', path=['missing'])]))))
        self.observer.status()
        self.assertEqual(self.events('status')[-1]['warning'], 'Resyncing 1 task.')
        self.assertEqual(self.events('runtime')[-1]['runtime']['source'], 'unconfirmed')
        self.observer.request_snapshot('local', 'other')
        self.snapshot({'turns': [{'id': 't', 'status': 'inProgress', 'items': []}]}, revision=3)
        self.observer.status()
        self.assertEqual(self.events('status')[-1]['warning'], 'Resyncing 1 task.')
        self.assertEqual(self.events('runtime')[-1]['runtime']['source'], 'live')
        self.snapshot({}, thread='other')
        self.observer.status()
        self.assertEqual(self.events('status')[-1]['warning'], '')
        self.observer.warning = 'Local history unavailable: OperationalError'
        self.observer.request_snapshot('local', 'other')
        self.snapshot({}, thread='other', revision=4)
        self.observer.status()
        self.assertEqual(self.events('status')[-1]['warning'], self.observer.warning)

    def test_history_pass_publishes_connection_progress_before_finishing(self):
        self.observer.client = 'fixture'
        self.observer.service_live()
        status = self.events('status')[-1]
        self.assertTrue(status['connected'])
        self.assertFalse(status['history'])

    def test_interrupted_failed_and_waiting_for_agents(self):
        for status in ['completed', 'failed', 'interrupted']:
            self.observer.completed('task', status, status=status)
            self.assertEqual(self.events('event')[-1]['event']['terminalStatus'], status)
        self.snapshot({'turns': [{'id': 'wait', 'status': 'inProgress', 'items': [{'type': 'collabAgentToolCall', 'tool': 'wait', 'status': 'inProgress'}]}]})
        self.assertEqual(self.events('runtime')[-1]['runtime']['status'], 'waiting_agents')

    def test_collector_freshness_heartbeat_does_not_change_source_status(self):
        with patch('collector.time.monotonic', return_value=100): self.observer.status()
        initial = self.events('status')[-1]
        with patch('collector.time.monotonic', return_value=110): self.observer.status()
        self.assertEqual(len(self.events('status')), 1)
        with patch('collector.time.monotonic', return_value=131): self.observer.status()
        self.assertEqual(self.events('status'), [initial, initial])


if __name__ == '__main__': unittest.main()
