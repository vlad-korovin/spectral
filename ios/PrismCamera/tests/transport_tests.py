#!/usr/bin/env python3
"""Compile the actual scalar transport functions from Optics.metal as C++.

This validates geometry and physics without an iPhone. It does NOT validate
Metal shader compilation, AR image registration, GPU performance, or appearance.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "PrismCamera/Optics.metal").read_text()
transport = source[source.index("float4 crystalPlane"):source.index("float3 spectralWeight")]
shim = r"""
#include <cmath>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
using uint = unsigned;
using std::abs; using std::sqrt; using std::floor;
inline float max(float a,float b) { return std::max(a,b); }
inline float clamp(float x,float a,float b) { return std::clamp(x,a,b); }
struct float3 {
    float x,y,z;
    float3(float v=0):x(v),y(v),z(v){}
    float3(float a,float b,float c):x(a),y(b),z(c){}
    float3 operator-() const { return {-x,-y,-z}; }
    float3 operator+(float3 b) const { return {x+b.x,y+b.y,z+b.z}; }
    float3 operator-(float3 b) const { return {x-b.x,y-b.y,z-b.z}; }
    float3 operator*(float b) const { return {x*b,y*b,z*b}; }
    float3& operator+=(float3 b) { *this=*this+b; return *this; }
};
struct float4 {
    float3 xyz; float w;
    float4(float x,float y,float z,float v):xyz(x,y,z),w(v){}
};
float dot(float3 a,float3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
float length(float3 a) { return sqrt(dot(a,a)); }
float3 normalize(float3 a) { return a*(1/length(a)); }
float3 reflect(float3 i,float3 n) { return i-n*(2*dot(n,i)); }
float3 refract(float3 i,float3 n,float eta) {
    float d=dot(n,i), k=1-eta*eta*(1-d*d);
    return k<0 ? float3(0) : i*eta-n*(eta*d+sqrt(k));
}
void require(bool v,const char* message) {
    if(!v) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
"""
checks = r"""
float3 rotateY(float3 p,float a) {
    return {std::cos(a)*p.x+std::sin(a)*p.z,p.y,-std::sin(a)*p.x+std::cos(a)*p.z};
}
float3 cross(float3 a,float3 b) {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};
}
float3 causticCentroid(float yaw, int& hits) {
    float3 d=normalize(float3(0.99,0.10,0.04));
    float3 tangent=normalize(cross(d,float3(0,1,0)));
    float3 bitangent=normalize(cross(tangent,d));
    float3 sum=0;
    hits=0;
    for(int y=0;y<16;y++) for(int x=0;x<24;x++) {
        float3 o=float3(0,0.075,0)-d*0.30+tangent*apertureCoordinate(y*24+x,0.754877666)*0.11
            +bitangent*apertureCoordinate(y*24+x,0.569840296)*0.08;
        require(o.y>0,"virtual aperture must stay above the receiver");
        auto p=traceGlass(rotateY(o,-yaw),rotateY(d,-yaw),refractiveIndex(550,1.5046,0.0042));
        if(!p.escaped) continue;
        float3 exit=rotateY(p.origin,yaw), out=rotateY(p.direction,yaw);
        float t=-exit.y/out.y;
        if(out.y<-0.001 && t>=0 && t<0.6) { sum+=exit+out*t; hits++; }
    }
    return hits ? sum*(1.0/hits) : sum;
}
int main() {
    int crystalExits=0, crystalTIR=0;
    for(int y=1;y<14;y++) for(int x=-7;x<=7;x++) {
        float3 o(x*0.01,y*0.01,0.4), d(0,0,-1);
        Interval entry=intersectGlass(o,d);
        auto path=traceGlassEntry(o,d,refractiveIndex(550,1.62,0.012),entry);
        if(path.escaped) {
            crystalExits++; crystalTIR+=path.bounces>0;
            require(path.throughput>=0 && path.throughput<=1,"cut crystal conserves transmission energy");
            require(path.length>0 && std::isfinite(path.length),"cut crystal has finite interior path");
            require(abs(length(path.direction)-1)<1e-4,"cut crystal outgoing direction normalized");
            require(!intersectGlass(path.origin,path.direction).hit,"cut crystal exit clears the solid");
        }
    }
    require(crystalExits>40 && crystalTIR>0,"cut crystal must refract and support internal reflection");
    std::printf("Cut crystal: %d exits, %d with internal reflection\n",crystalExits,crystalTIR);

    for(uint i=0;i<384;i++) {
        float a=apertureCoordinate(i,0.754877666), b=apertureCoordinate(i,0.569840296);
        require(a>=-0.5 && a<0.5 && b>=-0.5 && b<0.5,"aperture samples stay inside the emitter");
        require(a==apertureCoordinate(i,0.754877666),"aperture must not vary over time");
    }
    require(refractiveIndex(420,1.5046,0.0042)>refractiveIndex(680,1.5046,0.0042),
        "blue must refract more strongly than red");
    require(abs(fresnel(1,1,1.5)-0.04)<1e-5,"normal glass Fresnel must be 4 percent");
    require(fresnel(0.4,1.5,1)==1,"Fresnel must detect total internal reflection");
    auto miss=traceGlass({0.3,0.3,1},{0,0,-1},1.5);
    require(!miss.escaped,"ray missing solid must not transmit");
    auto normal=traceGlass({0,0.06,0.5},{0,0,-1},1.5);
    require(normal.escaped,"end-face ray must exit");
    require(normal.length>0.1 && normal.length<0.3,"cut crystal path length outside its closed bounds");
    require(abs(length(normal.direction)-1)<1e-5,"cut crystal exit direction not normalized");
    require(normal.throughput>0 && normal.throughput<=1,"cut crystal transmission energy outside bounds");
    int escaped=0, tir=0, receiverHits=0;
    float maxDispersion=0, maxRotation=0;
    for(int yi=0;yi<12;yi++) for(int zi=0;zi<7;zi++) for(int angle=-3;angle<=3;angle++) {
        float3 o(-0.35,0.02+yi*0.01,(zi-3)*0.009);
        float3 d=normalize(float3(1,angle*0.08,0));
        auto blue=traceGlass(o,d,refractiveIndex(420,1.5046,0.0042));
        auto red=traceGlass(o,d,refractiveIndex(680,1.5046,0.0042));
        if(blue.escaped) {
            escaped++;
            tir+=blue.bounces>0;
            require(std::isfinite(blue.throughput) && blue.throughput>=0 && blue.throughput<=1,
                "finite bounded transmitted energy");
            require(abs(length(blue.direction)-1)<1e-5,"outgoing direction normalized");
            if(blue.direction.y<0 && blue.origin.y>0) receiverHits++;
            if(red.escaped) maxDispersion=max(maxDispersion,length(blue.direction-red.direction));
            auto rotated=traceGlass(rotateY(o,-0.3),rotateY(d,-0.3),1.52);
            if(rotated.escaped) maxRotation=max(maxRotation,length(rotateY(rotated.direction,0.3)-blue.direction));
            for(uint i=0;i<18;i++) {
                float4 plane=crystalPlane(i);
                // Exit is on the surface or just beyond it, never deep inside the volume.
                require(dot(plane.xyz,blue.origin)-plane.w<0.0001,"exit lies on solid boundary");
            }
        }
        auto equalBlue=traceGlass(o,d,refractiveIndex(420,1.52,0));
        auto equalRed=traceGlass(o,d,refractiveIndex(680,1.52,0));
        require(length(equalBlue.direction-equalRed.direction)<1e-7,"zero Cauchy B eliminates dispersion");
    }
    require(escaped>50,"many side rays must exit");
    require(tir>0,"exercise TIR and subsequent escape");
    require(receiverHits>0,"exit rays must reach support plane");
    require(maxDispersion>0.01,"side refraction must produce continuous wavelength separation");
    require(maxRotation>0.01,"orientation must change optical response");
    int hits0=0,hits1=0;
    auto center0=causticCentroid(0,hits0), center1=causticCentroid(0.3,hits1);
    std::printf("Crystal receiver: %d / %d hits; orientation displacement %.5f m\n",hits0,hits1,length(center0-center1));
    require(hits0>10 && hits1>10,"configured lab emitter must produce a visible caustic");
    require(length(center0-center1)>0.002,"rotating lab glass must move the caustic on the fixed table");
    std::printf("PASS: thickness, Fresnel, TIR, energy, wavelength, rotation, receiver; %d exits, %d TIR exits, %d downward rays\n",
        escaped,tir,receiverHits);
}
"""
with tempfile.TemporaryDirectory(prefix="prism-transport-") as directory:
    path = Path(directory)
    (path / "test.cpp").write_text(shim + transport + checks)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", str(path / "test.cpp"),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
