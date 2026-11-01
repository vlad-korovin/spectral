#pragma once
#include <array>
#include <vector>
namespace hero {
struct V3 { float x=0,y=0,z=0; bool operator==(const V3&) const = default; };
V3 operator+(V3,V3); V3 operator-(V3,V3); V3 operator*(V3,float);
float dot(V3,V3); V3 normalized(V3);
using Transform=std::array<float,16>;
V3 point(const Transform&,V3); V3 vector(const Transform&,V3);
Transform inverseRigid(const Transform&);
// Same local vertices used by the raster mesh. Rigid transforms only.
inline constexpr std::array<V3,6> prismVertices={V3{-.9f,-.7f,.7f},V3{.9f,-.7f,.7f},V3{0,.9f,.7f},V3{-.9f,-.7f,-.7f},V3{.9f,-.7f,-.7f},V3{0,.9f,-.7f}};
struct Hit { float t=0; V3 normal; };
bool intersectPrism(V3 origin,V3 direction,Hit&);
bool refract(V3 direction,V3 opposingNormal,float eta,V3& transmitted);
float index(float wavelengthNm,float A,float B);
V3 xyzWeight(float wavelengthNm);
// The plane frame is the integration boundary for future tracked receivers.
// A depth/mesh receiver can replace intersect() without changing prism transport.
struct Receiver {
 bool operator==(const Receiver&) const = default;
 V3 origin{1.25f,-.85f,-5.2f}, u{1,0,0}, v{0,0,-1}, normal{0,1,0};
 float extent=10;
 bool intersect(V3,V3,V3&) const;
};
struct Settings {
 bool operator==(const Settings&) const = default;
 float A=1.5046f,B=.00420f,absorption=.025f,power=3;
 int wavelengths=31, apertureU=16,apertureV=64,maxBounces=8;
 V3 emitter{-4, .45f,-5.2f}, direction{1,0,0};
 float slitWidth=.055f, slitHeight=.8f;
};
struct Deposit { V3 position; V3 xyz; };
struct Stats { int launched=0,entered=0,escaped=0,tir=0,received=0,truncated=0; };
struct Result { std::vector<Deposit> deposits; Stats stats; V3 incidentEnd; bool incidentHit=false; };
Result transport(const Transform&,const Receiver&,const Settings&);
}
