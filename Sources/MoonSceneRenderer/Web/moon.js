import * as THREE from 'three';
import { GLTFLoader } from './vendor/addons/loaders/GLTFLoader.js';

const $ = id => document.getElementById(id);
const native = data => window.webkit?.messageHandlers?.scene?.postMessage(data);
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
let paused = false, fps = 30, speed = 1;
let yaw = 0, pitch = 0, targetYaw = 0, targetPitch = 0, zoom = 1, targetZoom = 1;
let dragging = false, lastPointer = null;
let lastFrame = 0, previousRenderTime = 0, raf = 0, ready = false, renderedFrames = 0;
const root = $('universe');
const scene = new THREE.Scene();
const camera = new THREE.OrthographicCamera(-5, 5, 3, -3, .1, 80);
camera.position.set(0, 0, 14);
const orbit = new THREE.Group(), moon = new THREE.Group();
scene.add(orbit); orbit.add(moon);
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: 'low-power' });
renderer.setClearColor(0x05070b);
renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.08;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
root.appendChild(renderer.domElement);
const sunOffset = new THREE.Vector3(-4.8, 3.2, 6);
const sun = new THREE.DirectionalLight(0xf4f1ec, 3.15);
sun.position.copy(sunOffset); sun.castShadow = true;
sun.shadow.mapSize.set(4096, 4096);
sun.shadow.camera.left = sun.shadow.camera.bottom = -2.3;
sun.shadow.camera.right = sun.shadow.camera.top = 2.3;
sun.shadow.camera.near = .1; sun.shadow.camera.far = 30;
sun.shadow.normalBias = .004; sun.shadow.bias = -.00004;
scene.add(sun, sun.target);
scene.add(new THREE.AmbientLight(0x8997ad, .045));
const earthshine = new THREE.DirectionalLight(0x99a7bd, .13);
earthshine.position.set(5, -2, 4); scene.add(earthshine);
let seed = 4187;
function random(){seed=(seed*1664525+1013904223)>>>0;return seed/4294967296;}
const positions=[], colors=[];
for(let i=0;i<520;i++){
 positions.push((random()-.5)*32,(random()-.5)*20,-8-random()*4);
 const c=.09+Math.pow(random(),5)*.43; colors.push(c*.83,c*.9,c);
}
const starGeometry=new THREE.BufferGeometry();
starGeometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));
starGeometry.setAttribute('color',new THREE.Float32BufferAttribute(colors,3));
scene.add(new THREE.Points(starGeometry,new THREE.PointsMaterial({size:.016,vertexColors:true,transparent:true,opacity:.8,sizeAttenuation:true,depthWrite:false})));
const points=[];
for(let i=0;i<240;i++){const a=i/240*Math.PI*2;points.push(new THREE.Vector3(Math.cos(a)*2.5,Math.sin(a)*2.5,0));}
const ring = new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(points),new THREE.LineBasicMaterial({color:0x7f796b,transparent:true,opacity:.13}));
ring.rotation.set(.86,.23,-.44); ring.position.z=-.4; orbit.add(ring);

function resize(){
 const w=innerWidth,h=innerHeight,aspect=w/h;camera.left=-3*aspect;camera.right=3*aspect;camera.updateProjectionMatrix();
 renderer.setSize(w,h);
 orbit.position.set(aspect<1?0:aspect*.96,aspect<1?.85:.24,0);
 const s=aspect<1?Math.min(1,aspect*1.35):1;orbit.scale.setScalar(s);
 sun.target.position.copy(orbit.position); earthshine.target= sun.target;
 drawOnce();
}
function updateClock(){
 const d=new Date(), pad=n=>String(n).padStart(2,'0');
 $('clock').textContent=`${pad(d.getHours())}:${pad(d.getMinutes())}`;
 $('clock').dateTime=d.toISOString();$('seconds').textContent=pad(d.getSeconds());
 $('date').textContent=`${d.getFullYear()} / ${pad(d.getMonth()+1)} / ${pad(d.getDate())}　${['星期日','星期一','星期二','星期三','星期四','星期五','星期六'][d.getDay()]}`;
 const offset=-d.getTimezoneOffset(),sign=offset>=0?'+':'−';
 $('zone').textContent=`LOCAL TIME / UTC ${sign}${pad(Math.floor(Math.abs(offset)/60))}:${pad(Math.abs(offset)%60)}`;
}
function reset(){targetYaw=0;targetPitch=0;targetZoom=1;if(paused)drawOnce();}
function drawOnce(){if(ready) render(0);}
function render(dt){
 const t=1-Math.exp(-dt*7), instant=dt===0?1:t;
 if(!dragging&&!reduced.matches)targetYaw+=dt*.025*speed;
 yaw+=(targetYaw-yaw)*instant;pitch+=(targetPitch-pitch)*instant;zoom+=(targetZoom-zoom)*instant;
 moon.rotation.set(pitch,yaw,-.06);
 moon.scale.setScalar(zoom);
 sun.position.copy(sunOffset).add(orbit.position);
 renderer.render(scene,camera);renderedFrames++;
}
function loop(now){
 raf=0;if(paused||document.hidden)return;
 const elapsed=now-lastFrame, interval=1000/fps;
 if(elapsed>=interval){const dt=Math.min((now-previousRenderTime)/1000,.1);lastFrame=now-(elapsed%interval);previousRenderTime=now;if(ready)render(dt);}
 raf=requestAnimationFrame(loop);
}
function startLoop(){if(!raf&&!paused&&!document.hidden){lastFrame=previousRenderTime=performance.now();raf=requestAnimationFrame(loop);}}
function drag(dx,dy){targetYaw+=dx*.006;targetPitch=THREE.MathUtils.clamp(targetPitch+dy*.004,-1.15,1.15);if(paused)drawOnce();}
function scroll(d){targetZoom=THREE.MathUtils.clamp(targetZoom-d*.0007,.7,1.35);if(paused)drawOnce();}
root.addEventListener('pointerdown',e=>{dragging=true;lastPointer=[e.clientX,e.clientY];root.setPointerCapture(e.pointerId);});
root.addEventListener('pointermove',e=>{if(dragging&&lastPointer){drag(e.clientX-lastPointer[0],e.clientY-lastPointer[1]);lastPointer=[e.clientX,e.clientY];}});
root.addEventListener('pointerup',()=>{dragging=false;lastPointer=null;});
root.addEventListener('pointercancel',()=>{dragging=false;lastPointer=null;});
root.addEventListener('wheel',e=>{e.preventDefault();scroll(e.deltaY);},{passive:false});
root.addEventListener('dblclick',reset);
root.addEventListener('keydown',e=>{if(e.key.startsWith('Arrow')){e.preventDefault();drag(e.key==='ArrowLeft'?-8:e.key==='ArrowRight'?8:0,e.key==='ArrowUp'?-8:e.key==='ArrowDown'?8:0);}});
document.addEventListener('keydown',e=>{if(e.key.toLowerCase()==='r')reset();});
window.addEventListener('resize',resize);
document.addEventListener('visibilitychange',()=>{if(document.hidden){cancelAnimationFrame(raf);raf=0;}else{updateClock();startLoop();}});
reduced.addEventListener('change',drawOnce);
renderer.domElement.addEventListener('webglcontextlost',e=>{e.preventDefault();fail('图形上下文已中断，请重新加载场景。');});
function fail(message){$('loading').classList.add('done');$('error').hidden=false;$('error-text').textContent=message;native({event:'error',message});}
window.addEventListener('error',e=>fail(e.message));
window.addEventListener('unhandledrejection',e=>fail(String(e.reason)));
// The native host sends only validated data, never executable source from the scene manifest.
window.sceneControl=command=>{
 switch(command.cmd){
 case 'desktop': document.body.classList.add('desktop');break;
 case 'pointer':if(command.drag)drag(command.dx,command.dy);break;
 case 'scroll':scroll(command.delta);break;
 case 'reset':reset();break;
 case 'speed':speed=Math.max(.25,Math.min(2,command.value));break;
 case 'power':paused=command.state==='pause';fps=Math.max(1,Math.min(60,command.fps||30));if(paused){cancelAnimationFrame(raf);raf=0;}else startLoop();break;
 }
};
window.sceneDiagnostics=()=>({ready,lightPosition:sun.position.clone().sub(orbit.position).toArray(),mouseFollow:false,modeControls:document.querySelectorAll("nav,[data-light]").length,moonRotation:moon.rotation.toArray(),auto:!reduced.matches,paused,fps,yaw,pitch,zoom,targetYaw,targetPitch,targetZoom,renderedFrames,clock:$('clock').textContent,seconds:$('seconds').textContent,triangles:renderer.info.render.triangles,drawCalls:renderer.info.render.calls,model:'NASA LRO 8k Topo Small'});
updateClock();setInterval(updateClock,1000);resize();
new GLTFLoader().load('./assets/moon.glb',gltf=>{
 const source=gltf.scene;
 source.traverse(node=>{if(node.isMesh){
  const m=node.material;
  node.material=new THREE.MeshStandardMaterial({map:m.map,normalMap:m.normalMap,normalScale:m.normalScale,roughness:1,metalness:0,color:0xc9c9c9});
  if(m.map){m.map.anisotropy=Math.min(8,renderer.capabilities.getMaxAnisotropy());}
  node.castShadow=true;node.receiveShadow=true;
 }});
 const box=new THREE.Box3().setFromObject(source),center=box.getCenter(new THREE.Vector3()),size=box.getSize(new THREE.Vector3());
 const scale=3.9/Math.max(size.x,size.y,size.z);source.position.copy(center).multiplyScalar(-scale);source.scale.setScalar(scale);moon.add(source);
 ready=true;resize();render(0);$('loading').classList.add('done');
 native({event:'scene-ready',renderWidth:renderer.domElement.width,renderHeight:renderer.domElement.height,targetFPS:fps,triangles:renderer.info.render.triangles});
 requestAnimationFrame(()=>{native({event:'first-frame-presented'});startLoop();});
},event=>{if(event.total)$('loading-text').textContent=`正在展开月面 · ${Math.round(event.loaded/event.total*100)}%`;},error=>fail('NASA 模型加载失败：'+error.message));
