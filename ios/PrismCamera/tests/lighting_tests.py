#!/usr/bin/env python3
"""Run production Metal highlight-compositing math as C++; no GPU claim."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "PrismCamera/Optics.metal").read_text()
function = source[source.index("float3 addFillWithHeadroom"):source.index("fragment float4 opticalFinish")]
cinematic = source[source.index("float3 cinematicReflection"):source.index("float4 opticalSample")]
cinematic = re.sub(r"float3\(([^()]*)\)", r"(float3){\1}", cinematic)
profile = source[source.index("float lightingProfile"):source.index("// Local diffuse enhancement")]
shim = r'''
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
using uint = unsigned;
using float2 = float __attribute__((ext_vector_type(2)));
using std::exp; using std::abs; using std::sqrt;
float clamp(float x,float lo,float hi) { return std::clamp(x,lo,hi); }
float dot(float2 a,float2 b) { return a.x*b.x+a.y*b.y; }
float smoothstep(float lo,float hi,float x) {
    float t=std::clamp((x-lo)/(hi-lo),0.f,1.f); return t*t*(3-2*t);
}
using float3 = float __attribute__((ext_vector_type(3)));
float dot(float3 a,float3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
float3 cross(float3 a,float3 b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
float3 normalize(float3 v) { return v/sqrt(dot(v,v)); }
float3 max(float3 a, float b) {
    return {std::max(a.x,b),std::max(a.y,b),std::max(a.z,b)};
}
float3 exp(float3 a) { return {std::exp(a.x),std::exp(a.y),std::exp(a.z)}; }
void require(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
'''
checks = r'''
int main() {
    for(int y=-10;y<=10;y++) for(int x=-10;x<=10;x++) {
        float3 direction=normalize((float3){x/10.f,y/10.f,1});
        for(auto axis : {(float3){0,1,0},normalize((float3){.5f,.5f,1})}) {
            auto light=cinematicReflection(direction,axis);
            for(int i=0;i<3;i++) require(std::isfinite(light[i]) && light[i]>=0 && light[i]<=12.001,"cinematic reflection lobes remain finite and bounded");
        }
    }
    for(uint style=0; style<5; ++style) {
        for(int y=-220;y<=220;y+=3) for(int x=-220;x<=220;x+=3) {
            float2 p={x/100.f,y/100.f};
            float value=lightingProfile(p,style);
            require(std::isfinite(value) && value>=0 && value<=1.00001f,"profiles are bounded and finite");
            require(std::abs(value-lightingProfile(-p,style))<1e-6,"modifier symmetry");
            require(std::abs(value-lightingProfile(p+(float2){.0001f,0},style))<.01f,"soft transitions without discontinuities");
        }
    }
    require(lightingProfile((float2){0,0},1)==1,"spot has a full center");
    require(lightingProfile((float2){1,0},1)==0,"spot has a bounded aperture");
    require(lightingProfile((float2){0,.5},2)>lightingProfile((float2){.5,0},2)*10,"strip is directional");
    require(lightingProfile((float2){0,0},3)==0 && lightingProfile((float2){.4,.4},3)>.9,"window has panes and mullions");
    require(lightingProfile((float2){.82,0},4)>.99 && lightingProfile((float2){0,0},4)<.001,"halo is a ring, not a spot");

    for (int b=0; b<=100; ++b) {
        float base=b/100.f;
        float3 color={base,base,base};
        require(addFillWithHeadroom(color,(float3){0,0,0}).x==base,"zero fill must be identity");
        require(addFillWithHeadroom(color,(float3){-1,-10,-.1f}).x==base,"negative fill cannot darken");
        float previous=base;
        for(int f=0; f<=100; ++f) {
            float gain=f/10.f;
            float result=addFillWithHeadroom(color,(float3){gain,gain,gain}).x;
            require(std::isfinite(result),"finite output across shadows and highlights");
            require(result>=previous,"increasing fill cannot decrease output");
            // The production finish pass clamps output; allow its .001 safety floor.
            require(result<=1.00101f,"headroom bounds highlight overshoot");
            previous=result;
        }
    }
    auto small=addFillWithHeadroom((float3){.2f,.4f,.6f},(float3){.0001f,.0001f,.0001f});
    require(std::abs(small.x-.2001f)<1e-6,"small signals preserve local contrast");
    auto colored=addFillWithHeadroom((float3){.2f,.4f,.6f},(float3){1,0,0});
    require(colored.y==.4f && colored.z==.6f,"tint does not leak between channels");
    std::puts("PASS: five production profiles, smoothness, bounds, fill identity, monotonicity and finite highlights");
}
'''
with tempfile.TemporaryDirectory(prefix="spectral-light-") as directory:
    path = Path(directory)
    (path / "test.cpp").write_text(shim + profile + cinematic + function + checks)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", str(path / "test.cpp"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
