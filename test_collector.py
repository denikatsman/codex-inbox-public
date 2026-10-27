import contextlib
import copy
import io
import json
import time
import unittest
import sqlite3
import tempfile
from pathlib import Path
from collector import Observer, patch, project_metadata


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        self.observer = Observer('/nonexistent-fixture', time.time())

    def tearDown(self):
        self.redirect.__exit__(None, None, None)

    def async_item(self):
        return {'id': 'question-1', 'type': 'agentMessage', 'delivery': 'async',
                'text': 'Questions', 'questions': [{'title': 'One?'}, {'title': 'Two?'}, {'title': 'Three?'}]}

    def test_all_questions_are_retained_and_deduplicated(self):
        for _ in range(2):
            self.observer.item('task', 'turn', self.async_item(), live=True)
        self.assertEqual(len(self.observer.sent), 3)
        self.assertEqual(len(self.output.getvalue().splitlines()), 3)

    def test_estimate_is_only_for_a_live_panel(self):
        self.observer.item('task', 'turn', self.async_item(), live=False)
        self.assertTrue(all('deadline' not in e for e in self.observer.sent.values()))

    def test_reply_resolves_only_its_own_question(self):
        self.observer.item('task', 'turn', self.async_item(), live=True)
        reply = json.dumps([{'questionItemId': '["request_user_input_async","question-1",1]', 'answer': 'Two'}])
        self.observer.item('task', 'turn', {'id': 'answer', 'type': 'userMessage', 'content': [{'type': 'text', 'text': '<send_user_message_question_reply>'+reply+'</send_user_message_question_reply>'}]})
        self.assertEqual(next(iter(self.observer.replies.values()))['answeredQuestionIDs'], ['["request_user_input_async","question-1",1]'])

    def test_rejected_steering_is_not_an_answer(self):
        self.observer.item('task', 'turn', self.async_item())
        self.observer.item('task', 'turn', {'type': 'steeringUserMessage', 'status': 'rejected', 'input': []})
        self.assertFalse(any(e['resolved'] for e in self.observer.sent.values()))

    def test_patch_insert_replace_remove_and_root(self):
        state = {'items': [{'text': 'old'}]}
        result = patch(state, [{'op': 'add', 'path': ['items', 0], 'value': {'text': 'new'}},
                               {'op': 'replace', 'path': ['items', 1, 'text'], 'value': 'updated'},
                               {'op': 'remove', 'path': ['items', 0]}])
        self.assertEqual(result, {'items': [{'text': 'updated'}]})
        self.assertEqual(patch(result, [{'op': 'replace', 'path': [], 'value': {}}]), {})

    def test_revision_gap_requests_a_snapshot(self):
        requests = []
        self.observer.follow = lambda *args, **kw: requests.append((args, kw))
        self.observer.message({'type': 'broadcast', 'method': 'thread-stream-state-changed', 'version': 11,
                               'params': {'hostId': 'local', 'conversationId': 'task', 'change': {'type': 'patches', 'baseRevision': 20, 'revision': 21, 'patches': []}}})
        self.assertEqual(requests[0][1], {'force': True})

    def test_schema_change_is_visible(self):
        self.observer.message({'type': 'broadcast', 'method': 'thread-stream-state-changed', 'version': 12,
                               'params': {'conversationId': 'task', 'change': {}}})
        self.assertIn('updated', self.observer.warning)

    def test_never_accepts_request_ownership(self):
        sent = []
        self.observer.send = sent.append
        self.observer.message({'type': 'client-discovery-request', 'requestId': 'r'})
        self.assertEqual(sent[0]['response'], {'canHandle': False})

    def test_all_approval_and_connector_paths(self):
        methods = ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
                   'item/permissions/requestApproval', 'execCommandApproval', 'applyPatchApproval',
                   'mcpServer/elicitation/request', 'item/tool/requestUserInput']
        self.observer.states[('local', 'task')] = {'requests': [{'id': str(i), 'method': m, 'params': {}} for i, m in enumerate(methods)]}
        self.observer.inspect_state('local', 'task', True)
        requests = json.loads(self.output.getvalue().splitlines()[-1])["requests"]
        self.assertEqual(len(requests), len(methods))
        self.assertTrue(all("deadline" not in e for e in requests))

    def test_pending_request_resolution_preserves_event(self):
        state = {'requests': [{'id': 'r', 'method': 'item/tool/requestUserInput', 'params': {'isBlocking': False}}]}
        self.observer.states[('local', 'task')] = state
        self.observer.inspect_state('local', 'task', True)
        self.assertTrue(json.loads(self.output.getvalue().splitlines()[-1])['requests'][0]['timerUnavailable'])
        state['requests'] = []
        self.observer.inspect_state('local', 'task', True)
        self.assertEqual(json.loads(self.output.getvalue().splitlines()[-1])['requests'], [])

    def test_explicit_deadline_not_inferred_from_duration(self):
        self.observer.states[('local', 'task')] = {'requests': [{'id': 'r', 'method': 'item/tool/requestUserInput', 'params': {'deadlineMs': 2000000000000}}]}
        self.observer.inspect_state('local', 'task', True)
        event = json.loads(self.output.getvalue().splitlines()[-1])['requests'][0]
        self.assertEqual(event['deadline'], 2000000000)
        self.assertFalse(event['estimated'])

    def test_same_item_ids_on_two_hosts_are_distinct(self):
        self.observer.item('task', 'turn', self.async_item(), host='local')
        self.observer.item('task', 'turn', self.async_item(), host='remote')
        self.assertEqual(len(self.observer.sent), 6)

    def test_sent_messages_keep_identity_order_and_are_not_duplicated_by_backfill(self):
        item = {'id': 'message-1', 'type': 'userMessage', 'content': [{'type': 'text', 'text': 'Hello'}]}
        self.observer.item('task', 'turn', item, live=True)
        self.observer.item('task', 'turn', item, live=True)
        self.observer.item('task', 'turn', item, created=100, ordinal=42)
        replies = [json.loads(line)['reply'] for line in self.output.getvalue().splitlines() if json.loads(line)['type'] == 'reply']
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]['id'], replies[1]['id'])
        self.assertEqual(replies[1]['sourceOrdinal'], 42)
        self.assertTrue(replies[1]['live'])

    def test_skipping_or_rejected_steering_does_not_emit_a_sent_message(self):
        blank = '<send_user_message_question_reply>' + json.dumps([{'questionItemId': 'q', 'answer': ''}]) + '</send_user_message_question_reply>'
        self.observer.item('task', 'turn', {'id': 'skip', 'type': 'userMessage', 'content': [{'type': 'text', 'text': blank}]}, live=True)
        self.observer.item('task', 'turn', {'id': 'steer', 'type': 'steeringUserMessage', 'status': 'rejected', 'input': [{'type': 'text', 'text': 'Hello'}]}, live=True)
        self.assertEqual(self.observer.replies, {})

    def test_request_disappearance_is_not_labelled_answered(self):
        state = {'requests': [{'id': 'r', 'method': 'item/commandExecution/requestApproval', 'params': {}}]}
        self.observer.states[('local', 'task')] = state
        self.observer.inspect_state('local', 'task', True)
        state['requests'] = []
        self.observer.inspect_state('local', 'task', True)
        self.assertEqual(json.loads(self.output.getvalue().splitlines()[-1])['requests'], [])
        self.assertFalse(any(json.loads(line).get('event', {}).get('resolution') == 'answered' for line in self.output.getvalue().splitlines()))

    def test_local_projects_and_source_cursors_are_read_only_and_emitted_after_events(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            state = sqlite3.connect(root / 'state_5.sqlite')
            state.executescript("CREATE TABLE threads(id TEXT,name TEXT,title TEXT,updated_at INTEGER,archived INTEGER,project_id TEXT); CREATE TABLE projects(id TEXT,name TEXT); INSERT INTO projects VALUES ('p','Project Name'); INSERT INTO threads VALUES ('task',NULL,'Task title',100,1,'p');")
            state.commit(); state.close()
            history = sqlite3.connect(root / 'thread_history_1.sqlite')
            history.executescript("CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_ordinal INTEGER); INSERT INTO thread_history_projection_state VALUES('task',44); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER); CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,error_json TEXT,completed_at INTEGER,rollout_end_ordinal INTEGER);")
            item = self.async_item()
            history.execute('INSERT INTO thread_items VALUES (?,?,?,?,?,?,?,?)', ('task', 'turn', item['id'], 41, 100000, json.dumps(item), 'agentMessage', 41))
            reply = {'id': 'reply', 'type': 'userMessage', 'content': [{'type': 'text', 'text': 'A reply'}]}
            history.execute('INSERT INTO thread_items VALUES (?,?,?,?,?,?,?,?)', ('task', 'turn', 'reply', 43, 99000, json.dumps(reply), 'userMessage', 43))
            history.commit(); history.close()
            before = {p.name: p.read_bytes() for p in root.glob('*.sqlite')}
            observer = Observer(root, 0)
            observer.read_history()
            messages = [json.loads(line) for line in self.output.getvalue().splitlines()]
            self.assertEqual(messages[0]['tasks'][0]['projectName'], 'Project Name')
            checkpoint = next(i for i, m in enumerate(messages) if m['type'] == 'cursor')
            self.assertEqual(messages[checkpoint]['ordinal'], 44)
            self.assertTrue(all(i < checkpoint for i, m in enumerate(messages) if m['type'] in ('event', 'reply')))
            self.assertTrue(all(m['event'].get('sourceOrdinal') == 41 for m in messages if m['type'] == 'event'))
            self.assertEqual(next(m['reply'] for m in messages if m['type'] == 'reply')['sourceOrdinal'], 43)
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.glob('*.sqlite')})
            # Persisted acknowledgement survives collector restart. Even though
            # timestamp 99 precedes 100, the ordinal says the reply came later.
            saved = sqlite3.connect(root / 'inbox.sqlite')
            saved.executescript("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('cursor:task','44');")
            saved.commit(); saved.close()
            restored = Observer(root, 0, root / 'inbox.sqlite')
            self.assertEqual(restored.cursors['task'], 44)

    def test_legacy_project_assignments_are_canonicalized_without_guessing_from_folders(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            data = {'local-projects': {'old-project': {'name': 'Old name'}},
                    'thread-project-assignments': {'legacy-task': {'projectId': 'old-project'}},
                    'app-server-project-id-by-legacy-project-id-by-host': {'local:' + str(root): {'old-project': 'native-project'}}}
            path = root / '.codex-global-state.json'; path.write_text(json.dumps(data)); original = path.read_bytes()
            tasks = [('legacy-task', 'A', 0, 0, None, None), ('native-task', 'B', 0, 0, 'native-project', 'Current name'), ('unassigned', 'C', 0, 0, None, None)]
            result = project_metadata(root, tasks, {'native-project': 'Current name'})
            self.assertEqual(result['legacy-task']['projectID'], result['native-task']['projectID'])
            self.assertEqual(result['legacy-task']['projectName'], 'Current name')
            self.assertIsNone(result['unassigned']['projectID'])
            self.assertEqual(path.read_bytes(), original)

    def test_saved_roots_respect_explicit_projectless_and_ambiguous_projects(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            data = {'local-projects': {'p': {'name': 'Project', 'rootPaths': ['/repo']}},
                    'projectless-thread-ids': ['projectless', 'explicit'],
                    'thread-project-assignments': {'explicit': {'projectId': 'p'}}}
            (root / '.codex-global-state.json').write_text(json.dumps(data))
            tasks = [(key, key, 0, 0, None, None, '/repo/subfolder') for key in ['normal', 'projectless', 'explicit']]
            result = project_metadata(root, tasks, {})
            self.assertEqual(result['normal']['projectID'], 'p')
            self.assertIsNone(result['projectless']['projectID'])
            self.assertEqual(result['explicit']['projectID'], 'p')
            data['local-projects']['other'] = {'name': 'Other', 'rootPaths': ['/repo']}
            (root / '.codex-global-state.json').write_text(json.dumps(data))
            self.assertIsNone(project_metadata(root, tasks, {})['normal']['projectID'])


if __name__ == '__main__':
    unittest.main()
