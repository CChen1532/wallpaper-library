import json,os,subprocess,threading,queue,time
from pathlib import Path
from PIL import Image,ImageChops,ImageStat
import argparse
parser=argparse.ArgumentParser(description="测试场景C音频条合成频谱对照，不采集系统声音；运行前须停止主应用播放。")
parser.add_argument('--app',type=Path,required=True)
parser.add_argument('--package',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
options=parser.parse_args()
OUT=options.output.resolve();OUT.mkdir(parents=True,exist_ok=True)
ROOT=options.app.resolve()/'Contents/Resources/SceneRuntime/Contents';env=os.environ.copy();env.pop('SCENERENDERER_DIAGNOSTICS_DIR',None);env['VK_ICD_FILENAMES']=env['VK_DRIVER_FILES']=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json');env['DYLD_FALLBACK_LIBRARY_PATH']=str(ROOT/'Frameworks');env['FONTCONFIG_FILE']=str(ROOT/'Resources/fonts/fonts.conf')
(OUT/'runtime.json').write_text(json.dumps({'speed':1e-8}));results=[]
for enabled in [False,True]:
 (OUT/'properties.json').write_text(json.dumps({'audiobar':enabled,'clock':False,'parallax':False}))
 args=[str(ROOT/'Resources/Renderers/SceneWallpaper'),'--display-id','3','--fps','30','--resolution','960x600','--muted','--external-spectrum','--no-mouse','--deferred-show','--control-stdin','--run-seconds','35','--runtime',str(OUT/'runtime.json'),'--user-properties',str(OUT/'properties.json'),'--cache-path',str(OUT/'cache'),str(ROOT/'Resources/assets'),str(options.package.resolve())]
 p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);q=queue.Queue();logs=[]
 def reader(proc=p,events=q,log=logs):
  for line in proc.stdout:
   log.append(line)
   try:events.put(json.loads(line))
   except ValueError:pass
 threading.Thread(target=reader,daemon=True).start()
 def wait(name):
  end=time.monotonic()+20
  while time.monotonic()<end:
   try:v=q.get(timeout=.2)
   except queue.Empty:continue
   if v.get('event')==name:return v
  raise RuntimeError(name+' timeout')
 def send(obj):p.stdin.write(json.dumps(obj)+'\n');p.stdin.flush()
 try:
  wait('first-frame-presented');frames=[]
  for amplitude in [0,1]:
   for _ in range(45):send({'cmd':'audioSpectrum','data':[amplitude]*128});time.sleep(.025)
   dest=OUT/f'bar-{enabled}-spectrum-{amplitude}.png';send({'cmd':'snapshot','path':str(dest),'token':str(amplitude)})
   # Keep external spectrum alive while snapshot is pending (250ms stale guard).
   for _ in range(6):send({'cmd':'audioSpectrum','data':[amplitude]*128});time.sleep(.02)
   assert wait('snapshot-done').get('ok');subprocess.run(['/usr/bin/sips','-s','format','png',str(dest),'--out',str(dest)],stdout=subprocess.DEVNULL,check=True);frames.append(Image.open(dest).convert('RGB'))
  d=ImageChops.difference(*frames);r={'audiobar':enabled,'mean_abs_difference':sum(ImageStat.Stat(d).mean)/3,'bbox':d.getbbox()};results.append(r);print(r,flush=True)
 finally:
  p.stdin.close()
  try:p.wait(timeout=6)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
  (OUT/f'bar-{enabled}.log').write_text(''.join(logs))
(OUT/'results.json').write_text(json.dumps(results,indent=2))

assert results[0]["mean_abs_difference"] < 0.01, "关闭音频条的阴性对照出现变化"
assert results[1]["mean_abs_difference"] > 0.05, "开启音频条后无可测响应"
