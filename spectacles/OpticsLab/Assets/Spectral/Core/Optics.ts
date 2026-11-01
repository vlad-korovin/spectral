/** Portable optical model. Metres, nanometres, radians. No Lens globals. */
export type V = [number, number, number];
export interface Plane { n: V; h: number }
export const add = (a: V,b: V): V => [a[0]+b[0],a[1]+b[1],a[2]+b[2]];
export const mul = (a: V,s: number): V => [a[0]*s,a[1]*s,a[2]*s];
export const sub = (a: V,b: V): V => add(a,mul(b,-1));
export const dot = (a: V,b: V) => a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
export const cross = (a: V,b: V): V => [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
export const length = (a: V) => Math.sqrt(dot(a,a));
export function unit(a: V): V { const m=length(a); if(!Number.isFinite(m)||m<1e-12) throw Error('Invalid direction'); return mul(a,1/m); }
export const clamp = (x: number,a=0,b=1) => Math.min(b,Math.max(a,x));
export const reflect = (d: V,n: V): V => sub(d,mul(n,2*dot(d,n)));
export function refract(d: V,n: V,ni: number,nt: number): V|null {
  const c=clamp(-dot(d,n)), eta=ni/nt, k=1-eta*eta*(1-c*c);
  return k<0?null:unit(add(mul(d,eta),mul(n,eta*c-Math.sqrt(k))));
}
export function fresnel(c: number,ni: number,nt: number): number {
  c=clamp(c); if(ni===nt)return 0;
  const s2=(ni/nt)**2*(1-c*c); if(s2>=1)return 1;
  const ct=Math.sqrt(1-s2), rs=(ni*c-nt*ct)/(ni*c+nt*ct),rp=(nt*c-ni*ct)/(nt*c+ni*ct);
  return clamp((rs*rs+rp*rp)/2);
}
export function intersect(o: V,d: V,planes: readonly Plane[]) {
  let enter=-Infinity, leave=Infinity, entry=-1, exit=-1;
  for(let i=0;i<planes.length;i++) {
    const p=planes[i],den=dot(p.n,d),dist=p.h-dot(p.n,o);
    if(Math.abs(den)<1e-9) { if(dist<0)return null; continue; }
    const t=dist/den;
    if(den<0&&t>enter){enter=t;entry=i;}
    if(den>0&&t<leave){leave=t;exit=i;}
  }
  return leave>Math.max(enter,0)&&exit>=0?{enter,leave,entry,exit}:null;
}
/** Same 18 half-spaces as the frozen iPhone Optics.metal; normalize h with n. */
export const CRYSTAL: Plane[] = (()=>{
  const cs=[1,Math.SQRT1_2,0,-Math.SQRT1_2,-1,-Math.SQRT1_2,0,Math.SQRT1_2];
  const sn=[0,Math.SQRT1_2,1,Math.SQRT1_2,0,-Math.SQRT1_2,-1,-Math.SQRT1_2];
  const p: Plane[]=[];
  for(let i=0;i<16;i++) {const n:V=i<8?[cs[i%8]*.714142843,.7,sn[i%8]*.714142843]:[cs[i%8]*.6,-.8,sn[i%8]*.6];p.push({n:unit(n),h:(i<8?.102772856:.01)/length(n)});}
  p.push({n:[0,-1,0],h:0},{n:[0,1,0],h:.145});return p;
})();
export const PRISM: Plane[] = [
  {n:[0,-1,0],h:.05},{n:[Math.sqrt(3)/2,.5,0],h:.05},
  {n:[-Math.sqrt(3)/2,.5,0],h:.05},{n:[0,0,1],h:.05},{n:[0,0,-1],h:.05}
];
export interface SurfaceEvent { point: V; normal: V; incident: number; refracted: number|null; critical: number|null; ni:number; nt:number; reflectance:number; face:number }
export interface Path { points: V[]; events: SurfaceEvent[]; origin:V; direction:V; energy:number; escaped:boolean; tir:number; status:'miss'|'inside'|'escaped'|'budget' }
const EPS=1e-5;
export function trace(origin: V,direction: V,index: number,planes=CRYSTAL,maxBounces=5): Path {
  let d=unit(direction),o=origin;
  const p:Path={points:[o],events:[],origin:o,direction:d,energy:0,escaped:false,tir:0,status:'miss'};
  const first=intersect(o,d,planes);if(!first)return p;
  if(first.enter<0||first.entry<0){p.status='inside';return p;}
  let energy=1;
  const event=(point:V,n:V,ni:number,nt:number,face:number)=>{
    const c=clamp(-dot(d,n)), t=refract(d,n,ni,nt),r=fresnel(c,ni,nt);
    p.events.push({point,normal:n,incident:Math.acos(c),refracted:t?Math.acos(clamp(-dot(t,n))):null,critical:ni>nt?Math.asin(nt/ni):null,ni,nt,reflectance:r,face});
    return t;
  };
  o=add(o,mul(d,first.enter));p.points.push(o);
  let t=event(o,planes[first.entry].n,1,index,first.entry);if(!t)return p;
  energy*=1-p.events[0].reflectance;d=t;o=add(o,mul(d,EPS));
  for(let bounce=0;bounce<maxBounces;bounce++) {
    const inside=intersect(o,d,planes);if(!inside)break;
    o=add(o,mul(d,inside.leave));p.points.push(o);
    const n=mul(planes[inside.exit].n,-1);t=event(o,n,index,1,inside.exit);
    if(t) {
      energy*=1-p.events[p.events.length-1].reflectance;
      return {...p,origin:add(o,mul(t,EPS)),direction:t,energy,escaped:true,status:'escaped'};
    }
    p.tir++;d=reflect(d,n);o=add(o,mul(d,EPS));
  }
  return {...p,origin:o,direction:d,status:'budget'}; // Never invent an exit.
}
export function receiverHit(o: V,d: V,plane: Plane,maxDistance=5): V|null {
  const den=dot(plane.n,d);if(Math.abs(den)<1e-7)return null;
  const t=(plane.h-dot(plane.n,o))/den;
  return t>EPS&&t<=maxDistance?add(o,mul(d,t)):null;
}
/** Construct the display mesh from the SAME half-spaces used by the ray tracer. */
export function faces(planes: readonly Plane[]): {normal:V;vertices:V[]}[] {
  return planes.map((plane,i)=>{
    const vertices:V[]=[];
    for(let j=0;j<planes.length;j++)for(let k=j+1;k<planes.length;k++){
      if(i===j||i===k)continue;
      const a=plane,b=planes[j],c=planes[k],bc=cross(b.n,c.n),den=dot(a.n,bc);
      if(Math.abs(den)<1e-8)continue;
      const v=mul(add(add(mul(bc,a.h),mul(cross(c.n,a.n),b.h)),mul(cross(a.n,b.n),c.h)),1/den);
      if(planes.some(p=>dot(p.n,v)>p.h+1e-7)||vertices.some(w=>length(sub(v,w))<1e-7))continue;
      vertices.push(v);
    }
    if(vertices.length<3)return {normal:plane.n,vertices:[]};
    const center=mul(vertices.reduce(add,[0,0,0] as V),1/vertices.length);
    const u=unit(sub(vertices[0],center)),v=cross(plane.n,u);
    vertices.sort((a,b)=>Math.atan2(dot(sub(a,center),v),dot(sub(a,center),u))-Math.atan2(dot(sub(b,center),v),dot(sub(b,center),u)));
    return {normal:plane.n,vertices};
  }).filter(f=>f.vertices.length>=3);
}
