#include "SpectralTransport.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
namespace hero {
V3 operator+(V3 a,V3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
V3 operator-(V3 a,V3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
V3 operator*(V3 a,float b){return {a.x*b,a.y*b,a.z*b};}
float dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
V3 normalized(V3 a){float l=std::sqrt(dot(a,a));return l>1e-8f?a*(1/l):V3{};}
static V3 cross(V3 a,V3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
V3 vector(const Transform&m,V3 p){return {m[0]*p.x+m[4]*p.y+m[8]*p.z,m[1]*p.x+m[5]*p.y+m[9]*p.z,m[2]*p.x+m[6]*p.y+m[10]*p.z};}
V3 point(const Transform&m,V3 p){return vector(m,p)+V3{m[12],m[13],m[14]};}
Transform inverseRigid(const Transform&m){Transform r={m[0],m[4],m[8],0,m[1],m[5],m[9],0,m[2],m[6],m[10],0,0,0,0,1};V3 p=vector(r,{-m[12],-m[13],-m[14]});r[12]=p.x;r[13]=p.y;r[14]=p.z;return r;}
// Convex half-space clipping: five exact planes, outward unit normals.
bool intersectPrism(V3 o,V3 d,Hit& hit){
 const V3 normals[]={{0,0,1},{0,0,-1},{0,-1,0},normalized({-1.6f,.9f,0}),normalized({1.6f,.9f,0})};
 const float distances[]={.7f,.7f,.7f,.81f/std::sqrt(3.37f),.81f/std::sqrt(3.37f)};
 float enter=-1e30f,exit=1e30f;V3 en{},ex{};
 for(int i=0;i<5;++i){float a=dot(normals[i],d),b=distances[i]-dot(normals[i],o);
  if(std::abs(a)<1e-7f){if(b<0)return false;continue;}
  float t=b/a;if(a<0){if(t>enter){enter=t;en=normals[i];}}else if(t<exit){exit=t;ex=normals[i];}
  if(enter>exit)return false;
 }
 if(enter>1e-5f){hit={enter,en};return true;}if(exit>1e-5f){hit={exit,ex};return true;}return false;
}
bool refract(V3 d,V3 n,float eta,V3& t){float c=-dot(n,d),k=1-eta*eta*(1-c*c);if(k<0)return false;t=normalized(d*eta+n*(eta*c-std::sqrt(k)));return true;}
float index(float nm,float A,float B){float um=nm*.001f;return A+B/(um*um);}
// Analytic CIE 1931 matching-function fit (Wyman/Sloan/Shirley).
// https://jcgt.org/published/0002/02/01/
V3 xyzWeight(float w){auto g=[w](float m,float a,float b){float t=(w-m)*(w<m?a:b);return std::exp(-.5f*t*t);};return {1.056f*g(599.8f,.0264f,.0323f)+.362f*g(442,.0624f,.0374f)-.065f*g(501.1f,.049f,.0382f),.821f*g(568.8f,.0213f,.0247f)+.286f*g(530.9f,.0613f,.0322f),1.217f*g(437,.0845f,.0278f)+.681f*g(459,.0385f,.0725f)};}
static float fresnel(float c,float n1,float n2){c=std::clamp(c,0.f,1.f);float s=n1/n2*std::sqrt(std::max(0.f,1-c*c));if(s>=1)return 1;float ct=std::sqrt(1-s*s);float rs=(n1*c-n2*ct)/(n1*c+n2*ct),rp=(n2*c-n1*ct)/(n2*c+n1*ct);return .5f*(rs*rs+rp*rp);}
bool Receiver::intersect(V3 o,V3 d,V3& p) const {float den=dot(normal,d);if(den>=-1e-6f)return false;float t=dot(origin-o,normal)/den;if(t<=1e-4f)return false;p=o+d*t;V3 q=p-origin;return std::abs(dot(q,u))<extent&&std::abs(dot(q,v))<extent;}
Result transport(const Transform&m,const Receiver& receiver,const Settings&s){
 Result r;const auto inv=inverseRigid(m);V3 worldD=normalized(s.direction),d=normalized(vector(inv,worldD));
 V3 apertureU=normalized(cross(worldD,{0,0,1})),apertureV=normalized(cross(worldD,apertureU));
 Hit central;if(intersectPrism(point(inv,s.emitter),d,central)){r.incidentHit=true;r.incidentEnd=s.emitter+worldD*central.t;}else r.incidentEnd=s.emitter+worldD*12;
 int nw=std::clamp(s.wavelengths,24,31),nu=std::max(s.apertureU,1),nv=std::max(s.apertureV,1);
 float norm=0;for(int w=0;w<nw;++w)norm+=xyzWeight(420+260.f*w/(nw-1)).y;
 r.deposits.reserve(nu*nv*nw);
 for(int y=0;y<nv;++y)for(int x=0;x<nu;++x){
  V3 start=s.emitter+apertureU*(((x+.5f)/nu-.5f)*s.slitWidth)+apertureV*(((y+.5f)/nv-.5f)*s.slitHeight);
  V3 o=point(inv,start);Hit entry;bool entered=intersectPrism(o,d,entry)&&dot(d,entry.normal)<0;
  for(int w=0;w<nw;++w){++r.stats.launched;if(!entered)continue;++r.stats.entered;
   float nm=420+260.f*w/(nw-1),n=index(nm,s.A,s.B);V3 dir;
   if(!refract(d,entry.normal,1/n,dir))continue;
   float energy=s.power/(nu*nv*norm)*(1-fresnel(-dot(d,entry.normal),1,n));
   V3 p=o+d*entry.t+dir*1e-4f;bool escaped=false;
   for(int bounce=0;bounce<s.maxBounces;++bounce){Hit h;if(!intersectPrism(p,dir,h))break;p=p+dir*h.t;energy*=std::exp(-std::max(0.f,s.absorption)*h.t);
    V3 next;if(refract(dir,h.normal*-1,n,next)){
     energy*=1-fresnel(dot(dir,h.normal),n,1);++r.stats.escaped;escaped=true;
     V3 world=point(m,p),out=normalized(vector(m,next)),received;
     // Reject a ray that re-enters the convex prism only by numerical contact.
     if(receiver.intersect(world+out*1e-4f,out,received)){r.deposits.push_back({received,xyzWeight(nm)*energy});++r.stats.received;}break;
    }
    ++r.stats.tir;dir=normalized(dir-h.normal*(2*dot(dir,h.normal)));p=p+dir*1e-4f;
   }
   if(!escaped)++r.stats.truncated;
  }
 }
 return r;
}
}
