#include "SpectralTransport.hpp"
#include "Scene.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <chrono>
using namespace hero;
void check(bool b,const char*m){if(!b)throw std::runtime_error(m);}
Transform model(float yaw){float c=std::cos(yaw),s=std::sin(yaw);return {c,0,-s,0,0,1,0,0,s,0,c,0,1.25f,-.15f,-5.2f,1};}
int main(){
 check(buildScene(ScenePreset::HeroLab).prisms.size()==1,"Hero scene changed unexpectedly");
 Hit h;check(intersectPrism({-3,0,0},{1,0,0},h),"entry miss");check(std::abs(h.t-2.49375f)<1e-4f,"wrong sloping plane");
 check(!intersectPrism({-3,2,0},{1,0,0},h),"false parallel hit");
 check(intersectPrism({0,0,0},{0,0,1},h)&&std::abs(h.t-.7f)<1e-5,"inside exit");
 V3 t;check(refract({0,-1,0},{0,1,0},1/1.5f,t)&&std::abs(t.y+1)<1e-6,"normal refraction");
 check(!refract(normalized({.9f,.43589f,0}),{0,-1,0},1.5f,t),"missing TIR");
 check(index(420,1.5046,.0042)>index(680,1.5046,.0042),"dispersion reversed");
 Receiver recv;V3 p;check(!recv.intersect({0,0,0},{0,1,0},p),"backward receiver");
 auto m=model(.10);V3 q={.4f,.3f,.2f};auto rt=point(inverseRigid(m),point(m,q));check(dot(rt-q,rt-q)<1e-10,"transform round trip");
 Settings s;auto a=transport(m,recv,s);auto b=transport(model(.20),recv,s);
 std::cout<<"hits "<<a.stats.received<<" / "<<b.stats.received<<", TIR "<<a.stats.tir<<"\n";
 check(a.stats.received>100&&b.stats.received>100,"default beam misses receiver");
 auto centroid=[](const Result&r){V3 c{};float w=0;for(auto d:r.deposits){c=c+d.position*d.xyz.y;w+=d.xyz.y;}return c*(1/w);};
 auto diff=centroid(a)-centroid(b);check(dot(diff,diff)>1e-4,"rotation does not move caustic");
 for(auto d:a.deposits){check(std::isfinite(d.xyz.x)&&d.xyz.y>=0,"invalid energy");check(std::abs(d.position.y-recv.origin.y)<1e-4,"deposit off plane");}
 s.B=0;auto ach=transport(m,recv,s);check(ach.deposits.size()>=31,"achromatic empty");for(int i=1;i<31;++i){auto delta=ach.deposits[i].position-ach.deposits[0].position;check(dot(delta,delta)<1e-10,"zero dispersion separates rays");}

 auto energy=[](const Result&r){double total=0;for(auto d:r.deposits)total+=d.xyz.y;return total;};
 s.B=.0042f;auto baseline=transport(m,recv,s);double e=energy(baseline);
 check(e>0&&e<=s.power,"nonconserving power");
 s.apertureU=32;s.apertureV=128;auto denser=transport(m,recv,s);
 check(std::abs(energy(denser)/e-1)<.015,"brightness depends on aperture sample count");
 s.wavelengths=24;auto fewer=transport(m,recv,s);
 check(std::abs(energy(fewer)/e-1)<.025,"brightness depends on wavelength count");
 s.absorption=4;check(energy(transport(m,recv,s))<e*.6,"absorption fails to attenuate");
 s=Settings{};auto tirPaths=transport(model(.25f),recv,s);
 check(tirPaths.stats.tir>0&&tirPaths.stats.received>0,"internal reflection transport path untested");
 auto close=transport(model(.101f),recv,s);
 auto shift=centroid(close)-centroid(baseline);check(dot(shift,shift)<.001,"rotation discontinuity away from boundary");
 // All points on every supported orientation remain above the receiver.
 for(float angle=-3.1f;angle<3.2f;angle+=.1f)for(auto v:prismVertices)
  check(point(model(angle),v).y>=recv.origin.y-1e-5,"prism penetrates table");
 auto start=std::chrono::steady_clock::now();for(int i=0;i<30;++i)(void)transport(model(.10f+i*.001f),recv,s);
 auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()/30;
 std::cout<<"CPU transport average: "<<ms<<" ms (31 wavelengths, 1024 aperture rays)\n";
 std::cout<<"All transport tests passed\n";
}
