#!/usr/bin/env python3
"""Local WebKit/GLB lifecycle test. Uses a hidden preview; never activates desktop wallpaper."""
import json,os,pathlib,select,subprocess,sys,time
renderer=pathlib.Path(sys.argv[1]).resolve();assets=pathlib.Path(sys.argv[2]).resolve()
out=pathlib.Path(sys.argv[3]).resolve();out.mkdir(parents=True,exist_ok=True)
p=subprocess.Popen([str(renderer),'--preview','--deferred-show','--control-stdin','--assets',str(assets)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
buffer=b''
def wait(name,timeout=45):
 global buffer
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  while b'\n' in buffer:
   line,buffer=buffer.split(b'\n',1);e=json.loads(line)
   if e['event']=='error':raise RuntimeError(e)
   if e['event']==name:return e
  if p.poll() is not None:raise RuntimeError(p.stderr.read().decode())
  if select.select([p.stdout],[],[],max(0,deadline-time.monotonic()))[0]:buffer+=os.read(p.stdout.fileno(),65536)
 raise TimeoutError(name)
def send(data):p.stdin.write(json.dumps(data).encode()+b'\n');p.stdin.flush()
def state():send({'cmd':'diagnostics'});return wait('diagnostics')
def shot(name):
 path=out/(name+'.png');send({'cmd':'snapshot','path':str(path),'token':name});assert wait('snapshot-done')['ok'];assert path.read_bytes()[:8]==b'\x89PNG\r\n\x1a\n';return path
try:
 ready=wait('scene-ready');assert ready['triangles']>1000000;wait('first-frame-presented');time.sleep(1.2)
 a=state();time.sleep(1.2);b=state();assert b['yaw']>a['yaw'] and b['seconds']!=a['seconds'];shot('01-rotating')
 send({'cmd':'power','state':'pause','fps':15});time.sleep(.2);a=state();time.sleep(.6);b=state();assert b['renderedFrames']==a['renderedFrames'] and b['paused']
 assert b['mouseFollow'] is False and b['modeControls']==0
 send({'cmd':'pointer','x':1,'y':-1,'dx':600,'dy':-400,'drag':False,'light':True});time.sleep(.3);c=state()
 assert c['moonRotation']==b['moonRotation'] and c['targetYaw']==b['targetYaw'] and c['targetPitch']==b['targetPitch'], 'plain pointer movement must not affect Moon'
 assert c['lightPosition']==b['lightPosition'], 'lighting must remain fixed'
 send({'cmd':'power','state':'play','fps':30});time.sleep(.2);assert state()['renderedFrames']>b['renderedFrames']
 send({'cmd':'pointer','x':.2,'y':-.1,'dx':60,'dy':30,'drag':True,'light':False});time.sleep(.6);b=state();assert b['targetYaw']>.3 and b['targetPitch']>.1 and b['auto']
 time.sleep(.5);assert state()['yaw']>b['yaw'], 'rotation resumes after a drag'
 send({'cmd':'scroll','delta':-150});time.sleep(.8);assert state()['zoom']>1.05
 send({'cmd':'reset'});time.sleep(.8)
 send({'cmd':'reset'});time.sleep(1);shot('00-preview')
 report={'ready':ready,'state':state(),'checks':['NASA geometry loaded','clock advances','Moon rotates','pause stops rendered frames','resume','drag rotates','wheel zooms','fixed lighting','no mode controls','no pointer following','rotation continues after dragging','PNG capture']}
 p.stdin.close();assert p.wait(timeout=8)==0;report['checks'].append('parent EOF cleanup')
 (out/'verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
finally:
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:p.kill();p.wait()
