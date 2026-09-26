import os,json,time,queue,threading,subprocess,collections
from pathlib import Path
from PIL import Image,ImageStat,ImageChops
import argparse
parser=argparse.ArgumentParser(description="串行隐藏渲染场景清单；运行前须停止主应用播放。")
parser.add_argument('--app',type=Path,required=True)
parser.add_argument('--inventory',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
options=parser.parse_args()
OUT=options.output.resolve();OUT.mkdir(parents=True,exist_ok=True)
ROOT=options.app.resolve()/'Contents/Resources/SceneRuntime/Contents'
env=os.environ.copy();env.pop('SCENERENDERER_DIAGNOSTICS_DIR',None);env['VK_ICD_FILENAMES']=env['VK_DRIVER_FILES']=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json');env['DYLD_FALLBACK_LIBRARY_PATH']=str(ROOT/'Frameworks');env['FONTCONFIG_FILE']=str(ROOT/'Resources/fonts/fonts.conf')
items=json.loads(options.inventory.read_text());results=[]
for item in sorted(items,key=lambda x:x['bytes']):
 ident=item['id'];folder=OUT/ident;folder.mkdir(exist_ok=True);logs=collections.deque(maxlen=1500);q=queue.Queue();start=time.monotonic()
 args=[str(ROOT/'Resources/Renderers/SceneWallpaper'),'--display-id','3','--fps','15','--resolution','640x400','--muted','--no-spectrum','--no-mouse','--deferred-show','--control-stdin','--run-seconds','45','--cache-path',str(OUT/'cache'),str(ROOT/'Resources/assets'),item['package']]
 p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
 def reader(proc=p,log=logs,events=q):
  for line in proc.stdout:
   log.append(line)
   if line.startswith('{'):
    try:events.put(json.loads(line))
    except ValueError:pass
 threading.Thread(target=reader,daemon=True).start()
 def wait(event,timeout=30):
  deadline=time.monotonic()+timeout
  while time.monotonic()<deadline:
   try:v=q.get(timeout=.3)
   except queue.Empty:
    if p.poll() is not None:raise RuntimeError('renderer exited '+str(p.returncode))
    continue
   if v.get('event')=='renderer-error':raise RuntimeError('renderer-error')
   if v.get('event')==event:return v
  raise RuntimeError('timeout '+event)
 row=dict(item)
 try:
  row['firstFrame']=wait('first-frame-presented');frames=[]
  for i in range(2):
   time.sleep(1.5 if i==0 else 1)
   dest=folder/f'frame{i}.png';p.stdin.write(json.dumps({'cmd':'snapshot','path':str(dest),'token':str(i)})+'\n');p.stdin.flush();assert wait('snapshot-done',8).get('ok')
   subprocess.run(['/usr/bin/sips','-s','format','png',str(dest),'--out',str(dest)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   im=Image.open(dest).convert('RGB');frames.append(im)
  stats=ImageStat.Stat(frames[-1].convert('L'));row.update(mean=stats.mean[0],stddev=stats.stddev[0],frameDifference=sum(ImageStat.Stat(ImageChops.difference(*frames)).mean)/3,status='rendered' if stats.stddev[0]>.5 else 'flat-frame-review')
 except Exception as e:row.update(status='failed',error=str(e))
 finally:
  try:p.stdin.close()
  except Exception:pass
  try:p.wait(timeout=6)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
  row['exitCode']=p.returncode;row['seconds']=round(time.monotonic()-start,2)
  errors=[x.strip()[:500] for x in logs if any(y in x.lower() for y in ['error','failed','unsupported','exception'])];row['diagnostics']=errors[:25]
  (folder/'renderer.log').write_text(''.join(logs));results.append(row);(OUT/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
  print(json.dumps(row,ensure_ascii=False),flush=True)
print('DONE',len(results),collections.Counter(x['status'] for x in results),flush=True)

if any(x["status"] != "rendered" or x["exitCode"] != 0 for x in results):
 raise SystemExit(1)
