import datetime
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import conversation_map as cm


class ConversationMapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.state = sqlite3.connect(self.home / "state_5.sqlite")
        self.state.executescript("""
        CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,title TEXT,agent_nickname TEXT,
          agent_path TEXT,thread_source TEXT,source TEXT,rollout_path TEXT);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);
        """)
        self.history = sqlite3.connect(self.home / "thread_history_1.sqlite")
        self.history.executescript("""
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,
          completed_at INTEGER,duration_ms INTEGER,rollout_ordinal INTEGER,
          rollout_byte_offset INTEGER,rollout_end_byte_offset INTEGER);
        ALTER TABLE thread_turns ADD COLUMN final_agent_item_id TEXT;
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,
          item_json TEXT,created_at_ms INTEGER,started_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER);
        """)
        self.path = self.home / "parent.jsonl"
        self.add_actor("parent", "Main chat", None, None)
        self.add_actor("child", "", "parent", "/root/reviewer")
        self.add_turn("parent", "old", 1, 0, 40)
        self.add_turn("parent", "main", 20, 100, 300)
        self.add_turn("child", "child-turn", 10, 150, 200)
        self.add_message("parent", "main", "input", "userMessage", 110, {"content": [{"type": "text", "text": "Check the work."}]})
        self.add_message("parent", "main", "progress", "agentMessage", 160, {"text": "Parent progress", "phase": "commentary"})
        self.add_message("parent", "main", "final", "agentMessage", 300, {"text": "Parent final", "phase": "final_answer"})
        self.add_message("child", "child-turn", "child-input", "userMessage", 150, {"content": [{"type": "text", "text": "Delegated prompt"}, {"type": "image"}]})
        self.add_message("child", "child-turn", "child-final", "agentMessage", 190, {"text": "Child final", "phase": "final_answer"})
        self.raw_call()

    def tearDown(self):
        self.state.close(); self.history.close(); self.temp.cleanup()

    def add_actor(self, id, name, parent, path):
        source = {"subagent": {"thread_spawn": {"parent_thread_id": parent}}} if parent else "cli"
        self.state.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)",
                           (id, name, name, "Reviewer" if parent else None, path,
                            "subagent" if parent else "user", json.dumps(source) if parent else source,
                            str(self.path) if id == "parent" else str(self.home / (id + ".jsonl"))))
        if parent:
            self.state.execute("INSERT INTO thread_spawn_edges VALUES(?,?,?)", (parent, id, "open"))

    def add_turn(self, thread, turn, ordinal, start, end):
        self.history.execute("INSERT INTO thread_turns(thread_id,turn_id,status,started_at,completed_at,duration_ms,rollout_ordinal,rollout_byte_offset,rollout_end_byte_offset) VALUES(?,?,?,?,?,?,?,?,?)",
                             (thread, turn, "completed", start, end, (end - start) * 1000 if end is not None else None, ordinal, None, None))

    def add_message(self, thread, turn, id, kind, at, value, ordinal=1):
        item = dict(value, type=kind, id=id)
        ms = at * 1000 if at is not None else None
        self.history.execute("INSERT INTO thread_items VALUES(?,?,?,?,?,?,?,?,?)",
                             (thread, turn, id, kind, json.dumps(item), ms, ms, ms, ordinal))

    def raw_call(self, namespace="collaboration", output="", target="/root/reviewer", call_id="call-1",
                 header_id="parent", context_turn="main", include_output=True, name="followup_task"):
        def record(type, payload, at=140):
            stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat()
            return (json.dumps({"timestamp": stamp, "type": type, "payload": payload}) + "\n").encode()
        header = record("session_meta", {"id": header_id})
        content = record("event_msg", {"type": "task_started", "turn_id": context_turn}, 100)
        content += record("response_item", {"type": "function_call", "name": name,
                                           "namespace": namespace, "call_id": call_id,
                                           "arguments": json.dumps({"target": target, "message": "Review the edge case."})})
        if include_output:
            content += record("response_item", {"type": "function_call_output", "call_id": call_id, "output": output}, 141)
        self.path.write_bytes(header + content)
        self.history.execute("UPDATE thread_turns SET rollout_byte_offset=?,rollout_end_byte_offset=? WHERE thread_id='parent' AND turn_id='main'",
                             (len(header), len(header) + len(content)))

    def reader(self):
        self.state.commit(); self.history.commit()
        return cm.SavedConversations(self.home)

    def load(self, thread="parent", start=100, end=400):
        r = self.reader()
        try: return r.load(thread, start, end)
        finally: r.close()

    def test_real_turns_messages_and_independent_numbering(self):
        value = self.load()
        self.assertEqual(value["root"]["id"], "parent")
        self.assertEqual(len(value["turns"]), 2)
        numbers = {t["thread"]: t["number"] for t in value["turns"]}
        self.assertEqual(numbers, {"parent": 2, "child": 1})
        messages = {m["item"]: m for m in value["messages"]}
        self.assertEqual(messages["input"]["at"], 110)
        self.assertEqual(messages["progress"]["phase"], "commentary")
        self.assertEqual(messages["child-final"]["preview"], "Child final")
        self.assertEqual(len(value["handoffs"]), 1)
        self.assertEqual(value["handoffs"][0]["senderTurn"], "main")
        self.assertNotIn("recipientTurn", value["handoffs"][0])

    def test_source_ownership_does_not_fabricate_timed_handoff(self):
        self.raw_call(include_output=False)
        value = self.load("child")
        self.assertEqual(value["root"]["id"], "parent")
        self.assertEqual(len(value["actors"]), 2)
        self.assertEqual(value["handoffs"], [])

    def test_unrecorded_or_failed_calls_are_not_links(self):
        for arguments in ({"namespace": "unrelated"}, {"output": "Error: recipient unavailable"},
                          {"output": json.dumps({"isError": True})}, {"output": json.dumps({"status": "failed"})}, {"call_id": None},
                          {"context_turn": "different-turn"}, {"header_id": "different-thread"}):
            with self.subTest(arguments=arguments):
                self.raw_call(**arguments)
                self.assertEqual(self.load()["handoffs"], [])

    def test_ambiguous_canonical_target_is_not_guessed(self):
        self.add_actor("other", "Other", "parent", "/root/reviewer")
        self.assertEqual(self.load()["handoffs"], [])
        self.raw_call(target="child")
        self.assertEqual(self.load()["handoffs"][0]["recipient"], "child")

    def test_indexed_completed_collaboration_is_recorded_evidence(self):
        self.raw_call(include_output=False)
        item = dict(type="collabAgentToolCall", id="native", tool="spawnAgent", status="completed",
                    senderThreadId="parent", receiverThreadIds=["child"], prompt="Inspect.")
        self.add_message("parent", "main", "native", "collabAgentToolCall", 130, item)
        links = self.load()["handoffs"]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["recipient"], "child")
        self.assertIsNone(links[0]["byteOffset"])
        self.history.execute("UPDATE thread_items SET item_json=? WHERE item_id='native'",
                             (json.dumps(dict(item, status="failed")),))
        self.assertEqual(self.load()["handoffs"], [])

    def test_full_message_and_non_text_content_preserved(self):
        r = self.reader()
        try:
            text = r.full_message("child", "child-turn", "child-input")
            self.assertEqual(text["text"], "Delegated prompt\n[image]")
            self.assertFalse(text["truncated"])
        finally: r.close()

    def test_unknown_times_remain_unknown(self):
        self.add_message("child", "child-turn", "undated", "agentMessage", None, {"text": "Unknown timestamp"})
        message = next(m for m in self.load()["messages"] if m["item"] == "undated")
        self.assertIsNone(message["at"])

    def test_source_databases_are_readonly_and_unchanged(self):
        self.state.commit(); self.history.commit()
        paths = [self.home / "state_5.sqlite", self.home / "thread_history_1.sqlite"]
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
        r = self.reader()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                r.state.execute("DELETE FROM threads")
            with self.assertRaises(sqlite3.OperationalError):
                r.history.execute("DELETE FROM thread_items")
            r.load("parent", 100, 400)
        finally: r.close()
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths])

    def test_preview_and_full_message_limits(self):
        body = "x" * (cm.FULL_BYTES + 20)
        self.add_message("child", "child-turn", "large", "agentMessage", 195, {"text": body})
        self.assertLessEqual(len(next(m for m in self.load()["messages"] if m["item"] == "large")["preview"].encode()), cm.PREVIEW_BYTES)
        r = self.reader()
        try:
            value = r.full_message("child", "child-turn", "large")
            self.assertTrue(value["truncated"])
            self.assertEqual(len(value["text"].encode()), cm.FULL_BYTES)
        finally: r.close()

    def test_timezone_less_raw_timestamps_are_not_assumed(self):
        self.assertIsNone(cm.stamp("2026-10-10T20:00:00"))

    def test_fallback_message_times_obey_selected_window(self):
        self.add_message("child", "child-turn", "earlier", "agentMessage", None, {"text": "Earlier"})
        self.history.execute("UPDATE thread_items SET started_at_ms=90000 WHERE item_id='earlier'")
        self.assertNotIn("earlier", {m["item"] for m in self.load()["messages"]})

    def test_oversized_full_record_is_rejected_without_transfer(self):
        self.add_message("child", "child-turn", "oversized", "agentMessage", 190, {"text": "x" * (cm.MAX_RECORD + 1)})
        value = self.load()
        self.assertNotIn("oversized", {m["item"] for m in value["messages"]})
        self.assertTrue(any("16 MiB" in warning for warning in value["warnings"]))
        r = self.reader()
        try:
            with self.assertRaisesRegex(ValueError, "16 MiB"):
                r.full_message("child", "child-turn", "oversized")
        finally: r.close()

    def test_opaque_prompt_is_not_presented_as_readable_message(self):
        self.assertIn("encoded", cm.prompt_preview("gAAAA" + "x" * 150))
        self.assertEqual(cm.prompt_preview("Review the change."), "Review the change.")

    def test_child_to_parent_call_belongs_to_child_turn(self):
        def record(type, payload, at=180):
            return (json.dumps({"timestamp": datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat(), "type": type, "payload": payload}) + "\n").encode()
        header = record("session_meta", {"id": "child"})
        content = record("event_msg", {"type": "task_started", "turn_id": "child-turn"}, 150)
        content += record("response_item", {"type": "function_call", "namespace": "collaboration", "name": "send_message", "call_id": "child-call", "arguments": json.dumps({"target": "parent", "message": "Review complete."})})
        content += record("response_item", {"type": "function_call_output", "call_id": "child-call", "output": ""}, 181)
        (self.home / 'child.jsonl').write_bytes(header + content)
        self.history.execute("UPDATE thread_turns SET rollout_byte_offset=?,rollout_end_byte_offset=? WHERE thread_id='child'", (len(header), len(header) + len(content)))
        link = next(h for h in self.load()["handoffs"] if h["sender"] == "child")
        self.assertEqual(link["senderTurn"], "child-turn")
        self.assertEqual(link["recipient"], "parent")
        self.assertNotIn("recipientTurn", link)

    def test_message_pages_weave_real_parent_and_child_messages(self):
        self.history.execute("UPDATE thread_turns SET final_agent_item_id='final' WHERE thread_id='parent' AND turn_id='main'")
        r = self.reader()
        try:
            first = r.messages_page('parent', limit=2)
            self.assertEqual([m['message']['item'] for m in first['messages']], ['final', 'child-final'])
            self.assertTrue(first['messages'][0]['finalForTurn'])
            self.assertFalse(first['messages'][1]['finalForTurn'])
            self.assertTrue(first['hasEarlier'])
            seen = first['messages']
            page = first
            while page['hasEarlier']:
                page = r.messages_page('parent', before=json.loads(page['next']), limit=2)
                seen += page['messages']
            self.assertEqual([m['message']['item'] for m in seen], ['final','child-final','progress','child-input','input'])
            self.assertEqual(len({m['message']['id'] for m in seen}), 5)
            self.assertNotIn('handoffs', first)
        finally: r.close()

    def test_message_page_ties_and_unknown_times_do_not_skip_or_duplicate(self):
        self.add_message('parent','main','same-time','agentMessage',190,{'text':'Same clock time'},ordinal=15)
        self.add_message('child','child-turn','undated','agentMessage',None,{'text':'Unknown clock time'})
        r = self.reader()
        try:
            ids = []
            page = r.messages_page('child', limit=1)
            while True:
                ids += [m['message']['item'] for m in page['messages']]
                if not page['hasEarlier']: break
                page = r.messages_page('parent', before=json.loads(page['next']), limit=1)
            self.assertEqual(len(ids),7)
            self.assertEqual(len(set(ids)),7)
            self.assertEqual(ids[-1],'undated')
            self.assertIsNone(page['messages'][0]['message']['at'])
        finally: r.close()

    def test_message_pages_preserve_accepted_steering_input_and_attachments(self):
        self.add_message('parent','main','steer','steeringUserMessage',180,{'status':'accepted','input':[{'type':'text','text':'New direction'},{'type':'image'}]})
        self.add_message('parent','main','pending','steeringUserMessage',181,{'status':'pending','input':[{'type':'text','text':'Not accepted'}]})
        r = self.reader()
        try:
            messages = {m['message']['item']:m['message'] for m in r.messages_page('parent',limit=20)['messages']}
            self.assertEqual(messages['steer']['preview'],'New direction\n[image]')
            self.assertEqual(messages['steer']['role'],'user')
            self.assertNotIn('pending',messages)
            self.assertEqual(r.full_message('parent','main','steer')['text'],'New direction\n[image]')
        finally: r.close()

    def test_messages_page_rejects_bad_cursor_and_preserves_readonly_sources(self):
        self.state.commit(); self.history.commit()
        paths=[self.home/'state_5.sqlite',self.home/'thread_history_1.sqlite',self.path]
        before=[hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
        r = self.reader()
        try:
            with self.assertRaises(ValueError): r.messages_page('parent',before=['bad'])
            r.messages_page('parent')
            r.messages_page('parent', with_routing=True)
        finally: r.close()
        self.assertEqual(before,[hashlib.sha256(p.read_bytes()).hexdigest() for p in paths])

    def test_routing_page_includes_only_recorded_calls_in_displayed_interval(self):
        r = self.reader()
        try:
            whole = r.messages_page('parent', limit=10, with_routing=True)
            self.assertEqual(len(whole['routing']),1)
            self.assertEqual(whole['routing'][0]['sender'],'parent')
            self.assertEqual(whole['routing'][0]['recipient'],'child')
            self.assertEqual(whole['routing'][0]['at'],140)
            latest = r.messages_page('parent', limit=2, with_routing=True)
            self.assertEqual(latest['routing'],[])
            older = r.messages_page('parent',before=json.loads(latest['next']),limit=4,with_routing=True)
            self.assertEqual(len(older['routing']),1)
        finally:r.close()

    def test_coarse_turn_end_does_not_hide_a_precisely_timed_call(self):
        self.history.execute("UPDATE thread_turns SET completed_at=140 WHERE thread_id='parent' AND turn_id='main'")
        self.raw_call()
        lines=[json.loads(line) for line in self.path.read_text().splitlines()]
        for line in lines:
            if line['payload'].get('type')=='function_call':
                line['timestamp']=datetime.datetime.fromtimestamp(140.25,datetime.timezone.utc).isoformat()
            if line['payload'].get('type')=='function_call_output':
                line['timestamp']=datetime.datetime.fromtimestamp(140.26,datetime.timezone.utc).isoformat()
        raw=('\n'.join(json.dumps(line) for line in lines)+'\n').encode()
        self.path.write_bytes(raw)
        header=len((json.dumps(lines[0])+'\n').encode())
        self.history.execute("UPDATE thread_turns SET rollout_byte_offset=?,rollout_end_byte_offset=? WHERE thread_id='parent' AND turn_id='main'",(header,len(raw)))
        r=self.reader()
        try:
            _,actors=r.family('parent')
            routes=r.routing_window(actors,140.2,140.3)
            self.assertEqual(len(routes),1)
            self.assertEqual(routes[0]['at'],140.25)
        finally:r.close()

    def test_activity_completion_and_ownership_are_not_message_routes(self):
        self.raw_call(include_output=False)
        self.add_message('parent','main','status','subAgentActivity',185,{'kind':'completed','agentThreadId':'child'})
        r = self.reader()
        try:
            page=r.messages_page('parent',limit=10,with_routing=True)
            self.assertEqual(page['routing'],[])
            self.assertEqual(next(a for a in page['actors'] if a['id']=='child')['parent'],'parent')
        finally:r.close()

    def test_recorded_spawn_requires_matching_saved_creator(self):
        self.raw_call(name='spawn_agent',output=json.dumps({'agent_id':'child'}))
        r = self.reader()
        try:
            self.assertEqual(r.messages_page('parent',limit=10,with_routing=True)['routing'][0]['kind'],'spawn_agent')
        finally:r.close()
        self.raw_call(name='spawn_agent',output=json.dumps({'agent_id':'parent'}))
        self.assertEqual(self.load()['handoffs'],[])
        self.add_actor('grandchild','Tester','child','/root/reviewer/tester')
        self.raw_call(name='spawn_agent',output=json.dumps({'agent_id':'grandchild'}))
        value=self.load()
        self.assertEqual(value['handoffs'],[])
        self.assertTrue(any('conflicts' in warning for warning in value['warnings']))

    def test_subagent_can_send_to_parent_and_spawn_its_own_subagent(self):
        self.add_actor('grandchild','Tester','child','/root/reviewer/tester')
        def record(payload,at=180,type='response_item'):
            return (json.dumps({'timestamp':datetime.datetime.fromtimestamp(at,datetime.timezone.utc).isoformat(),'type':type,'payload':payload})+'\n').encode()
        header=record({'id':'child'},type='session_meta')
        body=record({'type':'task_started','turn_id':'child-turn'},150,'event_msg')
        for id,name,args,out,at in [('back','send_message',{'target':'parent','message':'Review done.'},'',180),('spawn','spawn_agent',{'task_name':'tester','message':'Check it.'},json.dumps({'agent_id':'grandchild'}),182)]:
            body+=record({'type':'function_call','namespace':'collaboration','name':name,'call_id':id,'arguments':json.dumps(args)},at)
            body+=record({'type':'function_call_output','call_id':id,'output':out},at+1)
        (self.home/'child.jsonl').write_bytes(header+body)
        self.history.execute("UPDATE thread_turns SET rollout_byte_offset=?,rollout_end_byte_offset=? WHERE thread_id='child'",(len(header),len(header)+len(body)))
        r = self.reader()
        try:
            routes=r.messages_page('parent',limit=10,with_routing=True)['routing']
            self.assertTrue(any(h['sender']=='child' and h['recipient']=='parent' and h['kind']=='send_message' for h in routes))
            self.assertTrue(any(h['sender']=='child' and h['recipient']=='grandchild' and h['kind']=='spawn_agent' for h in routes))
            self.assertTrue(all('recipientTurn' not in h for h in routes))
        finally:r.close()


if __name__ == "__main__":
    unittest.main()
