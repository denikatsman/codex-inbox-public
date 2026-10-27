import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('repair',Path(__file__).parent/'scripts/repair-legacy-titles.py')
repair=importlib.util.module_from_spec(spec); spec.loader.exec_module(repair)


class HistoricalRepairTests(unittest.TestCase):
    def test_only_proven_title_annotations_interrupt_and_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            db=sqlite3.connect(Path(directory)/'fixture.sqlite')
            db.executescript('CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE notices(id TEXT PRIMARY KEY,attention INTEGER,done_reason TEXT); INSERT INTO notices VALUES("n",1,"manual"); CREATE TABLE activity(seq INTEGER PRIMARY KEY,dedup TEXT UNIQUE,notice_id TEXT,task_key TEXT,task_json TEXT,project_key TEXT,kind TEXT,detail TEXT,time_json TEXT,source_at REAL);')
            identity=json.dumps(dict(thread='t',host='local',title='Wrong'))
            for seq in (1,2,3): db.execute('INSERT INTO activity VALUES (?,?,?,?,?,?,?,?,?,?)',(seq,None,'n','t',identity,'','legacy_import','Original text','{}',1))
            db.commit(); before=repair.logical_digest(db)
            assessment={'legacyTitles':[dict(seq=i,noticeID='n',oldTaskJSON=identity,newTitle='Correct',legacyNoticeSHA256='fixture') for i in (1,2)]}
            def interrupt(seq): raise KeyboardInterrupt('Injected interruption')
            with self.assertRaises(KeyboardInterrupt): repair.apply_selected(db,assessment,'fixture',interrupt)
            self.assertEqual(repair.logical_digest(db),before)
            self.assertEqual(repair.apply_selected(db,assessment,'fixture'),[1,2])
            self.assertEqual(repair.apply_selected(db,assessment,'fixture'),[])
            self.assertEqual(tuple(db.execute('SELECT attention,done_reason FROM notices').fetchone()),(1,'manual'))
            self.assertEqual(db.execute("SELECT count(*) FROM activity WHERE seq<=3 AND task_json=?",(identity,)).fetchone()[0],3)
            ambiguous={'legacyTitles':[dict(assessment['legacyTitles'][0],seq=3,oldTaskJSON='changed')]}
            with self.assertRaises(ValueError): repair.apply_selected(db,ambiguous,'fixture')
            self.assertEqual(db.execute('SELECT count(*) FROM activity').fetchone()[0],5)
            db.close()

if __name__ == '__main__': unittest.main()
