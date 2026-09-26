import json, os, queue, subprocess, threading, time
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
import argparse
parser = argparse.ArgumentParser(description="本机视差验证：开始前须通过主应用停止播放，原素材和用户设置不会修改。")
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--materials', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
options = parser.parse_args()
MATERIALS = options.materials.resolve()
OUT=options.output.resolve(); OUT.mkdir(parents=True,exist_ok=True)
ROOT=options.app.resolve()/'Contents/Resources/SceneRuntime/Contents'
env=os.environ.copy();env.pop('SCENERENDERER_DIAGNOSTICS_DIR',None)
env['VK_ICD_FILENAMES']=env['VK_DRIVER_FILES']=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json')
env['DYLD_FALLBACK_LIBRARY_PATH']=str(ROOT/'Frameworks');env['FONTCONFIG_FILE']=str(ROOT/'Resources/fonts/fonts.conf')
runtime=OUT/'runtime.json';runtime.write_text(json.dumps({'speed':1.0}))
def capture(ident,key,enabled,x):
 name=f'{ident}-{"on" if enabled else "off"}-{x}'
 props={key:enabled,'camerashake':False,'newproperty':False,'newproperty1':False,'clotheffect':False,'skyeffect':False,'clock':False,'audio':False,'fog':False,'firefly':False,'bokeh':False}
 prop=OUT/(name+'.json');prop.write_text(json.dumps(props));png=OUT/(name+'.png')
 args=[str(ROOT/'Resources/Renderers/SceneWallpaper'),'--display-id','3','--fps','30','--resolution','960x600','--muted','--no-spectrum','--no-mouse','--deferred-show','--control-stdin','--run-seconds','25','--mouse-position',f'{x},0.5','--runtime',str(runtime),'--cache-path',str(OUT/'cache'), '--user-properties',str(prop),str(ROOT/'Resources/assets'),str(MATERIALS/ident/'scene.pkg')]
 q=queue.Queue();p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
 logs=[]
 def reader():
  for line in p.stdout: logs.append(line);q.put(line)
 t=threading.Thread(target=reader,daemon=True);t.start()
 def wait_event(event,limit=20):
  deadline=time.monotonic()+limit
  while time.monotonic()<deadline:
   try: line=q.get(timeout=.3)
   except queue.Empty:
    if p.poll() is not None: raise RuntimeError('renderer exited '+''.join(logs[-5:]))
    continue
   try: val=json.loads(line)
   except ValueError: continue
   if val.get('event')==event:return val
  raise RuntimeError('timeout '+event)
 try:
  wait_event('first-frame-presented');time.sleep(1.5)
  p.stdin.write(json.dumps({'cmd':'snapshot','path':str(png),'token':name})+'\n');p.stdin.flush()
  result=wait_event('snapshot-done');assert result.get('ok'),result
  subprocess.run(['/usr/bin/sips','-s','format','png',str(png),'--out',str(png)],check=True,stdout=subprocess.DEVNULL)
  print(name,Image.open(png).size,flush=True)
 finally:
  p.stdin.close()
  try:p.wait(timeout=6)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
  (OUT/(name+'.log')).write_text(''.join(logs))
 return png
results=[]
for ident,key in [('1000000002','lensparallax'),('1000000006','parallax')]:
 for enabled in [False,True]:
  a=capture(ident,key,enabled,0.1);b=capture(ident,key,enabled,0.9)
  diff=ImageChops.difference(Image.open(a).convert('RGB'),Image.open(b).convert('RGB'))
  stats=ImageStat.Stat(diff);results.append({'scene':ident,'parallax':enabled,'mean_abs_difference':sum(stats.mean)/3,'bbox':diff.getbbox()})
  print(results[-1],flush=True)
(OUT/'results.json').write_text(json.dumps(results,indent=2))
