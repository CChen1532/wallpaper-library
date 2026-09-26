import json,os,subprocess,threading,queue,time,sys
from pathlib import Path
from PIL import Image,ImageChops,ImageStat
import argparse
parser = argparse.ArgumentParser(description="本机视差验证：开始前须通过主应用停止播放，原素材和用户设置不会修改。")
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--materials', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
options = parser.parse_args()
MATERIALS = options.materials.resolve()
OUT=options.output.resolve();ROOT=options.app.resolve()/'Contents/Resources/SceneRuntime/Contents'
env=os.environ.copy();env.pop('SCENERENDERER_DIAGNOSTICS_DIR',None);env['VK_ICD_FILENAMES']=env['VK_DRIVER_FILES']=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json');env['DYLD_FALLBACK_LIBRARY_PATH']=str(ROOT/'Frameworks');env['FONTCONFIG_FILE']=str(ROOT/'Resources/fonts/fonts.conf')
args=[str(ROOT/'Resources/Renderers/SceneWallpaper'),'--display-id','3','--fps','30','--resolution','960x600','--muted','--no-spectrum','--no-mouse-buttons','--input-hz','60','--deferred-show','--control-stdin','--run-seconds','150','--cache-path',str(OUT/'cache'),'--user-properties',str(OUT/'1000000002-on-0.1.json'),str(ROOT/'Resources/assets'),str(MATERIALS/'1000000002/scene.pkg')]
p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);q=queue.Queue();logs=[]
def read():
 for line in p.stdout:
  logs.append(line)
  try:q.put(json.loads(line))
  except ValueError:pass
threading.Thread(target=read,daemon=True).start()
def wait(event):
 end=time.monotonic()+20
 while time.monotonic()<end:
  try:v=q.get(timeout=.3)
  except queue.Empty:continue
  if v.get('event')==event:return v
 raise RuntimeError(event+' timeout')
def send(obj):p.stdin.write(json.dumps(obj)+'\n');p.stdin.flush()
try:
 wait('first-frame-presented');send({'cmd':'activate'});wait('activated');print('READY live mouse enabled',flush=True)
 for line in sys.stdin:
  label=line.strip()
  if label=='quit':break
  if label not in ['live-left','live-right','live-left-again']:continue
  time.sleep(.6);png=OUT/(label+'.png');send({'cmd':'snapshot','path':str(png),'token':label});assert wait('snapshot-done').get('ok')
  subprocess.run(['/usr/bin/sips','-s','format','png',str(png),'--out',str(png)],stdout=subprocess.DEVNULL,check=True);print('CAPTURED '+label,flush=True)
finally:
 p.stdin.close()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
 (OUT/'live.log').write_text(''.join(logs));print('CLEANED',flush=True)
