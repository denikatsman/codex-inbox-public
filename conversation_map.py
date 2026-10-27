#!/usr/bin/env python3
"""Bounded, read-only saved conversation access. No sockets, models, or writes."""
import argparse
import datetime
import json
import os
from pathlib import Path
import sqlite3
import time

MAX_THREADS = 200
MAX_TURNS = 400
MAX_MESSAGES = 2000
MAX_RECORD = 16 * 1024 * 1024
MAX_RAW = 32 * 1024 * 1024
PREVIEW_BYTES = 2048
FULL_BYTES = 1024 * 1024


def clip(text, limit):
    return str(text).encode("utf-8")[:limit].decode("utf-8", "ignore")


def prompt_preview(value):
    # Some saved tool arguments contain an opaque encrypted wire value.
    # Preserve the evidence, but do not present ciphertext as message text.
    if isinstance(value, str) and len(value) > 80 and value.startswith("gAAAA"):
        return "Saved call prompt is encoded; readable text is unavailable."
    return clip(value or "", PREVIEW_BYTES)


def connect(path):
    db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", timeout=2)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    db.execute("BEGIN")
    return db


def seconds(value):
    if value is None:
        return None
    value = float(value)
    return value / 1000 if value > 100000000000 else value


def stamp(value):
    try:
        value = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value.timestamp() if value.tzinfo is not None else None
    except (ValueError, AttributeError):
        return None


def decoded(value):
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return None


def message_text(item):
    if item.get("type") == "agentMessage":
        return str(item.get("text") or '\n'.join(str(q.get('title') or '') for q in item.get('questions') or [] if isinstance(q, dict)))
    parts = []
    for part in item.get("content") or item.get("input") or []:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text":
            parts.append(str(part.get("text") or ""))
        else:
            parts.append("[" + str(part.get("type") or "Attachment") + "]")
    return "\n".join(parts)


class SavedConversations:
    def __init__(self, home):
        self.home = Path(home)
        self.state = connect(self.home / "state_5.sqlite")
        try:
            self.history = connect(self.home / "thread_history_1.sqlite")
        except Exception:
            self.state.close()
            raise
        self.warnings = []

    def close(self):
        self.history.close()
        self.state.close()

    def actor(self, thread):
        row = self.state.execute(
            "SELECT id,COALESCE(name,title) AS title,agent_nickname,agent_path,"
            "thread_source,source,rollout_path FROM threads WHERE id=?", (thread,)
        ).fetchone()
        if row is None:
            return None
        source = decoded(row["source"]) or {}
        subagent = source.get("subagent") if isinstance(source, dict) else None
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        spawn = spawn if isinstance(spawn, dict) else {}
        name = row["title"] or row["agent_nickname"] or thread[:8]
        return dict(id=thread, name=clip(name, 1024),
                    isSubagent=row["thread_source"] == "subagent" or bool(spawn),
                    parent=spawn.get("parent_thread_id"), path=row["agent_path"],
                    rollout=row["rollout_path"])

    def family(self, requested):
        root = self.actor(requested)
        if root is None:
            raise ValueError("This conversation is not in the local saved history.")
        visited = {root["id"]}
        while root["isSubagent"] and root["parent"]:
            parent = self.actor(root["parent"])
            if parent is None or parent["id"] in visited:
                break
            visited.add(parent["id"])
            root = parent
        actors = [root]
        visited = {root["id"]}
        for actor in actors:
            rows = self.state.execute(
                "SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id=?",
                (actor["id"],)
            ).fetchall()
            rows += self.state.execute(
                "SELECT id FROM threads WHERE CASE WHEN json_valid(source) THEN "
                "json_extract(source,'$.subagent.thread_spawn.parent_thread_id') END=?",
                (actor["id"],)
            ).fetchall()
            for row in rows:
                if row[0] in visited:
                    continue
                child = self.actor(row[0])
                if child is None or not child["isSubagent"]:
                    continue
                if child["parent"] and child["parent"] != actor["id"]:
                    self.warnings.append("Conflicting saved ownership was left out of the family map.")
                    continue
                if len(actors) >= MAX_THREADS:
                    self.warnings.append("The family exceeds 200 saved threads; the map is bounded.")
                    return root, actors
                visited.add(child["id"])
                # The edge records ownership, never a timed handoff or child turn.
                child["parent"] = child["parent"] or actor["id"]
                actors.append(child)
        return root, actors

    def full_message(self, thread, turn, item):
        row = self.history.execute(
            "SELECT CASE WHEN length(CAST(item_json AS BLOB))<=? THEN item_json END AS item_json,"
            "length(CAST(item_json AS BLOB)) AS bytes FROM thread_items "
            "WHERE thread_id=? AND turn_id=? AND item_id=? AND item_type IN ('userMessage','steeringUserMessage','agentMessage')",
            (MAX_RECORD, thread, turn, item)
        ).fetchone()
        if row is None:
            raise ValueError("The saved message is no longer available in this projection.")
        if row["bytes"] > MAX_RECORD:
            raise ValueError("This saved record exceeds the 16 MiB read limit. The source was preserved.")
        value = decoded(row["item_json"])
        if not isinstance(value, dict):
            raise ValueError("The saved message could not be decoded.")
        text = message_text(value)
        return dict(text=clip(text, FULL_BYTES), truncated=len(text.encode("utf-8")) > FULL_BYTES)

    def messages_page(self, requested, before=None, limit=12, with_routing=False):
        """Keyset page of real messages across a whole family, without raw scans.

        Page selection uses metadata only. JSON is read only for selected items;
        unknown timestamps stay unknown and follow all timestamped messages.
        """
        self.warnings = []
        root, actors = self.family(requested)
        ids = [a['id'] for a in actors]
        limit = min(100, max(1, int(limit)))
        marks = ','.join('?' for _ in ids)
        order = "COALESCE(created_at_ms,started_at_ms,-1e30),thread_id,rollout_ordinal,turn_id,item_id"
        where = ""
        arguments = list(ids)
        if before is not None:
            if not isinstance(before, list) or len(before) != 5:
                raise ValueError('Invalid saved-message page cursor.')
            where = " AND (" + order + ") < (?,?,?,?,?)"
            arguments += [before[0] if before[0] is not None else -1e30] + before[1:]
        rows = self.history.execute(
            "SELECT thread_id,turn_id,item_id,rollout_ordinal,COALESCE(created_at_ms,started_at_ms) AS ms "
            "FROM thread_items WHERE thread_id IN (" + marks + ") "
            "AND item_type IN ('userMessage','steeringUserMessage','agentMessage') " + where +
            " ORDER BY COALESCE(created_at_ms,started_at_ms,-1e30) DESC,thread_id DESC,"
            "rollout_ordinal DESC,turn_id DESC,item_id DESC LIMIT ?", arguments + [limit + 1]
        ).fetchall()
        selected = rows[:limit]
        messages = []
        for row in selected:
            item = self.history.execute(
                "SELECT CASE WHEN length(CAST(item_json AS BLOB))<=? THEN item_json END AS payload,"
                "item_type FROM thread_items WHERE thread_id=? AND turn_id=? AND item_id=?",
                (MAX_RECORD, row['thread_id'], row['turn_id'], row['item_id'])
            ).fetchone()
            value = decoded(item['payload']) if item is not None else None
            if not isinstance(value, dict):
                self.warnings.append('Some saved messages are invalid or exceed the 16 MiB record limit; their source is preserved.')
                continue
            if item['item_type'] == 'steeringUserMessage' and value.get('status') != 'accepted':
                continue
            turn = self.history.execute(
                "SELECT final_agent_item_id,1+(SELECT COUNT(*) FROM thread_turns older "
                "WHERE older.thread_id=t.thread_id AND older.rollout_ordinal<t.rollout_ordinal) AS number "
                "FROM thread_turns t WHERE thread_id=? AND turn_id=?", (row['thread_id'], row['turn_id'])
            ).fetchone()
            message = dict(id=row['thread_id'] + ':' + row['turn_id'] + ':' + row['item_id'],
                           thread=row['thread_id'], turn=row['turn_id'], item=row['item_id'],
                           at=row['ms'] / 1000 if row['ms'] is not None else None,
                           role='assistant' if item['item_type'] == 'agentMessage' else 'user',
                           phase=value.get('phase'), preview=clip(message_text(value), PREVIEW_BYTES),
                           ordinal=row['rollout_ordinal'])
            messages.append(dict(message=message, turnNumber=turn['number'] if turn else None,
                                 finalForTurn=bool(turn and turn['final_agent_item_id'] == row['item_id'])))
        last = selected[-1] if selected else None
        cursor = [last['ms'],last['thread_id'],last['rollout_ordinal'],last['turn_id'],last['item_id']] if last else None
        captured = time.time()
        result = dict(root=root, actors=actors, messages=messages, next=json.dumps(cursor, separators=(',', ':')) if len(rows)>limit else None,
                      hasEarlier=len(rows)>limit, capturedAt=captured)
        if with_routing:
            dated = [row['ms']/1000 for row in selected if row['ms'] is not None]
            upper = before[0]/1000 if before and before[0] is not None else captured
            result['routing'] = self.routing_window(actors, min(dated), upper) if dated else []
        result['warnings'] = list(dict.fromkeys(self.warnings))
        return result

    def routing_window(self, actors, start, end):
        """Only explicit timed calls in the displayed history interval.

        Ownership metadata remains a separate fact. It never becomes a dated
        spawn, message delivery or guessed recipient turn.
        """
        links, budget, count = [], MAX_RAW, 0
        for actor in actors:
            rows = self.history.execute(
                "SELECT turn_id,rollout_byte_offset,rollout_end_byte_offset FROM thread_turns WHERE thread_id=? "
                "AND (started_at IS NULL OR CASE WHEN started_at>100000000000 THEN started_at/1000.0 ELSE started_at END<=?) "
                "AND (completed_at IS NULL OR CASE WHEN completed_at>100000000000 THEN completed_at/1000.0 ELSE completed_at+1 END>=?) "
                "ORDER BY rollout_ordinal DESC LIMIT 81", (actor['id'], end, start)
            ).fetchall()
            turns = []
            for row in rows[:80]:
                if count >= MAX_TURNS: break
                turn = dict(turn=row['turn_id'], byteStart=row['rollout_byte_offset'], byteEnd=row['rollout_end_byte_offset'])
                turns.append(turn); count += 1
                links.extend(self.indexed_handoffs(actor, turn, actors, start, end))
            if len(rows)>80 or count>=MAX_TURNS:
                self.warnings.append('Some routing evidence exceeds the turn read limit; unverified events were left out.')
            raw, budget = self.raw_handoffs(actor, turns, actors, start, end, budget)
            links.extend(raw)
        unique = {}
        for link in links:
            key=(link['sender'],link['senderTurn'],link['callID'],link['recipient'])
            unique.setdefault(key,link)
        links=sorted(unique.values(),key=lambda h:(h['at'],h['id']),reverse=True)
        if len(links)>200:
            self.warnings.append('Showing at most 200 recorded routing events for this history interval.')
        return links[:200]

    @staticmethod
    def resolve(target, sender, actors):
        if not isinstance(target, str):
            return None
        direct = [a for a in actors if a["id"] == target]
        if len(direct) == 1:
            return direct[0]["id"]
        if target.startswith("/"):
            path = os.path.normpath(target)
            matches = [a for a in actors if a["path"] == path]
        elif sender.get("path"):
            path = os.path.normpath(sender["path"] + "/" + target)
            matches = [a for a in actors if a["path"] == path]
        else:
            # Relative tool targets are canonical task names. Resolve only a
            # unique recorded direct-child path component in this sender's family.
            matches = [a for a in actors if a["parent"] == sender["id"] and a["path"]
                       and a["path"].rsplit("/", 1)[-1] == target]
        return matches[0]["id"] if len(matches) == 1 else None

    def raw_handoffs(self, actor, turns, actors, start, end, budget):
        path = Path(actor["rollout"] or "")
        if not path.is_file():
            if turns:
                self.warnings.append("A saved session file is unavailable; its raw handoff history could not be checked.")
            return [], budget
        result = []
        try:
            with path.open("rb") as stream:
                first = stream.readline(MAX_RECORD + 1)
                header = decoded(first)
                if not isinstance(header, dict) or header.get("type") != "session_meta" or header.get("payload", {}).get("id") != actor["id"]:
                    self.warnings.append("A saved session file failed the thread identity check.")
                    return [], budget
                size = os.fstat(stream.fileno()).st_size
                for turn in turns:
                    low, high = turn["byteStart"], turn["byteEnd"] or size
                    if low is None or high < low:
                        continue
                    if high - low > budget:
                        self.warnings.append("Some handoff records exceed the 32 MiB scan budget; no links were guessed.")
                        continue
                    budget -= high - low
                    stream.seek(low)
                    calls = {}
                    context_turn = None
                    while stream.tell() < high:
                        offset = stream.tell()
                        line = stream.readline(min(MAX_RECORD + 1, high - offset))
                        if len(line) > MAX_RECORD or not line.endswith(b"\n"):
                            self.warnings.append("An incomplete or oversized saved session record was skipped.")
                            break
                        record = decoded(line)
                        if not isinstance(record, dict):
                            continue
                        payload = record.get("payload") or {}
                        if not isinstance(payload, dict):
                            continue
                        if record.get("type") == "turn_context":
                            context_turn = payload.get("turn_id")
                        if record.get("type") == "event_msg" and payload.get("type") == "task_started":
                            context_turn = payload.get("turn_id")
                        if context_turn != turn["turn"]:
                            continue
                        kind = payload.get("type")
                        if kind == "function_call":
                            namespace, name = payload.get("namespace"), payload.get("name", "")
                            if not isinstance(name, str):
                                continue
                            if name.startswith("collaboration."):
                                namespace, name = "collaboration", name.split(".", 1)[1]
                            if namespace != "collaboration" or name not in ("spawn_agent", "followup_task", "send_message", "resume_agent", "send_input"):
                                continue
                            at = stamp(record.get("timestamp"))
                            args = decoded(payload.get("arguments"))
                            call_id = payload.get("call_id")
                            if at is None or not start <= at <= end or not isinstance(args, dict) or not isinstance(call_id, str) or not call_id:
                                continue
                            calls[call_id] = dict(name=name, at=at, args=args, offset=offset)
                        elif kind == "function_call_output" and payload.get("call_id") in calls:
                            call = calls.pop(payload["call_id"])
                            output = payload.get("output")
                            obj = decoded(output) if isinstance(output, str) else output
                            if isinstance(obj, dict) and (obj.get("isError") or obj.get("error")):
                                continue
                            if isinstance(obj, dict) and obj.get("status") in ("failed", "errored", "error", "rejected", "not_found"):
                                continue
                            if isinstance(output, str) and output.lstrip().lower().startswith(("error", "tool error")):
                                continue
                            target = call["args"].get("target") or call["args"].get("agent_id")
                            if call["name"] == "spawn_agent":
                                target = obj.get("agent_id") if isinstance(obj, dict) else None
                            recipient = self.resolve(target, actor, actors)
                            if recipient is None or recipient == actor["id"]:
                                continue
                            if call['name'] == 'spawn_agent':
                                created = next(a for a in actors if a['id'] == recipient)
                                if not created['isSubagent'] or created['parent'] != actor['id']:
                                    self.warnings.append('A spawn call conflicts with saved ownership; no creation event was guessed.')
                                    continue
                            result.append(dict(
                                id=actor["id"] + ":" + payload["call_id"], sender=actor["id"],
                                senderTurn=turn["turn"], recipient=recipient, at=call["at"],
                                kind=call["name"], callID=payload["call_id"],
                                preview=prompt_preview(call["args"].get("message") or call["args"].get("prompt")),
                                source=str(path), byteOffset=call["offset"],
                                evidence="Recorded collaboration call and matching tool output; recipient resolved from saved thread metadata.",
                            ))
        except (OSError, ValueError) as error:
            self.warnings.append("Some saved handoff records could not be read: " + str(error))
        return result, budget

    def indexed_handoffs(self, actor, turn, actors, start, end):
        links = []
        rows = self.history.execute(
            "SELECT item_id,created_at_ms,started_at_ms,"
            "CASE WHEN length(CAST(item_json AS BLOB))<=? THEN item_json END AS item_json,"
            "length(CAST(item_json AS BLOB)) AS bytes "
            "FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type='collabAgentToolCall' "
            "ORDER BY rollout_ordinal DESC LIMIT 401", (MAX_RECORD, actor["id"], turn["turn"])
        ).fetchall()
        for row in rows[:400]:
            if row["bytes"] > MAX_RECORD:
                continue
            item = decoded(row["item_json"])
            if not isinstance(item, dict) or item.get("status") != "completed" or item.get("senderThreadId") != actor["id"]:
                continue
            tool = item.get("tool")
            names = {"spawnAgent": "spawn_agent", "sendInput": "send_input", "resumeAgent": "resume_agent"}
            if tool not in names:
                continue
            raw_at = row["created_at_ms"] if row["created_at_ms"] is not None else row["started_at_ms"]
            at = float(raw_at) / 1000 if raw_at is not None else None
            if at is None or not start <= at <= end:
                continue
            for recipient in item.get("receiverThreadIds") or []:
                if not isinstance(recipient, str) or recipient == actor["id"] or recipient not in {a["id"] for a in actors}:
                    continue
                if tool == 'spawnAgent':
                    created = next(a for a in actors if a['id'] == recipient)
                    if not created['isSubagent'] or created['parent'] != actor['id']:
                        self.warnings.append('A spawn item conflicts with saved ownership; no creation event was guessed.')
                        continue
                links.append(dict(id=actor["id"] + ":" + row["item_id"] + ":" + recipient,
                                  sender=actor["id"], senderTurn=turn["turn"], recipient=recipient,
                                  at=at, kind=names[tool], callID=row["item_id"],
                                  preview=prompt_preview(item.get("prompt")),
                                  source=str(self.home / "thread_history_1.sqlite") + " · item " + row["item_id"],
                                  byteOffset=None, evidence="Saved completed collaboration item with explicit sender and recipient thread IDs."))
        if len(rows) == 401:
            self.warnings.append("Some recorded collaboration items exceed the per-turn map limit.")
        return links

    def load(self, requested, start, end):
        root, actors = self.family(requested)
        all_turns, messages, handoffs = [], [], []
        budget = MAX_RAW
        active = {root["id"]}
        for actor in actors:
            rows = self.history.execute(
                "SELECT turn_id,status,started_at,completed_at,duration_ms,rollout_ordinal,"
                "rollout_byte_offset,rollout_end_byte_offset FROM thread_turns WHERE thread_id=? "
                "AND (started_at IS NULL OR CASE WHEN started_at>100000000000 THEN started_at/1000.0 ELSE started_at END<=?) "
                "AND (completed_at IS NULL OR CASE WHEN completed_at>100000000000 THEN completed_at/1000.0 ELSE completed_at END>=?) "
                "ORDER BY rollout_ordinal DESC LIMIT 81", (actor["id"], end, start)
            ).fetchall()
            turns = []
            for row in rows:
                began, finished = seconds(row["started_at"]), seconds(row["completed_at"])
                if began is not None and began > end or finished is not None and finished < start:
                    continue
                if len(all_turns) >= MAX_TURNS or len(turns) >= 80:
                    self.warnings.append("The selected window has more turns than the map limit; choose a shorter window.")
                    break
                value = dict(id=actor["id"] + ":" + row["turn_id"], thread=actor["id"], turn=row["turn_id"],
                             status=row["status"], start=began, end=finished,
                             byteStart=row["rollout_byte_offset"], byteEnd=row["rollout_end_byte_offset"],
                             ordinal=row["rollout_ordinal"],
                             number=1 + self.history.execute(
                                 "SELECT COUNT(*) FROM thread_turns WHERE thread_id=? AND rollout_ordinal<?",
                                 (actor["id"], row["rollout_ordinal"])).fetchone()[0])
                turns.append(value); all_turns.append(value); active.add(actor["id"])
                handoffs.extend(self.indexed_handoffs(actor, value, actors, start, end))
                remaining = MAX_MESSAGES - len(messages)
                if remaining <= 0:
                    continue
                # SQLite extracts a bounded preview, without transferring complete
                # tool output or reasoning payloads into the map process.
                items = self.history.execute(
                    "SELECT item_id,item_type,created_at_ms,started_at_ms,completed_at_ms,"
                    "CASE WHEN length(CAST(item_json AS BLOB))<=? THEN CASE WHEN json_valid(item_json) "
                    "THEN json_extract(item_json,'$.phase') END END AS phase,rollout_ordinal,"
                    "CASE WHEN length(CAST(item_json AS BLOB))<=? THEN CASE WHEN json_valid(item_json) THEN "
                    "substr(CASE WHEN item_type='agentMessage' THEN COALESCE(json_extract(item_json,'$.text'),'') "
                    "ELSE COALESCE((SELECT group_concat(json_extract(value,'$.text'),char(10)) "
                    "FROM json_each(item_json,'$.content') WHERE json_extract(value,'$.type')='text'),'[Attachment]') END,1,2048) END END AS preview "
                    "FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type IN ('userMessage','agentMessage') "
                    "AND (COALESCE(created_at_ms,started_at_ms) IS NULL "
                    "OR COALESCE(created_at_ms,started_at_ms) BETWEEN ? AND ?) "
                    "ORDER BY rollout_ordinal DESC LIMIT ?",
                    (MAX_RECORD, MAX_RECORD, actor["id"], row["turn_id"], start * 1000, end * 1000, min(remaining, 401))
                ).fetchall()
                if len(items) == 401:
                    self.warnings.append("A turn has more than 400 messages in this window; its message map is bounded.")
                    items = items[:400]
                for item in items:
                    if item["preview"] is None:
                        self.warnings.append("Some saved message records are invalid or exceed the 16 MiB source limit; they were left out.")
                        continue
                    at = item["created_at_ms"] if item["created_at_ms"] is not None else item["started_at_ms"]
                    messages.append(dict(id=actor["id"] + ":" + row["turn_id"] + ":" + item["item_id"],
                                         thread=actor["id"], turn=row["turn_id"], item=item["item_id"],
                                         at=float(at) / 1000 if at is not None else None,
                                         role="user" if item["item_type"] == "userMessage" else "assistant",
                                         phase=item["phase"], preview=clip(item["preview"], PREVIEW_BYTES),
                                         ordinal=item["rollout_ordinal"]))
            links, budget = self.raw_handoffs(actor, turns, actors, start, end, budget)
            handoffs.extend(links)
        # A native item and its raw function call can describe the same handoff.
        unique = {}
        for link in handoffs:
            key = (link["sender"], link["senderTurn"], link["callID"], link["recipient"])
            unique.setdefault(key, link)
        handoffs = list(unique.values())
        if len(messages) >= MAX_MESSAGES:
            self.warnings.append("Showing at most 2000 saved messages; choose a shorter window for more detail.")
        for link in handoffs:
            active.add(link["recipient"]); active.add(link["sender"])
        return dict(root=root, requested=requested, actors=[a for a in actors if a["id"] in active],
                    familyCount=len(actors), turns=all_turns, messages=messages,
                    handoffs=handoffs, start=start, end=end, capturedAt=time.time(),
                    warnings=list(dict.fromkeys(self.warnings)),
                    source="Local Codex saved history (read-only)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME") or str(Path.home() / ".codex"))
    parser.add_argument("--thread", required=True)
    parser.add_argument("--since", type=float)
    parser.add_argument("--until", type=float)
    parser.add_argument("--message-turn")
    parser.add_argument("--message-item")
    parser.add_argument("--messages-page", action="store_true")
    parser.add_argument("--with-routing", action="store_true")
    parser.add_argument("--before", help="Saved-message keyset cursor as JSON")
    parser.add_argument("--page-size", type=int, default=12)
    args = parser.parse_args()
    reader = None
    try:
        reader = SavedConversations(args.codex_home)
        if args.messages_page:
            value = reader.messages_page(args.thread, json.loads(args.before) if args.before else None, args.page_size, args.with_routing)
        elif args.message_turn and args.message_item:
            value = reader.full_message(args.thread, args.message_turn, args.message_item)
        else:
            end = args.until or time.time()
            value = reader.load(args.thread, args.since if args.since is not None else end - 7200, end)
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    except (OSError, sqlite3.Error, ValueError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    finally:
        if reader:
            reader.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
