"""Synthetic collector -> native reader integration source; never reads user data."""
import json
from pathlib import Path
import sys
from collector import Observer
from test_repairs import SourceFixture

root = Path(sys.argv[1]); root.mkdir()
source = SourceFixture(root); source.task(high=3000)
for i in range(1,130): source.item(i, updated=2000)
source.item(2010, item={'id':'final','type':'agentMessage','text':'Final from snapshot','phase':'final_answer'})
source.turn(2200)
observer = Observer(root,999999)
observer.read_history()  # item stream and first bounded window
observer.read_history()  # terminal turn behind the item page
observer.item('task','turn',{'id':'steering','type':'steeringUserMessage','status':'accepted','serverUserMessageId':'1','input':[{'text':'reply'}]})
observer.states[('remote','request-task')] = {'requests':[{'id':1,'method':'item/commandExecution/requestApproval','params':{}}]}
for _ in range(100): observer.inspect_state('remote','request-task')
# Final sentinel cannot pass the native storage queue before the requests commit.
from collector import emit
emit('cursor',thread='flow-check',ordinal=3000)
source.close()
sys.stdin.buffer.read()
