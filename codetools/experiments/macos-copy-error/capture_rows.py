import subprocess,json,time,sys
from pathlib import Path
# Archived laptop calibration: update helper path, PID and coordinates before use.
# The orchestrator must obtain a hands-off window and restore clipboard/focus.
if "--allow-ui-control" not in sys.argv:
 raise SystemExit("WIP UI automation: read README.md, then explicitly pass --allow-ui-control")
sys.argv.remove("--allow-ui-control")
base=Path('/tmp/minerva-mac-capture'); helper=str(base/'mac_capture')
def run(*args):return subprocess.check_output([helper,*map(str,args)],text=True).strip()
rows=json.loads(sys.argv[1]); entries=[]
try:
 for index,y in enumerate(rows):
  if run('front')!='7136':raise RuntimeError('Godot lost focus; stopped capture')
  before=run('clipboard-count')
  run('click',550,y,'right'); time.sleep(.25)
  windows=json.loads(subprocess.check_output(['python3',str(base/'windows.py')],text=True))
  menus=[w for w in windows if w['pid']==7136 and not w['title'] and 45<=w['bounds']['Height']<=90]
  if len(menus)!=1:raise RuntimeError('Copy Error menu could not be identified')
  b=menus[0]['bounds'];run('click',b['X']+70,b['Y']+20,'left');time.sleep(.15)
  if run('clipboard-count')==before:raise RuntimeError('Copy Error did not update clipboard')
  path=base/f'{sys.argv[2]}-{index:02}.txt';run('clipboard-read',path)
  text=path.read_text()
  if not text.startswith(('W ','E ','WARNING','ERROR','SCRIPT ERROR')):raise RuntimeError('Clipboard did not contain a diagnostic')
  entries.append(text)
  print(text.splitlines()[0],flush=True)
finally:
 (base/f'{sys.argv[2]}.json').write_text(json.dumps(entries,indent=2))
