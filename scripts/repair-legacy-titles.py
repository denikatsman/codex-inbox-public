#!/usr/bin/env python3
"""CN-020 only: append proven legacy-title corrections, preserving original rows.

Consumes the exact assessed activity IDs and legacy-file hashes. No field overlays,
source imports, attention changes, or generalized migration mechanism.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid


def digest(value):
    return hashlib.sha256(value).hexdigest()


def logical_digest(connection):
    result = hashlib.sha256()
    for (name,) in connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
        # Names originate from the database schema, not SQL values.
        escaped = name.replace('"', '""')
        result.update(name.encode())
        for row in connection.execute('SELECT * FROM "' + escaped + '" ORDER BY rowid'):
            result.update(json.dumps(tuple(row), ensure_ascii=False, separators=(',', ':')).encode())
    return result.hexdigest()


def validate_sources(directory, assessment):
    originals = {}
    for name, expected in assessment['sources'].items():
        if name not in ('inbox-v1-preserved.json', 'inbox.json'):
            raise ValueError('Unexpected legacy source')
        data = (directory/name).read_bytes()
        if digest(data) != expected: raise ValueError('Legacy source changed; reassess before writing')
        for notice in json.loads(data)['notices']: originals[notice['id']] = notice
    for candidate in assessment['legacyTitles']:
        original = originals[candidate['noticeID']]
        if digest(json.dumps(original, sort_keys=True).encode()) != candidate['legacyNoticeSHA256'] or original['title'] != candidate['newTitle']:
            raise ValueError('The proposed correction does not match the retained original')


def apply_selected(connection, assessment, evidence, interrupt=None):
    """One transaction; interruption and repetition cannot duplicate corrections."""
    applied = []
    connection.row_factory = sqlite3.Row
    connection.execute('BEGIN IMMEDIATE')
    try:
        for candidate in assessment['legacyTitles']:
            seq = candidate['seq']; key = f'repair:CN-020:activity:{seq}'
            if connection.execute('SELECT 1 FROM meta WHERE key=?',(key,)).fetchone(): continue
            old = connection.execute('SELECT * FROM activity WHERE seq=?',(seq,)).fetchone()
            if old is None or old['kind'] != 'legacy_import' or old['notice_id'] != candidate['noticeID'] or old['task_json'] != candidate['oldTaskJSON']:
                raise ValueError(f'Activity {seq} changed or does not match its assessed legacy record')
            task = json.loads(old['task_json']); task['title'] = candidate['newTitle']
            now = time.time()
            stamp = dict(at=now,deviceAt=now,elapsed=time.monotonic(),session='CN-020-repair',quality='Device clock; targeted historical annotation')
            detail = f"Corrected the captured legacy title to {candidate['newTitle']!r}. Original activity #{seq} remains unchanged. Retained legacy notice SHA-256: {candidate['legacyNoticeSHA256']}. Evidence: {evidence}"
            cursor = connection.execute('INSERT INTO activity(dedup,notice_id,task_key,task_json,project_key,kind,detail,time_json,source_at) VALUES (?,?,?,?,?,?,?,?,?)',
                (key,old['notice_id'],old['task_key'],json.dumps(task),old['project_key'],'legacy_title_corrected',detail,json.dumps(stamp),old['source_at']))
            connection.execute('INSERT INTO meta(key,value) VALUES (?,?)',(key,json.dumps(dict(originalActivity=seq,correctionActivity=cursor.lastrowid,evidence=evidence))))
            applied.append(seq)
            if interrupt: interrupt(seq)
        connection.commit()
    except BaseException:
        connection.rollback(); raise
    return applied


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('assessment',type=Path)
    parser.add_argument('--directory',type=Path,default=Path.home()/'Library/Application Support/Codex Inbox')
    parser.add_argument('--apply',action='store_true')
    args = parser.parse_args()
    assessment = json.loads(args.assessment.read_text())
    validate_sources(args.directory,assessment)
    # Share the app's ownership lock. Never terminate a running Inbox.
    descriptor = os.open(args.directory/'instance.lock',os.O_RDWR|os.O_NOFOLLOW)
    with os.fdopen(descriptor,'r+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        path=args.directory/'activity.sqlite'
        original=sqlite3.connect(f'file:{path}?mode=ro',uri=True)
        original.execute('BEGIN')
        if not args.apply:
            print(json.dumps({'provenLegacyTitleCandidates':len(assessment['legacyTitles']),'applied':False})); return
        stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        recovery=args.directory/'Recovery'/('CN-020-'+stamp+'-'+uuid.uuid4().hex[:8])
        recovery.mkdir(parents=True,mode=0o700)
        backup=recovery/'activity-before.sqlite'
        saved=sqlite3.connect(backup)
        original.backup(saved)
        before=logical_digest(original)
        if logical_digest(saved)!=before or saved.execute('PRAGMA integrity_check').fetchone()[0]!='ok':
            raise ValueError('Consistent backup verification failed')
        saved.close(); original.close(); backup.chmod(0o600)
        (recovery/'assessment.json').write_text(json.dumps(assessment,indent=2)); (recovery/'assessment.json').chmod(0o600)
        current=sqlite3.connect(path)
        if logical_digest(current)!=before: raise ValueError('Database changed after backup; preserved backup, no repairs applied')
        applied=apply_selected(current,assessment,str(recovery/'assessment.json'))
        result=dict(bug='CN-020',backup=str(backup),backupSHA256=digest(backup.read_bytes()),beforeLogicalSHA256=before,appliedActivitySequences=applied,originalRowsPreserved=True)
        (recovery/'result.json').write_text(json.dumps(result,indent=2)); (recovery/'result.json').chmod(0o600)
        current.close(); print(json.dumps(result,indent=2))


if __name__ == '__main__': main()
