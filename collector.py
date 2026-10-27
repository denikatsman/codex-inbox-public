#!/usr/bin/python3
"""Read-only Codex observer. JSON lines to stdout; no model/network API calls.

Uses the installed desktop's private IPC protocol (version checked), plus its
read-only history projection. Never claims ownership or sends task actions.
"""
import argparse
import copy
from collections import OrderedDict
import json
import os
import re
import html
from pathlib import Path
import select
import socket
import sqlite3
import struct
import sys
import time
import uuid


MAX_RECORD_BYTES = 16 * 1024 * 1024
PAGE_SIZE = 64
WINDOW_SIZE = 2048


def task_origin(value):
    """Explicit origin evidence only. A durable host or aeon source is not Dot."""
    source = value.get('source')
    if isinstance(source, str):
        try: source = json.loads(source)
        except ValueError: source = {}
    source = source if isinstance(source, dict) else {}
    child = source.get('subagent', source.get('subAgent', {}))
    child = child if isinstance(child, dict) else {}
    spawn = child.get('thread_spawn', {})
    spawn = spawn if isinstance(spawn, dict) else {}
    originator = value.get('originator')
    result = {k: value[k] for k in ('originator', 'threadSource', 'agentNickname', 'agentRole') if value.get(k) is not None}
    if isinstance(originator, str) and originator in ('orbit_cca', 'orbit_cca_desktop', 'orbit_cca_web'):
        result['origin'] = 'dot'
    elif child or value.get('threadSource') == 'subagent':
        result['origin'] = 'subagent'
    for target, key in [('agentNickname', 'agent_nickname'), ('agentRole', 'agent_role')]:
        if spawn.get(key): result[target] = spawn[key]
    parent = spawn.get('parent_thread_id') or value.get('parentThreadId')
    return result, parent


def delegation_parent(item):
    if item.get('type') != 'functionCallOutput' or item.get('namespace') != 'codex_app' or item.get('name') not in ('create_thread', 'send_message_to_thread'):
        return None
    body = item.get('output')
    if not isinstance(body, str) or not body.strip().startswith('<codex_delegation>') or not body.strip().endswith('</codex_delegation>'):
        return None
    parent = re.search(r'<source_thread_id>\s*([^<]+)\s*</source_thread_id>', body)
    if not parent: return None
    thread = html.unescape(parent.group(1)).strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', thread): return None
    return thread, 'created' if item['name'] == 'create_thread' else 'delegated'


class RecoveryGap(ValueError):
    pass


def emit(kind, **data):
    raw = json.dumps(dict(type=kind, **data), ensure_ascii=False)
    if len(raw.encode('utf-8')) > MAX_RECORD_BYTES:
        raise RecoveryGap('An envelope exceeds the 16 MiB limit; coverage was not acknowledged.')
    print(raw, flush=True)


def answer_metadata(text):
    """None means ordinary text, including invalid embedded metadata."""
    opening, closing = '<send_user_message_question_reply>', '</send_user_message_question_reply>'
    if opening not in text or closing not in text:
        return None
    before, rest = text.split(opening, 1)
    raw, after = rest.split(closing, 1)
    try:
        values = json.loads(raw)
        if isinstance(values, dict):
            values = [values]
        if not isinstance(values, list) or not all(
                isinstance(v, dict) and isinstance(v.get('questionItemId'), str)
                and bool(v['questionItemId']) and isinstance(v.get('answer'), str) for v in values):
            return None
        return values, before + after
    except (ValueError, TypeError):
        return None


def error_text(error):
    if isinstance(error, str):
        try:
            error = json.loads(error)
        except ValueError:
            return error
    if error is None:
        return ''
    if isinstance(error, dict) and isinstance(error.get('message'), str):
        return error['message']
    if isinstance(error, str):
        return error
    return json.dumps(error, sort_keys=True, separators=(',', ':'), ensure_ascii=False)



def patch(document, patches):
    document = copy.deepcopy(document)
    # Publish only the returned candidate; failures leave the original intact.
    for p in patches:
        path = p['path']
        if not path:
            if p['op'] != 'replace':
                raise ValueError('Unsupported root patch')
            document = copy.deepcopy(p['value'])
            continue
        target = document
        for key in path[:-1]:
            target = target[key]
        key = path[-1]
        if p['op'] == 'remove':
            if isinstance(target, list):
                target.pop(int(key))
            else:
                del target[key]
        elif p['op'] in ('add', 'replace'):
            value = copy.deepcopy(p['value'])
            if isinstance(target, list) and p['op'] == 'add':
                target.insert(int(key), value)
            else:
                target[key] = value
        else:
            raise ValueError('Unsupported patch operation')
    return document


def project_metadata(home, tasks, database_projects, database_roots=()):
    """Prefer explicit Codex assignments, including its pre-migration cache.

    Explicit assignments override projectless markers; otherwise only a unique
    saved project root may match the task's cwd/workspace hint, as in Codex's
    sidebar. Never invent projects from folder names. Ambiguous roots stay blank.
    """
    path = Path(home) / '.codex-global-state.json'
    global_state = json.loads(path.read_text()) if path.exists() else {}
    legacy = global_state.get('local-projects', {})
    mappings = global_state.get('app-server-project-id-by-legacy-project-id-by-host', {}).get('local:' + str(Path(home)), {})
    assignments = global_state.get('thread-project-assignments', {})
    projectless = set(global_state.get('projectless-thread-ids', []))
    hints = global_state.get('thread-workspace-root-hints', {})
    names = dict(database_projects)
    roots = {}
    for pid, path in database_roots:
        roots.setdefault(os.path.normpath(path), set()).add(mappings.get(pid, pid))
    for pid, project in legacy.items():
        canonical = mappings.get(pid, pid)
        names.setdefault(canonical, project.get('name'))
        for path in project.get('rootPaths', []):
            roots.setdefault(os.path.normpath(path), set()).add(canonical)
    result = {}
    for task in tasks:
        tid, title, _, _, native_id, native_name = task[:6]
        assignment = assignments.get(tid, {})
        pid = native_id or assignment.get('projectId')
        pid = mappings.get(pid, pid) if pid else None
        if pid is None and tid not in projectless:
            cwd = task[6] if len(task) > 6 else None
            for path in [hints.get(tid), cwd]:
                if not isinstance(path, str) or not path:
                    continue
                path = os.path.normpath(path)
                matches = [(len(root), projects) for root, projects in roots.items() if path == root or path.startswith(root.rstrip('/') + '/')]
                if matches:
                    longest = max(length for length, _ in matches)
                    candidates = set().union(*(projects for length, projects in matches if length == longest))
                    if len(candidates) == 1:
                        pid = next(iter(candidates))
                    break
        result[tid] = dict(thread=tid, host='local', title=title, projectID=pid,
                           projectName=native_name or names.get(pid),
                           projectKnowledge="assigned" if pid else ("none" if tid in projectless else "unknown"))
    return result


class Observer:
    def __init__(self, home, since, inbox_db=None, parent_lifetime=False):
        self.home, self.since = Path(home), since
        self.started = time.time()
        self.sock = None
        self.client = None
        self.buffer = b''
        self.states = {}
        self.revisions = {}
        self.subscribed = set()
        self.wanted = set()
        self.titles = {}
        self.cursors = {}
        self.sent = OrderedDict()
        self.replies = OrderedDict()
        self.recovering = False
        self.resync = set()
        self.active = set()
        self.request_pins = set()
        self.prefetch = set()
        self.external = {}
        self.live_idle_boundary = {}
        self.boundaries = {}
        self.parent_lifetime = parent_lifetime
        self.next_connect = 0
        self.history_ok = False
        self.warning = ''
        self.last_status = None
        self.last_status_at = 0
        self.task_metadata = {}
        self.identity_cache = {}
        self.runtime_cache = {}
        self.runtime_published_at = {}
        self.relation_cache = OrderedDict()
        self.relationship_cursors = {}
        self.discovered_active = set()
        self.remote_known = set()
        self.spawn_edges = set()
        # The parent persists these only after committing every preceding event.
        # A crash before acknowledgement causes replay, never an advanced cursor
        # with missing activity. The collector never writes this database.
        if inbox_db and Path(inbox_db).exists():
            with sqlite3.connect(f'file:{Path(inbox_db)}?mode=ro', uri=True) as saved:
                for key, value in saved.execute("SELECT key,value FROM meta WHERE key LIKE 'cursor:%'"):
                    self.cursors[key.removeprefix('cursor:')] = int(value)
                for key, value in saved.execute("SELECT key,value FROM meta WHERE key LIKE 'relationships:v2:%'"):
                    self.relationship_cursors[key.removeprefix('relationships:v2:')] = int(value)
                if saved.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks'").fetchone():
                    for (raw,) in saved.execute("SELECT payload FROM tasks WHERE host<>'local'"):
                        value = json.loads(raw); key = (value['host'], value['thread'])
                        self.identity_cache[key] = value
                        self.remote_known.add(key)
                        self.wanted.add(key)

    def publish_task(self, value):
        key = (value['host'], value['thread'])
        merged = dict(self.identity_cache.get(key, {}), **value)
        if self.identity_cache.get(key) != merged:
            emit('tasks', tasks=[merged]); self.identity_cache[key] = merged

    def runtime(self, thread, host, status, turn=None, ordinal=None, source_at=None, source='live'):
        value = dict(thread=thread, host=host, status=status, turn=turn, sourceOrdinal=ordinal, sourceAt=source_at, source=source)
        key = (host, thread)
        now = time.monotonic()
        if self.runtime_cache.get(key) != value or (source == 'live' and now - self.runtime_published_at.get(key, 0) >= 30):
            emit('runtime', runtime=value); self.runtime_cache[key] = value
            self.runtime_published_at[key] = now
        if status in ('finished', 'failed', 'interrupted', 'idle'):
            self.discovered_active.discard(key)
            if self.identity_cache.get(key, {}).get('origin') != 'dot': self.remote_known.discard(key)

    def relation(self, thread, host, parent, kind, source_id, parent_host=None, source_at=None):
        if not isinstance(parent, str) or not parent or (parent_host == host and parent == thread): return
        value = dict(thread=thread, host=host, parentThread=parent, parentHost=parent_host, kind=kind, sourceID=source_id, sourceAt=source_at)
        key = (host, thread, kind, source_id)
        if self.relation_cache.get(key) == value: return
        emit('relation', relation=value); self.cache(self.relation_cache, key, value)

    def relationship_item(self, thread, host, item, created=None):
        parent = delegation_parent(item)
        if parent:
            self.relation(thread, host, parent[0], parent[1], item.get('id', parent[0]), source_at=created)
        if item.get('type') == 'subAgentActivity' and isinstance(item.get('agentThreadId'), str):
            child = item['agentThreadId']
            # Activity can be an interaction with an existing user chat. It is
            # not creation evidence; native metadata/spawn calls establish that.
            self.relation(child, host, thread, 'delegated', 'activity:' + thread, parent_host=host, source_at=created)
            if item.get('kind') == 'started':
                self.discovered_active.add((host, child)); self.follow(host, child)
                self.runtime(child, host, 'working', source='parent', source_at=created)
            elif item.get('kind') in ('completed', 'failed', 'interrupted'):
                self.runtime(child, host, {'completed': 'finished'}.get(item['kind'], item['kind']), source='parent', source_at=created)
        if item.get('type') == 'collabAgentToolCall' and item.get('tool') == 'spawnAgent' and item.get('status') == 'completed':
            for child in item.get('receiverThreadIds', []):
                if isinstance(child, str):
                    self.relation(child, host, thread, 'subagent', 'spawn:' + thread, parent_host=host, source_at=created)
                    self.discovered_active.add((host, child)); self.follow(host, child)
                    self.runtime(child, host, 'working', source='parent', source_at=created)
        # Successful creation results identify children before they have local history.
        is_create = item.get('tool') == 'create_thread' and (item.get('server') == 'codex_app' or item.get('namespace') == 'codex_app')
        if is_create and item.get('status') == 'completed' and not item.get('error'):
            result = item.get('result') or {}
            if isinstance(result, dict) and result.get('isError'): return
            candidates = [result.get('structuredContent')] if isinstance(result, dict) else []
            for part in result.get('content', []) if isinstance(result, dict) else []:
                if isinstance(part, dict) and part.get('type') == 'text':
                    try: candidates.append(json.loads(part.get('text', '')))
                    except (ValueError, TypeError): pass
            for child in candidates:
                if not isinstance(child, dict) or child.get('isError'): continue
                tid, target_host = child.get('threadId'), child.get('hostId')
                if isinstance(tid, str) and isinstance(target_host, str):
                    self.relation(tid, target_host, thread, 'created', item.get('id', tid), parent_host=host, source_at=created)
                    self.discovered_active.add((target_host, tid)); self.follow(target_host, tid)
                    if target_host != 'local': self.remote_known.add((target_host, tid))

    def cache(self, cache, key, value):
        # Two bounded live caches. Recovery never puts payloads in either cache.
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > 256 or sum(len(json.dumps(v).encode()) for v in cache.values()) > 4 * 1024 * 1024:
            cache.popitem(last=False)

    def output_event(self, event, live=False):
        event.setdefault('created', time.time())
        event.setdefault('host', 'local')
        event.setdefault('title', self.titles.get((event['host'], event['thread']), 'Codex task'))
        event.setdefault('resolved', False)
        event.setdefault('historical', event['created'] < self.since)
        previous = None if self.recovering else self.sent.get(event['id'])
        if previous:
            if event.get('timeSource') != 'codex' or previous.get('timeSource') == 'codex':
                event['created'] = previous['created']
                event['timeSource'] = previous.get('timeSource')
            event['historical'] = previous['historical']
            event['sourceOrdinal'] = event.get('sourceOrdinal', previous.get('sourceOrdinal'))
            if previous.get('deadline') is not None and event.get('estimated', True):
                event['deadline'] = previous['deadline']
                event['estimated'] = previous.get('estimated', False)
        if previous == event:
            return
        # Discovery is saved quietly, independently of the previous shutdown
        # cutoff. Polling may announce a source-timed event created this run.
        announce = live or (self.recovering and event.get('timeSource') == 'codex'
                            and event['created'] >= self.started)
        emit('event', event=event, announce=announce)
        if not self.recovering:
            self.cache(self.sent, event['id'], event)

    def item(self, thread, turn, item, created=None, host='local', live=False, ordinal=None):
        self.relationship_item(thread, host, item, created)
        typ, item_id = item.get('type'), item.get('id', '')
        if typ in ('userMessage', 'steeringUserMessage'):
            if typ == 'steeringUserMessage' and item.get('status') != 'accepted':
                return
            meaningful, answered = [], []
            for part in item.get('content', item.get('input', [])) or []:
                if not isinstance(part, dict):
                    continue
                text = part.get('text') if isinstance(part.get('text'), str) else ''
                parsed = answer_metadata(text)
                if parsed is not None:
                    answers, remainder = parsed
                    answered.extend(v['questionItemId'] for v in answers if v['answer'].strip())
                    if not remainder.strip() and not any(v['answer'].strip() for v in answers):
                        continue
                if text.strip() or part.get('type') not in ('text', None):
                    meaningful.append(text or '[' + str(part.get('type', 'attachment')) + ']')
            if not item_id or not meaningful:
                return
            rid = f'{host}:{thread}:message:{item_id}'
            aliases = ['item:' + item_id] + (['server:' + item_id] if typ == 'userMessage' else [])
            for field, kind in [('serverUserMessageId', 'server'), ('userMessageId', 'server'), ('serverMessageId', 'server'),
                                ('clientUserMessageId', 'client'), ('clientId', 'client')]:
                if isinstance(item.get(field), str) and item[field]:
                    aliases.append(kind + ':' + item[field])
            reply = dict(id=rid, thread=thread, host=host, body='\n'.join(meaningful),
                         created=created, sourceOrdinal=ordinal, live=live,
                         provenance='new_action' if live else 'discovery',
                         aliases=sorted(set(aliases)), answeredQuestionIDs=sorted(set(answered)))
            previous = None if self.recovering else self.replies.get(rid)
            if previous:
                reply['created'] = previous['created'] if previous['created'] is not None else created
                reply['sourceOrdinal'] = ordinal if ordinal is not None else previous['sourceOrdinal']
                reply['live'] = previous['live']
                reply['provenance'] = previous['provenance']
            if reply != previous:
                emit('reply', reply=reply)
                if not self.recovering:
                    self.cache(self.replies, rid, reply)
            return
        if typ != 'agentMessage' or not item_id:
            return
        text = (item.get('text') or '').strip()
        if item.get('delivery') == 'async':
            questions = item.get('questions') or [{'title': text}]
            for index, q in enumerate(questions):
                qid = json.dumps(['request_user_input_async', item_id, index], separators=(',', ':')) if item.get('questions') else item_id
                event_id = f'{host}:{thread}:question:{item_id}:{index}'
                when = created if created is not None else time.time()
                event = dict(id=event_id, thread=thread, turn=turn, host=host, questionID=qid,
                             kind='question', body=q.get('title', text), created=when,
                             sourceOrdinal=ordinal, timeSource='codex' if created is not None else ('observed' if live else 'unknown'))
                if created is None and not live:
                    event['historical'] = True
                if live and event_id not in self.sent:
                    event.update(deadline=when + 30, estimated=True)
                self.output_event(event, live=live)

    def completed(self, thread, turn, body='', error=None, created=None, host='local', ordinal=None, live=False, status='completed'):
        rendered = error_text(error)
        failed = status in ('failed', 'interrupted') or bool(rendered)
        fallback = 'Work interrupted. Reason unavailable.' if status == 'interrupted' else 'Codex failed without supplying error details.'
        self.output_event(dict(id=f'{host}:{thread}:turn:{turn}', thread=thread,
                               turn=turn, host=host, kind='error' if failed else 'completion',
                               terminalStatus='failed' if rendered and status == 'completed' else status,
                               body=(rendered or fallback) if failed else (body or 'Codex finished working.'),
                               created=created if created is not None else time.time(), sourceOrdinal=ordinal,
                               timeSource='codex' if created is not None else ('observed' if live else 'unknown'),
                               historical=(created < self.since) if created is not None else not live), live=live)

    def inspect_state(self, host, thread, live=False, new_items=()):
        key = (host, thread)
        state = self.states[key]
        title = state.get('generatedTitle') or state.get('title') or self.titles.get(key) or self.identity_cache.get(key, {}).get('title', 'Codex task')
        origin, parent = task_origin(state)
        self.publish_task(dict(thread=thread, host=host, title=title, **origin))
        if host != 'local': self.remote_known.add(key)
        if parent:
            native_agent = origin.get('origin') == 'subagent'
            parent_host = host if native_agent else state.get('parentHostId')
            self.relation(thread, host, parent, 'subagent' if native_agent else 'created', 'native-parent', parent_host=parent_host if isinstance(parent_host, str) else None)
        if self.titles.get(key) != title:
            self.titles[key] = title
            emit('task_title', thread=thread, host=host, title=title)
        current_turns = state.get('turns', [])
        turns = list(current_turns) + list(state.get('turnHistory', {}).get('history', {}).get('entitiesByKey', {}).values())
        for turn in turns:
            tid = turn.get('turnId', turn.get('id', ''))
            items = turn.get('items', [])
            for item in items:
                iid = item.get('id', '')
                timestamp = turn.get('aeonAssistantMessageStartedAtMsById', {}).get(iid)
                if item.get('type') == 'userMessage':
                    timestamp = turn.get('turnStartedAtMs')
                when = timestamp / 1000 if isinstance(timestamp, (float, int)) else None
                self.item(thread, tid, item, host=host, live=(tid, iid) in new_items, created=when)
            if tid and turn.get('status') in ('completed', 'failed', 'interrupted'):
                final = next((i.get('text', '') for i in reversed(items) if i.get('type') == 'agentMessage' and i.get('delivery') != 'async'), '')
                start, duration = turn.get('turnStartedAtMs'), turn.get('durationMs')
                at = (start + duration) / 1000 if isinstance(start, (int, float)) and isinstance(duration, (int, float)) else None
                self.completed(thread, tid, final, turn.get('error'), created=at, host=host, live=live, status=turn['status'])
        requests = []
        for request in state.get('requests', []):
            method, params = request.get('method', ''), request.get('params') or {}
            rid = str(request.get('id', ''))
            if not rid:
                continue
            if 'requestUserInput' in method:
                kind, questions = 'question', params.get('questions') or [{'question': 'Codex needs your input.'}]
            elif 'Approval' in method or 'approval' in method:
                kind, questions = 'approval', [{'question': params.get('reason') or params.get('command') or 'Codex needs your permission.'}]
            elif method == 'mcpServer/elicitation/request':
                kind, questions = 'input', [{'question': params.get('message') or 'A connected tool needs your input.'}]
            else:
                continue
            source = {k: params[k] for k in ('turnId', 'itemId', 'callId') if isinstance(params.get(k), str) and params[k]}
            for index, q in enumerate(questions):
                identity = json.dumps([host, thread, method, source, rid, q.get('id'), index], sort_keys=True, separators=(',', ':'))
                value = dict(identity=identity, opaque=not bool(source), kind=kind,
                             body=str(q.get('question') or q.get('title') or 'Input requested'))
                deadline = params.get('deadlineMs')
                if isinstance(deadline, (int, float)):
                    value.update(deadline=deadline / 1000, estimated=False)
                elif params.get('isBlocking') is False or params.get('autoResolutionMs'):
                    value['timerUnavailable'] = True
                requests.append(value)
        # Only an accepted state that actually contains this field establishes absence.
        if 'requests' in state:
            if requests: self.request_pins.add(key)
            else: self.request_pins.discard(key)
        active = bool(state.get('requests')) or any(t.get('status') in ('inProgress', 'running') for t in current_turns)
        runtime = state.get('threadRuntimeStatus')
        runtime = runtime.get('type', runtime.get('status')) if isinstance(runtime, dict) else runtime
        active = active or runtime in ('running', 'busy', 'active', 'waitingForApproval', 'waitingForInput')
        latest = current_turns[-1] if current_turns else {}
        tid = latest.get('turnId', latest.get('id'))
        status = None
        if state.get('requests') or runtime in ('waitingForApproval', 'waitingForInput'):
            status = 'waiting_user'
        elif active:
            waiting = any(i.get('type') == 'collabAgentToolCall' and i.get('tool') == 'wait' and i.get('status') == 'inProgress' for i in latest.get('items', []))
            status = 'waiting_agents' if waiting else 'working'
        elif runtime in ('idle', 'completed', 'failed', 'interrupted'):
            status = {'completed': 'finished'}.get(runtime, runtime)
        elif latest.get('status') in ('completed', 'failed', 'interrupted'):
            status = {'completed': 'finished'}.get(latest['status'], latest['status'])
        if status: self.runtime(thread, host, status, turn=tid, ordinal=self.boundaries.get(thread) if host == 'local' else None)
        elif 'requests' in state and self.runtime_cache.get(key, {}).get('status') == 'waiting_user':
            self.runtime(thread, host, 'waiting_user', turn=tid, source='unconfirmed')
        if active:
            self.active.add(key)
            self.live_idle_boundary.pop(key, None)
        elif runtime in ('idle', 'completed', 'failed', 'interrupted') or (current_turns and all(t.get('status') in ('completed', 'failed', 'interrupted') for t in current_turns)):
            self.active.discard(key)
            self.live_idle_boundary[key] = self.boundaries.get(thread)
        self.wanted.add(key)
        if 'requests' in state:
            emit('requests', thread=thread, host=host, requests=requests, announce=live)

    def send(self, data):
        raw = json.dumps(data).encode()
        self.sock.sendall(struct.pack('<I', len(raw)) + raw)

    def follow(self, host, thread, force=False):
        self.wanted.add((host, thread))
        if not self.client or ((host, thread) in self.subscribed and not force):
            return
        self.send(dict(type='broadcast', method='thread-stream-following-changed',
                       version=1, sourceClientId=self.client,
                       params=dict(hostId=host, conversationId=thread, following=True)))
        self.subscribed.add((host, thread))

    def sync_subscriptions(self):
        desired = self.prefetch | self.active | self.request_pins | self.discovered_active | self.remote_known | {k for k, clients in self.external.items() if clients}
        try:
            for host, thread in self.wanted - desired:
                if self.client and (host, thread) in self.subscribed:
                    self.send(dict(type='broadcast', method='thread-stream-following-changed', version=1,
                                   sourceClientId=self.client, params=dict(hostId=host, conversationId=thread, following=False)))
                key = (host, thread)
                self.subscribed.discard(key)
                self.states.pop(key, None); self.revisions.pop(key, None); self.resync.discard(key)
                self.titles.pop(key, None)
                for cache in (self.sent, self.replies):
                    for identifier in [i for i, v in cache.items() if (v['host'], v['thread']) == key]:
                        del cache[identifier]
            self.wanted = desired
            for host, thread in list(desired):
                self.follow(host, thread)
        except OSError:
            self.disconnect()

    def message(self, msg):
        if msg.get('type') == 'client-discovery-request':
            self.send(dict(type='client-discovery-response', requestId=msg['requestId'], response={'canHandle': False}))
        elif msg.get('type') == 'response' and msg.get('method') == 'initialize':
            self.client = msg['result']['clientId']
            for host, thread in list(self.wanted):
                self.follow(host, thread)
        elif msg.get('type') == 'broadcast':
            method, params = msg.get('method'), msg.get('params', {})
            host, thread = params.get('hostId', 'local'), params.get('conversationId')
            key = (host, thread)
            if method == 'thread-stream-following-changed' and thread and msg.get('sourceClientId') != self.client:
                clients = self.external.setdefault(key, set())
                client = msg.get('sourceClientId', 'unknown')
                if params.get('following'):
                    clients.add(client); self.follow(host, thread)
                else:
                    clients.discard(client)
            if method == 'thread-stream-following-status-requested' and thread and key in self.wanted:
                self.follow(host, thread, force=True)
            if method != 'thread-stream-state-changed' or not thread:
                return
            if msg.get('version') != 11:
                self.warning = 'Codex updated its live connection. Using local history.'
                return
            change = params.get('change', {})
            new_items = set()
            if change.get('type') == 'snapshot':
                candidate = change['conversationState']
            elif change.get('type') == 'patches':
                if key in self.resync:
                    return
                if key not in self.states or self.revisions.get(key) != change.get('baseRevision'):
                    self.request_snapshot(host, thread)
                    return
                try:
                    candidate = patch(self.states[key], change['patches'])
                    # Only an individual append to an already observed running turn
                    # proves a new action. Containers/history/replacements are discovery.
                    for p in change['patches']:
                        path = p.get('path', [])
                        if p.get('op') == 'add' and len(path) == 4 and path[0] == 'turns' and path[2] == 'items':
                            old_turn = self.states[key]['turns'][path[1]]
                            if old_turn.get('status') == 'inProgress' and path[3] == len(old_turn.get('items', [])):
                                value = p.get('value', {})
                                new_items.add((old_turn.get('turnId', old_turn.get('id', '')), value.get('id', '')))
                except (KeyError, IndexError, TypeError, ValueError):
                    self.request_snapshot(host, thread)
                    return
            else:
                return
            if not isinstance(candidate, dict):
                self.request_snapshot(host, thread)
                return
            self.states[key] = candidate
            self.revisions[key] = change.get('revision')
            self.resync.discard(key)
            # Every accepted container can carry a request, terminal turn or title.
            self.inspect_state(host, thread, live=change.get('type') == 'patches', new_items=new_items)

    def request_snapshot(self, host, thread):
        key = (host, thread)
        previous = self.runtime_cache.get(key)
        if previous and previous['status'] in ('working', 'waiting_user', 'waiting_agents'):
            self.runtime(thread, host, previous['status'], turn=previous.get('turn'), source='unconfirmed')
        self.resync.add(key)
        self.follow(host, thread, force=True)

    def connect(self):
        if self.sock or time.monotonic() < self.next_connect:
            return
        try:
            path = self.home / 'ipc/ipc.sock'
            if path.stat().st_uid != os.getuid():
                raise OSError('Socket owner mismatch')
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(2)
            self.sock.connect(str(path))
            self.send(dict(type='request', requestId=str(uuid.uuid4()), method='initialize',
                           version=0, params={'clientType': 'codex-inbox-observer'}))
        except OSError:
            self.disconnect()

    def disconnect(self):
        if self.sock:
            self.sock.close()
        self.sock, self.client, self.buffer = None, None, b''
        self.subscribed.clear()
        self.states.clear()
        self.revisions.clear()
        self.resync.clear()
        self.external.clear()
        self.runtime_cache.clear()
        self.next_connect = time.monotonic() + 5

    def read_socket(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise OSError('Codex disconnected')
        self.buffer += chunk
        while len(self.buffer) >= 4:
            size = struct.unpack('<I', self.buffer[:4])[0]
            if not 0 < size <= 268435456:
                raise ValueError('Invalid Codex frame')
            if len(self.buffer) < size + 4:
                break
            raw, self.buffer = self.buffer[4:size + 4], self.buffer[size + 4:]
            self.message(json.loads(raw))

    def check_parent(self):
        if self.parent_lifetime and select.select([sys.stdin.fileno()], [], [], 0)[0]:
            if not os.read(sys.stdin.fileno(), 1):
                raise SystemExit(0)

    def service_live(self):
        self.check_parent()
        try:
            if self.sock and select.select([self.sock], [], [], 0)[0]:
                self.read_socket()
        except (OSError, ValueError, KeyError, TypeError):
            self.disconnect()
        # Publish connection/recovery progress even while a large initial history
        # pass is still running. status() coalesces unchanged observations.
        self.status()

    def checked_item(self, history, thread, turn, item_id):
        length = history.execute('SELECT length(CAST(item_json AS BLOB)) FROM thread_items WHERE thread_id=? AND turn_id=? AND item_id=?', (thread, turn, item_id)).fetchone()
        if length and length[0] > MAX_RECORD_BYTES:
            raise RecoveryGap(f'Task {thread}, item {item_id} exceeds 16 MiB; source preserved, recovery window paused.')
        row = history.execute('SELECT item_json FROM thread_items WHERE thread_id=? AND turn_id=? AND item_id=?', (thread, turn, item_id)).fetchone()
        return json.loads(row[0]) if row else {}

    def history_completion(self, history, thread, tid):
        row = history.execute('SELECT status,length(CAST(error_json AS BLOB)),completed_at,rollout_end_ordinal FROM thread_turns WHERE thread_id=? AND turn_id=?', (thread, tid)).fetchone()
        if not row or row[0] not in ('completed', 'failed', 'interrupted') or row[3] is None:
            return
        status, length, at, ordinal = row
        if length and length > MAX_RECORD_BYTES:
            raise RecoveryGap(f'Task {thread}, turn {tid} error exceeds 16 MiB; recovery window paused.')
        error = history.execute('SELECT error_json FROM thread_turns WHERE thread_id=? AND turn_id=?', (thread, tid)).fetchone()[0]
        body = ''
        for (iid,) in history.execute("SELECT item_id FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type='agentMessage' ORDER BY rollout_ordinal DESC", (thread, tid)):
            item = self.checked_item(history, thread, tid, iid)
            if item.get('delivery') != 'async':
                body = item.get('text', ''); break
        self.completed(thread, tid, body, error, created=(at / 1000 if at and at > 1e11 else at), ordinal=ordinal, status=status)

    def recover_window(self, history, thread):
        history.execute('BEGIN')
        self.recovering = True
        try:
            high = history.execute('SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id=?', (thread,)).fetchone()[0]
            start = self.cursors.get(thread, 0)
            if start > high:  # Source projection rebuilt; stable IDs make replay safe.
                start = 0
            end = min(high, start + WINDOW_SIZE)
            if end == start:
                return
            update = 'CASE WHEN updated_at_ordinal>0 THEN updated_at_ordinal ELSE rollout_ordinal END'
            last = (-1, -1, '', '')
            while True:
                keys = history.execute(f"SELECT {update},rollout_ordinal,turn_id,item_id,created_at_ms FROM thread_items WHERE thread_id=? AND {update}>=? AND {update}<? AND ({update},rollout_ordinal,turn_id,item_id)>(?,?,?,?) AND item_type IN ('agentMessage','userMessage','steeringUserMessage') ORDER BY {update},rollout_ordinal,turn_id,item_id LIMIT ?", (thread, start, end, *last, PAGE_SIZE)).fetchall()
                if not keys:
                    break
                for updated, original, turn, iid, ms in keys:
                    self.check_parent()
                    item = self.checked_item(history, thread, turn, iid)
                    self.item(thread, turn, item, created=ms / 1000 if ms is not None else None, ordinal=original)
                    if item.get('type') == 'agentMessage' and item.get('delivery') != 'async':
                        self.history_completion(history, thread, turn)
                last = keys[-1][:4]
            last_turn = (-1, '')
            while True:
                keys = history.execute("SELECT rollout_end_ordinal,turn_id FROM thread_turns WHERE thread_id=? AND rollout_end_ordinal>=? AND rollout_end_ordinal<? AND (rollout_end_ordinal,turn_id)>(?,?) AND status IN ('completed','failed','interrupted') ORDER BY rollout_end_ordinal,turn_id LIMIT ?", (thread, start, end, *last_turn, PAGE_SIZE)).fetchall()
                if not keys:
                    break
                for ordinal, tid in keys:
                    self.check_parent(); self.history_completion(history, thread, tid)
                last_turn = keys[-1]
            # The parent serially commits all preceding envelopes before this one.
            emit('cursor', thread=thread, ordinal=end)
            self.cursors[thread] = end
        finally:
            self.recovering = False
            history.rollback()  # Release the read-only snapshot between windows.

    def recover_relationships(self, history, thread, high):
        """Separate, acknowledged cursor; existing notification cursors are untouched."""
        start = self.relationship_cursors.get(thread, 0)
        if start > high: start = 0
        end = min(high, start + WINDOW_SIZE)
        if start == end: return
        history.execute('BEGIN')
        try:
            last = (-1, '', '')
            update = 'CASE WHEN updated_at_ordinal>0 THEN updated_at_ordinal ELSE rollout_ordinal END'
            while True:
                keys = history.execute(f"SELECT {update},turn_id,item_id,created_at_ms FROM thread_items WHERE thread_id=? AND {update}>=? AND {update}<? AND ({update},turn_id,item_id)>(?,?,?) AND item_type IN ('functionCallOutput','subAgentActivity','collabAgentToolCall','mcpToolCall','dynamicToolCall') ORDER BY {update},turn_id,item_id LIMIT ?", (thread, start, end, *last, PAGE_SIZE)).fetchall()
                if not keys: break
                for ordinal, turn, iid, ms in keys:
                    self.check_parent()
                    self.relationship_item(thread, 'local', self.checked_item(history, thread, turn, iid), ms / 1000 if ms is not None else None)
                last = keys[-1][:3]
            # Recover explicit outcomes for old notices without guessing from body text.
            last_turn = (-1, '')
            while True:
                turns = history.execute("SELECT rollout_end_ordinal,turn_id,status FROM thread_turns WHERE thread_id=? AND rollout_end_ordinal>=? AND rollout_end_ordinal<? AND (rollout_end_ordinal,turn_id)>(?,?) AND status IN ('completed','failed','interrupted') ORDER BY rollout_end_ordinal,turn_id LIMIT ?", (thread, start, end, *last_turn, PAGE_SIZE)).fetchall()
                if not turns: break
                for _, turn, status in turns:
                    self.check_parent(); emit('outcome', id=f'local:{thread}:turn:{turn}', terminalStatus=status)
                last_turn = turns[-1][:2]
            emit('relationship_cursor', thread=thread, ordinal=end)
            self.relationship_cursors[thread] = end
        finally: history.rollback()

    def read_history(self):
        state = sqlite3.connect(f'file:{self.home}/state_5.sqlite?mode=ro', uri=True, timeout=.15)
        history = sqlite3.connect(f'file:{self.home}/thread_history_1.sqlite?mode=ro', uri=True, timeout=.15)
        try:
            columns = {r[1] for r in state.execute('PRAGMA table_info(threads)')}
            has_projects = 'project_id' in columns and state.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='projects'").fetchone()
            fields = 't.project_id,p.name' if has_projects else 'NULL,NULL'
            join = ' LEFT JOIN projects p ON t.project_id=p.id' if has_projects else ''
            cwd = 't.cwd' if 'cwd' in columns else 'NULL'
            tasks = state.execute('SELECT t.id,COALESCE(t.name,t.title),t.updated_at,t.archived,' + fields + ',' + cwd + ' FROM threads t' + join).fetchall()
            evidence_fields = ['source', 'thread_source', 'originator', 'agent_nickname', 'agent_role']
            evidence_sql = ','.join(name if name in columns else 'NULL' for name in evidence_fields)
            evidence = {r[0]: dict(zip(['source', 'threadSource', 'originator', 'agentNickname', 'agentRole'], r[1:])) for r in state.execute('SELECT id,' + evidence_sql + ' FROM threads')}
            projects = dict(state.execute('SELECT id,name FROM projects')) if has_projects else {}
            roots = list(state.execute('SELECT project_id,path FROM project_roots')) if state.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='project_roots'").fetchone() else []
            try:
                metadata = project_metadata(self.home, tasks, projects, roots)
            except (OSError, ValueError, TypeError, AttributeError):
                metadata = {t[0]: dict(self.task_metadata.get(t[0], {}), thread=t[0], host='local', title=t[1]) for t in tasks}
                self.warning = 'Project labels unavailable: keeping last known assignments.'
            for tid, value in metadata.items():
                origin, parent = task_origin(evidence.get(tid, {})); value.update(origin)
                self.publish_task(value)
                if parent: self.relation(tid, 'local', parent, 'subagent', 'native-parent', parent_host='local')
            if state.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='thread_spawn_edges'").fetchone():
                edges = set(state.execute('SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges'))
                for parent, child in sorted(edges - self.spawn_edges):
                    self.relation(child, 'local', parent, 'subagent', 'native-parent', parent_host='local')
                self.spawn_edges = edges
            self.task_metadata = metadata
            self.titles.update({('local', t[0]): t[1] for t in tasks})
            tracked = {t[0] for t in tasks}
            self.titles = {k: v for k, v in self.titles.items() if k[0] != 'local' or k[1] in tracked}
            self.live_idle_boundary = {k: v for k, v in self.live_idle_boundary.items() if k[0] != 'local' or k[1] in tracked}
            self.prefetch = {('local', t[0]) for t in sorted((t for t in tasks if not t[3]), key=lambda t: t[2], reverse=True)[:12]}
            self.active = {k for k in self.active if k[0] != 'local' or k[1] in tracked}
            self.request_pins = {k for k in self.request_pins if k[0] != 'local' or k[1] in tracked}
            self.external = {k: v for k, v in self.external.items() if k[0] != 'local' or k[1] in tracked}
            turn_columns = {r[1] for r in history.execute('PRAGMA table_info(thread_turns)')}
            for thread in tracked:
                projected = history.execute('SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id=?', (thread,)).fetchone()
                if not projected:
                    continue
                ordinal = projected[0]
                key = ('local', thread)
                self.boundaries[thread] = ordinal
                if key in self.live_idle_boundary and self.live_idle_boundary[key] is None:
                    self.live_idle_boundary[key] = ordinal
                # Read the latest turn across the entire inventory, not just newest 12.
                order = 'rollout_ordinal' if 'rollout_ordinal' in turn_columns else 'rowid'
                latest = history.execute(f'SELECT status,turn_id FROM thread_turns WHERE thread_id=? ORDER BY {order} DESC LIMIT 1', (thread,)).fetchone()
                if latest:
                    live_turns = self.states.get(key, {}).get('turns', [])
                    live_ids = {t.get('turnId', t.get('id')) for t in live_turns if t.get('status') in ('inProgress', 'running')}
                    terminal = latest[0] in ('completed', 'failed', 'interrupted')
                    suppressed = key in self.live_idle_boundary and self.live_idle_boundary[key] == ordinal
                    if key not in self.states or (terminal and live_ids == {latest[1]}):
                        normalized = {'inProgress': 'working', 'running': 'working', 'completed': 'finished'}.get(latest[0], 'idle' if latest[0] == 'idle' else latest[0])
                        if not suppressed or terminal:
                            self.runtime(thread, 'local', normalized, turn=latest[1], ordinal=ordinal, source='history')
                if latest and latest[0] in ('inProgress', 'running') and not (key in self.live_idle_boundary and self.live_idle_boundary[key] == ordinal):
                    self.active.add(key)
                elif latest and latest[0] in ('completed', 'failed', 'interrupted'):
                    live_turns = self.states.get(key, {}).get('turns', [])
                    running = {t.get('turnId', t.get('id')) for t in live_turns if t.get('status') in ('inProgress', 'running')}
                    # The terminal projection of this same turn retires a stale
                    # live running snapshot. A distinct newer live turn stays pinned.
                    if key not in self.states or running == {latest[1]}:
                        self.active.discard(key)
                try:
                    self.recover_relationships(history, thread, ordinal)
                    self.recover_window(history, thread)
                except RecoveryGap as error:
                    self.warning = str(error)
                self.service_live()
            self.history_ok = True
            if self.warning.startswith('Local history unavailable:'):
                self.warning = ''
        finally:
            state.close(); history.close()
        # IPC failure must never abort a healthy database read.
        self.sync_subscriptions()

    def status(self):
        value = dict(connected=bool(self.client), history=self.history_ok,
                     tasks=len(self.titles), liveTasks=len(self.states),
                     warning=self.warning or (f'Resyncing {len(self.resync)} task' + ('s.' if len(self.resync) != 1 else '.') if self.resync else ''))
        now = time.monotonic()
        if value != self.last_status or now - self.last_status_at >= 30:
            emit('status', **value)
            self.last_status = value
            self.last_status_at = now

    def run(self):
        poll = 0
        while True:
            self.check_parent()
            self.connect()
            if time.monotonic() >= poll:
                try:
                    self.read_history()
                except (sqlite3.Error, OSError, ValueError) as e:
                    self.history_ok = False
                    self.warning = 'Local history unavailable: ' + type(e).__name__
                poll = time.monotonic() + 2
            try:
                if self.sock:
                    readable, _, _ = select.select([self.sock], [], [], .5)
                    if readable:
                        self.read_socket()
                else:
                    time.sleep(.5)
            except (OSError, ValueError, KeyError, TypeError):
                self.disconnect()
            self.status()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', default=str(Path.home() / '.codex'))
    parser.add_argument('--since', type=float, default=time.time())
    parser.add_argument('--inbox-db')
    parser.add_argument('--parent-lifetime', action='store_true', help='Exit when the app-owned stdin pipe closes; standalone runs omit this flag')
    args = parser.parse_args()
    try:
        Observer(args.home, args.since, args.inbox_db, args.parent_lifetime).run()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
