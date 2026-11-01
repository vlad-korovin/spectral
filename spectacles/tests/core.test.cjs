const {test}=require('node:test'),assert=require('node:assert/strict');
const O=require('../.test-build/Optics'),M=require('../.test-build/Materials'),L=require('../.test-build/Lesson'),G=require('../.test-build/Lighting'),I=require('../.test-build/IdleMotion');
const near=(a,b,t=1e-8)=>assert.ok(Math.abs(a-b)<t,`${a} != ${b}`);
test('normal incidence and Brewster angle match analytic Fresnel',()=>{
 near(O.fresnel(1,1,1.5),.04);near(O.fresnel(1,1.5,1),.04);near(O.fresnel(0,1,1),0);
 const angle=Math.atan(1.5),c=Math.cos(angle),ct=Math.sqrt(1-(Math.sin(angle)/1.5)**2);
 near(O.fresnel(c,1,1.5),.5*((c-1.5*ct)/(c+1.5*ct))**2);
});
test('Snell reversibility, grazing rays, TIR boundary',()=>{
 for(const n of [1.33,1.5,2.4])for(let a=0;a<89;a+=1.5){const i=[Math.sin(a*Math.PI/180),-Math.cos(a*Math.PI/180),0];const t=O.refract(i,[0,1,0],1,n);near(n*t[0],i[0]);const r=O.refract(O.mul(t,-1),[0,-1,0],n,1);r.forEach((x,j)=>near(x,-i[j]));}
 const critical=Math.asin(1/1.5);for(const delta of [-1e-6,1e-6]){const a=critical+delta;const t=O.refract([Math.sin(a),-Math.cos(a),0],[0,1,0],1.5,1);assert.equal(t===null,delta>0);}
 near(O.fresnel(0,1,1.5),1);
});
test('material reference values, finite monotonic dispersion and domain checks',()=>{
 near(M.ior('crown',587.6),1.5168,1e-5);near(M.ior('crown',486.1),1.52238,1e-5);near(M.ior('crown',656.3),1.51432,1e-5);
 near(M.ior('water',589.3),1.333,5e-4);near(M.ior('diamond',589.3),2.417,3e-3);near(M.ior('sapphire',589.3),1.768,2e-3);
 for(const m of M.MATERIALS){let previous=Infinity;for(let nm=420;nm<=680;nm++){const n=M.ior(m,nm);assert.ok(n>1&&n<previous);previous=n;}}
 for(const nm of [0,419,681,NaN,Infinity])assert.throws(()=>M.ior('crown',nm));
});
test('spectral quadrature conserves a white display response for every sample count',()=>{
 for(const n of [2,13,24,31]){const s=M.samples('crown','white',n);for(let c=0;c<3;c++)near(s.reduce((sum,x)=>sum+x.color[c],0),1);}
 assert.throws(()=>M.samples('water','white',32));
});
test('all five area-light patterns conserve energy and remain bounded',()=>{
 assert.deepEqual(G.LIGHTING_STYLES,['soft','spot','strip','window','halo']);
 for(const style of G.LIGHTING_STYLES){const p=G.lightingPattern(style);near(p.reduce((sum,x)=>sum+x.weight,0),1);assert.ok(p.length>=1&&p.length<=8);for(const x of p){assert.ok(Number.isFinite(x.x)&&Number.isFinite(x.y)&&x.weight>0);assert.ok(Math.hypot(x.x,x.y)<=1.001);}}
});
test('convex display geometry and optical boundary are the same closed solid',()=>{
 for(const planes of [O.CRYSTAL,O.PRISM]){
  const faces=O.faces(planes);assert.equal(faces.length,planes.length);
  const edges=new Map();for(const f of faces){assert.ok(O.dot(O.cross(O.sub(f.vertices[1],f.vertices[0]),O.sub(f.vertices[2],f.vertices[0])),f.normal)>0);
   for(let i=0;i<f.vertices.length;i++){const p=f.vertices[i],q=f.vertices[(i+1)%f.vertices.length];for(const plane of planes)assert.ok(O.dot(plane.n,p)<=plane.h+1e-7);
    const key=[p,q].map(v=>v.map(x=>x.toFixed(6)).join(',')).sort().join('|');edges.set(key,(edges.get(key)||0)+1);}
  }
  for(const count of edges.values())assert.equal(count,2);
 }
});
test('ray sweep: correct interface equations and energy, bounded termination',()=>{
 let escaped=0,tir=0;for(const m of M.MATERIALS)for(let a=0;a<360;a+=7){const r=a*Math.PI/180,o=[.4*Math.cos(r),.072,.4*Math.sin(r)],d=O.unit(O.sub([0,.072,0],o));const path=O.trace(o,d,M.ior(m,550));assert.ok(path.events.length<=6);assert.ok(path.energy>=0&&path.energy<=1);if(path.escaped)escaped++;tir+=path.tir;
  for(const e of path.events)if(e.refracted!==null)near(e.ni*Math.sin(e.incident),e.nt*Math.sin(e.refracted),1e-7);
  if(!path.escaped)assert.equal(path.energy,0);
 }
 assert.ok(escaped>0&&tir>0);
});
test('slab exits parallel and includes both Fresnel transmissions',()=>{
 const slab=[{n:[1,0,0],h:.1},{n:[-1,0,0],h:.1},{n:[0,1,0],h:10},{n:[0,-1,0],h:10},{n:[0,0,1],h:10},{n:[0,0,-1],h:10}];
 const d=O.unit([1,.3,0]),p=O.trace([-.5,0,0],d,1.5,slab);assert.ok(p.escaped);p.direction.forEach((v,i)=>near(v,d[i]));near(p.energy,(1-O.fresnel(d[0],1,1.5))**2);
});
test('dispersion changes exit directions and pose changes paths',()=>{
 const origin=[-.4,.03,.025],direction=O.unit(O.sub([0,.07,0],origin));
 const a=O.trace(origin,direction,M.ior('crown',420)),b=O.trace(origin,direction,M.ior('crown',680));assert.ok(a.escaped&&b.escaped);assert.ok(O.length(O.sub(a.direction,b.direction))>.001);
 const c=O.trace([-.35,.09,.18],O.unit([.35,-.02,-.18]),M.ior('crown',420));assert.notDeepEqual(a.points,c.points);
});
test('misses, inside starts and budget limits never create fabricated caustics',()=>{
 assert.equal(O.trace([1,1,1],[1,0,0],1.5).status,'miss');assert.equal(O.trace([0,.07,0],[1,0,0],1.5).status,'inside');
 assert.equal(O.trace([-.4,.07,0],[1,0,0],1.5,O.CRYSTAL,0).energy,0);
 assert.equal(O.receiverHit([0,1,0],[1,0,0],{n:[0,1,0],h:0}),null);
 assert.equal(O.receiverHit([0,1,0],[0,1,0],{n:[0,1,0],h:0}),null);
 assert.deepEqual(O.receiverHit([0,1,0],[0,-1,0],{n:[0,1,0],h:0}),[0,0,0]);
});
test('voice handles final exact commands, rejects negation and ambient mentions',()=>{
 assert.deepEqual(L.parseVoice('Spectral, crown glass!',true),{kind:'material',value:'crown'});
 assert.deepEqual(L.parseVoice('Spectral halo light',true),{kind:'style',value:'halo'});
 for(const text of ['diamond','do not spectral diamond','spectral diamond please','spectral watership','__proto__'])assert.equal(L.parseVoice(text,true),null);
 assert.equal(L.parseVoice('spectral diamond',false),null);
});
test('network settings reject malformed/out-of-schema/oversized values',()=>{
 assert.deepEqual(L.decodeSettings(JSON.stringify(L.DEFAULT_SETTINGS)),L.DEFAULT_SETTINGS);
 assert.deepEqual(L.decodeSettings('{"schema":1,"material":"crown","light":"white","lesson":true}'),{...L.DEFAULT_SETTINGS,lesson:true});
 for(const s of ['null','{}','x','x'.repeat(257),'{"schema":3,"material":"crown","light":"white","style":"soft","lesson":true}','{"schema":2,"material":"fake","light":"white","style":"soft","lesson":true}','{"schema":2,"material":"crown","light":"white","style":"laser","lesson":true}'])assert.equal(L.decodeSettings(s),null);
});
test('late room queries cannot update a newer pose',()=>{const gate=new L.RevisionGate(),a=gate.next(),b=gate.next();assert.equal(gate.accepts(a),false);assert.equal(gate.accepts(b),true);});
test('idle motion matches the iOS delay, bounds and frame-rate independent turn',()=>{
 const run=step=>{const idle=new I.IdleCrystalMotion();idle.reset(0);let yaw=0,frame;for(let t=step;t<=12+1e-9;t+=step){frame=idle.step(t,true);yaw+=frame.yawDelta;}return {yaw,frame};};
 const delayed=new I.IdleCrystalMotion();delayed.reset(0);for(const t of [.1,1,2.9,3]){const frame=delayed.step(t,true);assert.deepEqual(frame.offset,[0,0,0]);near(frame.yawDelta,0);}
 const fast=run(1/120),slow=run(1/30);near(fast.yaw,slow.yaw,2e-3);
 for(const frame of [fast.frame,slow.frame]){assert.ok(Math.abs(frame.offset[0])<=.00801);assert.ok(frame.offset[1]>=0&&frame.offset[1]<=.13201);assert.ok(frame.offset[2]>=-.01201&&frame.offset[2]<=.00001);assert.ok(frame.cinema>=0&&frame.cinema<=1);}
});
test('idle pause preserves the airborne pose and landing returns smoothly to zero',()=>{
 const idle=new I.IdleCrystalMotion();idle.reset(0);for(let t=.05;t<=7;t+=.05)idle.step(t,true);
 const before=[...idle.offset];idle.pause(7);idle.step(7.1,false);assert.deepEqual(idle.offset,before);
 idle.land(7.1);for(let t=7.15;t<=8.4;t+=.05)idle.step(t,true);idle.offset.forEach(value=>near(value,0,1e-8));near(idle.cinema,0,1e-8);
});
