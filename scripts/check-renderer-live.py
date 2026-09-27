#!/usr/bin/env python3
# Local acceptance probe: never activates its renderer windows; isolates script storage.
import os,json,time,queue,threading,subprocess
from pathlib import Path
from PIL import Image,ImageChops,ImageStat
import argparse
parser=argparse.ArgumentParser(description="Bounded hidden-window renderer checks. Stop desktop playback first. Requires Pillow.")
parser.add_argument('--runtime',type=Path,required=True,help='Packaged SceneRuntime directory')
parser.add_argument('--scene',type=Path,required=True,help='Existing scene.pkg for live playback checks')
parser.add_argument('--output',type=Path,required=True,help='New evidence directory; existing output is rejected')
parser.add_argument('--display-id',type=int,required=True)
args=parser.parse_args()
if args.output.exists(): parser.error('Use a new output directory to preserve prior evidence')
ROOT=args.runtime.resolve()/'Contents'
PKG=args.scene.resolve()
if not (ROOT/'Resources/Renderers/SceneWallpaper').is_file() or not PKG.is_file(): parser.error('Runtime or scene is missing')
if args.display_id<=0: parser.error('Display ID must be positive')
OUT=args.output.resolve();OUT.mkdir(parents=True)

RESULT={}
class Renderer:
 def __init__(self,name,pkg,quality):
  self.out=OUT/name;self.out.mkdir(exist_ok=True);self.log=[];self.events=queue.Queue()
  storage=self.out/'storage';storage.mkdir(exist_ok=True)
  (storage/(pkg.parent.name+'.json')).write_text(json.dumps({'probe':'7'}))
  env=os.environ.copy();env['RSTD_LOG']='info';env.update(VK_ICD_FILENAMES=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json'),VK_DRIVER_FILES=str(ROOT/'Resources/Renderers/vulkan/icd.d/MoltenVK_icd.json'),DYLD_FALLBACK_LIBRARY_PATH=str(ROOT/'Frameworks'),FONTCONFIG_FILE=str(ROOT/'Resources/fonts/fonts.conf'))
  if '--metalfx' in quality:
   env['SCENERENDERER_DIAGNOSTICS_DIR']=str(self.out)
   (self.out/'capture').touch()
  args=[str(ROOT/'Resources/Renderers/SceneWallpaper'),'--display-id',str(args.display_id),'--fps','15','--muted','--no-spectrum','--no-mouse','--deferred-show','--control-stdin','--run-seconds','90','--cache-path',str(self.out/'cache'),'--script-storage-dir',str(storage)]+quality+[str(ROOT/'Resources/assets'),str(pkg)]
  (self.out/'arguments.json').write_text(json.dumps(args,indent=2))
  self.p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
  threading.Thread(target=self.reader,daemon=True).start()
 def reader(self):
  for line in self.p.stdout:
   self.log.append(line)
   try:self.events.put(json.loads(line))
   except ValueError:pass
 def wait(self,event,token=None,timeout=30):
  end=time.monotonic()+timeout
  while time.monotonic()<end:
   try:v=self.events.get(timeout=.2)
   except queue.Empty:
    if self.p.poll() is not None:raise RuntimeError('renderer exited '+str(self.p.returncode))
    continue
   if v.get('event')==event and (token is None or v.get('token')==token):return v
  raise RuntimeError('timeout '+event)
 def send(self,cmd):self.p.stdin.write(json.dumps(cmd)+'\n');self.p.stdin.flush()
 def shot(self,name):
  file=self.out/(name+'.heic');self.send(dict(cmd='snapshot',path=str(file),token=name))
  assert self.wait('snapshot-done',name,10).get('ok')
  png=file.with_suffix('.png');subprocess.run(['sips','-s','format','png',str(file),'--out',str(png)],check=True,stdout=subprocess.DEVNULL)
  return Image.open(png).convert('RGB')
 def storage(self,name):
  self.send(dict(cmd='exportScriptStorage',token=name));data=self.wait('script-storage',name,8)['values'];(self.out/(name+'.json')).write_text(json.dumps(data,indent=2));return data
 def close(self):
  self.p.stdin.close()
  try:self.p.wait(timeout=6)
  except subprocess.TimeoutExpired:self.p.terminate();self.p.wait(timeout=3)
  (self.out/'renderer.log').write_text(''.join(self.log));print('closed',self.p.pid,self.p.returncode,flush=True)
  assert self.p.returncode==0

def diff(a,b):return sum(ImageStat.Stat(ImageChops.difference(a,b)).mean)/3
if __name__ == '__main__':
 r=Renderer('live',PKG,['--resolution','960x600'])
 try:
  r.wait('first-frame-presented');r.send(dict(cmd='setProperty',key='clock',value=False));time.sleep(.7)
  a=r.shot('running-a');time.sleep(1.2);b=r.shot('running-b')
  r.send(dict(cmd='power',state='pause',fps=15));time.sleep(.5);c=r.shot('paused-a');time.sleep(1.2);d=r.shot('paused-b')
  assert diff(c,d)==0,('paused pixels changed',diff(c,d))
  r.send(dict(cmd='volume',value=.4));r.send(dict(cmd='muted',value=True));r.send(dict(cmd='speed',value=1.5))
  r.send(dict(cmd='power',state='run',fps=30));time.sleep(1.3);e=r.shot('resumed')
  assert diff(a,b)>0 and diff(d,e)>0
  exported=r.storage('before-reset');assert exported.get('probe')=='7',exported
  r.send(dict(cmd='resetScriptStorage'));time.sleep(.2);reset=r.storage('after-reset');assert reset=={},reset
  r.send(dict(cmd='mediaStatus',data=dict(state=1,title='Test Track',artist='Test Artist',duration=30,position=5,artURL='',previousArtURL='')))
  RESULT['live']=dict(pid=r.p.pid,runningPixelDifference=diff(a,b),pausedPixelDifference=diff(c,d),resumedPixelDifference=diff(d,e),snapshotSize=e.size,firstFrames=sum('first-frame-presented' in x for x in r.log),storageReset=True,hidden=not any('"event":"activated"' in x for x in r.log))
  print(json.dumps(RESULT['live']),flush=True)
 finally:r.close()
 r=Renderer('quality',PKG,['--render-scale','0.25','--metalfx','--msaa','4'])
 try:
  r.wait('first-frame-presented');time.sleep(.7);frame=r.shot('metalfx-msaa4')
  presentation=json.loads((r.out/'presentation.json').read_text());assert presentation['metalfx_presenter'],presentation
  RESULT['quality']=dict(presentation=presentation,snapshotSize=frame.size,firstFrame=True,requestedMSAA=4,requestedRenderScale=.25)
  print(json.dumps(RESULT['quality']),flush=True)
 finally:r.close()
 fixture=OUT/'position-fixture';fixture.mkdir(exist_ok=True)
 scene={'camera':{},'general':{'clearcolor':[0,0,0],'orthogonalprojection':{'width':1920,'height':1080}},'objects':[]}
 for i in range(3):
  color=[0,0,0];color[i]=1
  scene['objects'].append(dict(id=i+1,image='models/util/solidlayer.json',origin=[320+i*640,540,0],size=[640,1080],color=color,visible=True))
 (fixture/'scene.json').write_text(json.dumps(scene))
 r=Renderer('position',fixture/'scene.json',['--resolution','300x600'])
 try:
  r.wait('first-frame-presented');r.send(dict(cmd='power',state='pause',fps=15));time.sleep(.3)
  colors=[]
  for x in [0,.5,1]:
   r.send(dict(cmd='position',x=x,y=.5));time.sleep(.3);frame=r.shot('crop-'+str(x));colors.append(frame.getpixel((frame.width//2,frame.height//2)))
  assert all(c[i]>200 and sum(c)-c[i]<60 for i,c in enumerate(colors)),colors
  r.send(dict(cmd='fillmode',value='contain'));time.sleep(.3);contain=r.shot('contain');assert max(contain.getpixel((contain.width//2,10)))<20
  r.send(dict(cmd='fillmode',value='stretch'));time.sleep(.3);stretch=r.shot('stretch');assert stretch.getpixel((stretch.width//2,10))[1]>200
  RESULT['position']=dict(colors=colors,containTop=contain.getpixel((contain.width//2,10)),stretchTop=stretch.getpixel((stretch.width//2,10)),changedWhilePaused=True)
  print(json.dumps(RESULT['position']),flush=True)
 finally:r.close()
 (OUT/'result.json').write_text(json.dumps(RESULT,indent=2))

 f=OUT/'property-fixture';f.mkdir(exist_ok=True)
 for name,color in [('red',(255,0,0)),('green',(0,255,0))]:Image.new('RGB',(64,64),color).save(f/(name+'.png'))
 (f/'model.json').write_text(json.dumps({'material':'material.json'}))
 (f/'material.json').write_text(json.dumps({'passes':[{'shader':'genericimage','textures':[str(f/'red.png')],'cullmode':'nocull','depthtest':'disabled','depthwrite':'disabled','blending':'normal'}]}))
 js="export function mediaPropertiesChanged(event) { localStorage.set('receivedTitle',event.title); } export function mediaThumbnailChanged(event) {localStorage.set('receivedArt',event.thumbnail || 'event');} export function update(){ localStorage.set('tick',engine.runtime);return true;}"
 scene={'camera':{},'general':{'clearcolor':[0,0,0],'orthogonalprojection':{'width':1000,'height':600}},'objects':[dict(id=1,image='model.json',origin=[500,300,0],size=[1000,600],instance={'usertextures':['picture']},visible={'value':True,'script':js})]}
 (f/'scene.json').write_text(json.dumps(scene));(f/'project.json').write_text(json.dumps({'general':{'properties':{'picture':{'type':'scenetexture','value':str(f/'red.png'),'text':'Picture'}}}}))
 r=Renderer('properties',f/'scene.json',['--resolution','1000x600','--msaa','4'])
 try:
  r.wait('first-frame-presented');time.sleep(.4);a=r.shot('red')
  r.send(dict(cmd='setProperty',key='picture',value=dict(type='scenetexture',value=str(f/'green.png'))));time.sleep(.5);b=r.shot('green')
  ca=a.getpixel((500,300));cb=b.getpixel((500,300));assert ca[0]>200 and cb[1]>200,(ca,cb)
  r.send(dict(cmd='mediaStatus',data=dict(state=1,title='Fixture Song',artist='Fixture Artist',album='Fixture Album',duration=60,position=10,artURL=str(f/'green.png'),previousArtURL='')));time.sleep(.3)
  data=r.storage('media-delivered');assert json.loads(data['receivedTitle'])=='Fixture Song',data
  r.send(dict(cmd='speed',value=.25));time.sleep(.3);slow0=float(json.loads(r.storage('slow-start')['tick']));time.sleep(1.2);slow1=float(json.loads(r.storage('slow-end')['tick']))
  r.send(dict(cmd='speed',value=2));time.sleep(.3);fast0=float(json.loads(r.storage('fast-start')['tick']));time.sleep(1.2);fast1=float(json.loads(r.storage('fast-end')['tick']))
  assert fast1-fast0 > (slow1-slow0)*3, (slow1-slow0,fast1-fast0)
  result=dict(slowAnimationSeconds=slow1-slow0,fastAnimationSeconds=fast1-fast0,textureBefore=ca,textureAfter=cb,mediaTitleDelivered=True,mediaArtworkEvent='receivedArt' in data,firstFrameEvents=sum('first-frame-presented' in x for x in r.log),msaaLog=[x.strip() for x in r.log if 'msaa requested' in x])
  print(json.dumps(result),flush=True);(OUT/'property-result.json').write_text(json.dumps(result,indent=2))
 finally:r.close()
