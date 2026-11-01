#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 inverseViewProjection, viewProjection, worldToCamera, model, inverseModel, inverseProbe;
    float4 imageRow0, imageRow1, camera, flags, glass, light, receiver, viewport;
};
struct ScreenVertex { float4 position [[position]]; float2 uv; };
struct StudioLight { float4 sourceGain, targetRadius, colorSoftness, normalEnabled, shapeRight; };
vertex ScreenVertex fullscreen(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p};
}
constexpr sampler filtered(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
float3 linearize(float3 c) { return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045); }
float3 displayRGB(float3 c) { return select(12.92*c, 1.055*pow(max(c,0.0),float3(1.0/2.4))-0.055, c>0.0031308); }
float2 sensorUV(float2 uv, constant Uniforms& u) {
    return float2(dot(u.imageRow0.xyz,float3(uv,1)), dot(u.imageRow1.xyz,float3(uv,1)));
}
float3 cameraColor(float2 uv, constant Uniforms& u, texture2d<float> y, texture2d<float> cbcr) {
    float2 image = sensorUV(uv,u);
    float luma = y.sample(filtered,image).r;
    float2 chroma = cbcr.sample(filtered,image).rg - 0.5;
    return linearize(saturate(float3(luma+1.402*chroma.y,
        luma-0.344136*chroma.x-0.714136*chroma.y, luma+1.772*chroma.x)));
}
float4 crystalPlane(uint i) {
    if(i==16) return float4(0,-1,0,0);
    if(i==17) return float4(0,1,0,0.145);
    // Exact eightfold symmetry; avoid trig in every plane test of every spectral bounce.
    const float cs[8]={1,0.707106781,0,-0.707106781,-1,-0.707106781,0,0.707106781};
    const float sn[8]={0,0.707106781,1,0.707106781,0,-0.707106781,-1,-0.707106781};
    if(i<8) return float4(cs[i%8]*0.714142843,0.7,sn[i%8]*0.714142843,0.102772856);
    return float4(cs[i%8]*0.6,-0.8,sn[i%8]*0.6,0.01);
}
struct Interval { float enter, leave; float3 entryNormal, exitNormal; bool hit; };
Interval intersectGlass(float3 o, float3 d) {
    Interval r = {-1e10,1e10,float3(0),float3(0),true};
    for (uint i=0;i<18;i++) {
        float4 p=crystalPlane(i);
        float denominator=dot(p.xyz,d), distance=p.w-dot(p.xyz,o);
        if(abs(denominator)<1e-7) { if(distance<0) r.hit=false; continue; }
        float t=distance/denominator;
        if(denominator<0 && t>r.enter) { r.enter=t; r.entryNormal=p.xyz; }
        if(denominator>0 && t<r.leave) { r.leave=t; r.exitNormal=p.xyz; }
    }
    r.hit = r.hit && r.leave>max(r.enter,0.0);
    return r;
}
float refractiveIndex(float nm, float A, float B) { float um=nm*0.001; return A+B/(um*um); }
float fresnel(float cosine, float ni, float nt) {
    float c=clamp(cosine,0.0,1.0);
    float s2=(ni/nt)*(ni/nt)*(1-c*c);
    if(s2>=1) return 1;
    float ct=sqrt(1-s2);
    float rs=(ni*c-nt*ct)/max(ni*c+nt*ct,1e-6);
    float rp=(nt*c-ni*ct)/max(nt*c+ni*ct,1e-6);
    return 0.5*(rs*rs+rp*rp);
}
struct OpticalPath { float3 origin, direction; float throughput, length; uint bounces; bool escaped; };
OpticalPath traceGlassEntry(float3 origin, float3 direction, float index, Interval entry) {
    OpticalPath path={origin,direction,0,0,0,false};
    if(!entry.hit || entry.enter<0) return path;
    path.throughput=1-fresnel(-dot(direction,entry.entryNormal),1,index);
    path.direction=refract(direction,entry.entryNormal,1/index);
    path.origin=origin+direction*entry.enter+path.direction*0.00001;
    for(uint bounce=0;bounce<5;bounce++) {
        Interval inside=intersectGlass(path.origin,path.direction);
        if(!inside.hit || inside.leave<0) break;
        path.length+=inside.leave;
        path.origin+=path.direction*inside.leave;
        float3 transmitted=refract(path.direction,-inside.exitNormal,index);
        if(dot(transmitted,transmitted)>1e-8) {
            path.throughput*=1-fresnel(dot(path.direction,inside.exitNormal),index,1);
            path.direction=normalize(transmitted);
            path.origin+=path.direction*0.00001;
            path.escaped=true;
            return path;
        }
        path.direction=reflect(path.direction,inside.exitNormal);
        path.origin+=path.direction*0.00001;
        path.bounces++;
    }
    path.throughput=0; // Bounded work; never invent transmission for trapped paths.
    return path;
}
OpticalPath traceGlass(float3 origin, float3 direction, float index) {
    return traceGlassEntry(origin,direction,index,intersectGlass(origin,direction));
}
float apertureCoordinate(uint aperture, float step) {
    float value=0.5+float(aperture+1)*step;
    return value-floor(value)-0.5;
}
float3 spectralWeight(float wavelength) {
    // Positive display-primary response approximations, not three fixed ray paths.
    // Per-channel normalization preserves an achromatic scene under equal-energy light.
    float3 x=(float3(wavelength)-float3(610,545,455))/float3(39,32,25);
    return exp(-0.5*x*x);
}
float2 project(float3 p, constant Uniforms& u) {
    float4 clip=u.viewProjection*float4(p,1);
    if(clip.w<=0) return float2(-10);
    return (clip.xy/clip.w)*float2(0.5,-0.5)+0.5;
}
// Reconstruct registered depth once per sensor frame, guided by full-resolution luma.
// Packed inverse-depth/weight allows linear sampling without blending invalid depth sentinels.
kernel void buildDepthGuide(texture2d<float> raw [[texture(0)]], texture2d<float> confidence [[texture(1)]],
    texture2d<float> luma [[texture(2)]], texture2d<float, access::write> guide [[texture(3)]],
    uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=guide.get_width() || pixel.y>=guide.get_height()) return;
    float2 uv=(float2(pixel)+0.5)/float2(guide.get_width(),guide.get_height());
    float2 size=float2(raw.get_width(),raw.get_height());
    float2 location=uv*size-0.5;
    int2 base=int2(round(location));
    float center=luma.sample(filtered,uv).r;
    float weights[9], depths[9];
    float best=0, reference=0;
    uint k=0;
    for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++,k++) {
        int2 cell=clamp(base+int2(i,j),int2(0),int2(size)-1);
        float2 sampleUV=(float2(cell)+0.5)/size;
        float z=raw.read(uint2(cell)).r;
        float reliable=confidence.read(uint2(cell)).r*255;
        float color=luma.sample(filtered,sampleUV).r-center;
        float2 distance=float2(cell)-location;
        float w=exp(-dot(distance,distance)*0.7-color*color/0.0032);
        if(reliable<1 || !isfinite(z) || z<0.05 || z>15) w=0;
        weights[k]=w; depths[k]=z;
        if(w>best) { best=w; reference=z; }
    }
    float total=0, inverse=0;
    for(uint i=0;i<9;i++) {
        if(weights[i]>0 && abs(depths[i]-reference)<max(0.025,reference*0.015)) {
            total+=weights[i]; inverse+=weights[i]/depths[i];
        }
    }
    float support=smoothstep(0.015,0.12,total);
    guide.write(total>1e-6 ? float4(inverse/total*support,support,0,0) : float4(0),pixel);
}
float sensorDepth(float2 uv, constant Uniforms& u, texture2d<float> depth, texture2d<float> confidence) {
    if(u.flags.y<0.5 || any(uv<0) || any(uv>1)) return 100;
    float2 sample=depth.sample(filtered,sensorUV(uv,u)).rg;
    return sample.y>0.05 && sample.x>0 ? sample.y/sample.x : 100;
}
float3 environment(float3 d, constant Uniforms& u, texturecube<float> cube) {
    float3 local=(u.inverseProbe*float4(d,0)).xyz;
    return max(cube.sample(filtered,local,level(0)).rgb,0.0);
}
// Accept a screen-space crossing only when both endpoints observe the same surface.
// Otherwise silhouettes / missing depth used to create false hits and torn triangles.
float screenTrust(float2 uv) {
    float border=min(min(uv.x,uv.y),min(1-uv.x,1-uv.y));
    return smoothstep(0.015,0.09,border);
}
float3 sceneAlongRay(float3 origin, float3 direction, constant Uniforms& u,
    texture2d<float> y, texture2d<float> cbcr, texture2d<float> depth,
    texture2d<float> confidence, texturecube<float> cube) {
    float3 fallback=environment(direction,u,cube);
    float previous=-1, previousT=0.002, previousDepth=100;
    float t=0.008;
    for(uint i=0;i<16 && u.flags.y>0.5;i++,t*=1.48) {
        float3 p=origin+direction*t;
        float2 uv=project(p,u);
        if(any(uv<0.002) || any(uv>0.998)) break;
        float z=-(u.worldToCamera*float4(p,1)).z;
        float measured=sensorDepth(uv,u,depth,confidence);
        float delta=z-measured;
        if(measured<99 && previousDepth<99 && delta>=0 && previous<0 &&
           abs(measured-previousDepth)<0.06) {
            float low=previousT, high=t;
            for(uint j=0;j<5;j++) {
                float mid=(low+high)*0.5;
                float3 candidate=origin+direction*mid;
                float2 pixel=project(candidate,u);
                float difference=-(u.worldToCamera*float4(candidate,1)).z-sensorDepth(pixel,u,depth,confidence);
                if(difference>0) high=mid; else low=mid;
            }
            float3 candidate=origin+direction*((low+high)*0.5);
            float2 pixel=project(candidate,u);
            float error=abs(-(u.worldToCamera*float4(candidate,1)).z-sensorDepth(pixel,u,depth,confidence));
            float trust=screenTrust(pixel)*(1-smoothstep(0.015,0.05,error))
                *(1-smoothstep(0.025,0.06,abs(measured-previousDepth)));
            return mix(fallback,cameraColor(pixel,u,y,cbcr),trust);
        }
        previous=delta; previousT=t; previousDepth=measured;
    }
    float denominator=dot(u.receiver.xyz,direction);
    if(abs(denominator)>1e-5) {
        float t=-(dot(u.receiver.xyz,origin)+u.receiver.w)/denominator;
        if(t>0.001 && t<3) {
            float3 p=origin+direction*t;
            float2 uv=project(p,u);
            if(all(uv>0.01) && all(uv<0.99)) {
                float measured=sensorDepth(uv,u,depth,confidence);
                float predicted=-(u.worldToCamera*float4(p,1)).z;
                float trust=measured<99 ? 1-smoothstep(0.025,0.09,abs(measured-predicted)) : 0;
                return mix(fallback,cameraColor(uv,u,y,cbcr),trust*screenTrust(uv));
            }
        }
    }
    return fallback;
}
float3 worldRay(float2 uv, constant Uniforms& u) {
    float4 h=u.inverseViewProjection*float4(uv*float2(2,-2)+float2(-1,1),0.5,1);
    return normalize(h.xyz/h.w-u.camera.xyz);
}
// Two broad virtual studio reflections, blended only during the authored idle flight.
// These shape the crystal highlights, not room illumination or caustic source fitting.
float3 cinematicReflection(float3 direction, float3 axis) {
    float3 side=normalize(cross(abs(axis.y)>0.95 ? float3(1,0,0) : float3(0,1,0),axis));
    float3 rim=normalize(axis-side*1.8+float3(0,0.35,0));
    float keyLobe=exp(18*(clamp(dot(direction,axis),-1.0,1.0)-1));
    float rimLobe=exp(28*(clamp(dot(direction,rim),-1.0,1.0)-1));
    return float3(1,0.77,0.48)*(7*keyLobe)+float3(0.38,0.7,1)*(5*rimLobe);
}

float4 opticalSample(float2 uv, constant Uniforms& u,
    texture2d<float> y, texture2d<float> cbcr,
    texture2d<float> depth, texture2d<float> confidence, texturecube<float> cube, constant float4* spectrum) {
    float3 background=cameraColor(uv,u,y,cbcr);
    if(u.flags.x<0.5) return float4(0);
    float3 worldDirection=worldRay(uv,u);
    float3 origin=(u.inverseModel*u.camera).xyz;
    float3 direction=normalize((u.inverseModel*float4(worldDirection,0)).xyz);
    Interval entry=intersectGlass(origin,direction);
    if(!entry.hit || entry.enter<0) return float4(0);
    float3 worldEntry=(u.model*float4(origin+entry.enter*direction,1)).xyz;
    float z=-(u.worldToCamera*float4(worldEntry,1)).z;
    float measured=sensorDepth(uv,u,depth,confidence);
    float coverage=smoothstep(-0.005,0.015,measured-z);
    if(coverage<=0) return float4(0);

    float3 normal=normalize((u.model*float4(entry.entryNormal,0)).xyz);
    float3 reflected=sceneAlongRay(worldEntry+normal*0.001,reflect(worldDirection,normal),u,y,cbcr,depth,confidence,cube);
    if(u.light.w>0.001) reflected+=cinematicReflection(reflect(worldDirection,normal),normalize(u.light.xyz))*u.light.w;
    float3 sum=0;
    uint count=uint(u.flags.w);
    for(uint i=0;i<count;i++) {
        float index=spectrum[i].w;
        OpticalPath path=traceGlassEntry(origin,direction,index,entry);
        float3 color=0;
        if(path.escaped) {
            float3 exit=(u.model*float4(path.origin,1)).xyz;
            float3 outgoing=normalize((u.model*float4(path.direction,0)).xyz);
            color=sceneAlongRay(exit,outgoing,u,y,cbcr,depth,confidence,cube);
            color*=path.throughput*exp(-path.length*u.glass.z*0.35);
        }
        float entryF=fresnel(-dot(direction,entry.entryNormal),1,index);
        color+=reflected*entryF;
        sum+=color*spectrum[i].xyz;
    }
    float3 glass=sum;
    // Premultiplied optical difference. Camera pixels are reconstructed at native resolution later.
    return float4((glass-background)*coverage,coverage);
}

fragment float4 opticalComposite(ScreenVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]],
    constant float4* spectrum [[buffer(1)]],
    texture2d<float> y [[texture(0)]], texture2d<float> cbcr [[texture(1)]],
    texture2d<float> depth [[texture(2)]], texture2d<float> confidence [[texture(3)]],
    texturecube<float> cube [[texture(4)]]) {
    constexpr float2 offsets[4]={float2(-0.375,-0.125),float2(0.125,-0.375),
                                 float2(-0.125,0.375),float2(0.375,0.125)};
    float3 origin=(u.inverseModel*u.camera).xyz;
    uint hits=0;
    float3 normal=0;
    bool multipleFaces=false;
    for(uint i=0;i<4;i++) {
        float3 direction=normalize((u.inverseModel*float4(worldRay(in.uv+offsets[i]/u.viewport.xy,u),0)).xyz);
        Interval entry=intersectGlass(origin,direction);
        if(entry.hit && entry.enter>=0) {
            if(hits>0 && dot(normal,entry.entryNormal)<0.995) multipleFaces=true;
            normal=entry.entryNormal;
            hits++;
        }
    }
    if(hits==0) return float4(0);
    if(hits==4 && !multipleFaces) return opticalSample(in.uv,u,y,cbcr,depth,confidence,cube,spectrum);
    // Spend extra spectral rays only on silhouette/bevel/face boundaries, not the whole camera image.
    float4 result=0;
    for(uint i=0;i<4;i++) result+=opticalSample(in.uv+offsets[i]/u.viewport.xy,u,y,cbcr,depth,confidence,cube,spectrum);
    return result*0.25;
}

struct CausticVertex {
    float4 position [[position]];
    float2 corner;
    float3 energy;
    float3 world;
};
struct CausticSplat { float4 hitRadius; float4 energy; };
struct RoomLight { float4 directionSpread; float4 radiance; };
// Fit up to three bright upper-hemisphere regions of the measured probe. No synthetic fallback.
// This is image-based illumination, not calibrated lamp detection or lamp-position reconstruction.
kernel void buildRoomLights(constant Uniforms& u [[buffer(0)]], device RoomLight* lights [[buffer(1)]],
    texturecube<float> cube [[texture(0)]], uint id [[thread_position_in_grid]]) {
    if(id!=0) return;
    for(uint i=0;i<3;i++) lights[i]={float4(0),float4(0)};
    if(u.flags.z<0.5) return;
    float3 directions[96], colors[96];
    float brightness[96];
    float mean=0;
    for(uint i=0;i<96;i++) {
        float y=(float(i)+0.5)/96;
        float phi=float(i)*2.39996323;
        float radius=sqrt(1-y*y);
        directions[i]=float3(cos(phi)*radius,y,sin(phi)*radius);
        colors[i]=environment(directions[i],u,cube);
        brightness[i]=dot(colors[i],float3(0.2126,0.7152,0.0722));
        mean+=brightness[i]/96;
    }
    for(uint light=0;light<3;light++) {
        uint peak=0;
        for(uint i=1;i<96;i++) if(brightness[i]>brightness[peak]) peak=i;
        if(brightness[peak]<max(0.025,mean*1.5)) break;
        float3 axis=directions[peak], direction=0, energy=0;
        float weight=0, moment=0;
        for(uint i=0;i<96;i++) {
            float cosine=dot(axis,directions[i]);
            if(cosine>0.85 && brightness[i]>mean*1.1) {
                float w=brightness[i]-mean;
                direction+=directions[i]*w; weight+=w; moment+=(1-cosine)*w;
                energy+=colors[i]*(w/max(brightness[i],1e-5))*(6.2831853/96);
                brightness[i]=0;
            }
        }
        if(weight>1e-6) lights[light]={float4(-normalize(direction),clamp(sqrt(2*moment/weight),0.025,0.25)),float4(energy,1)};
    }
}

// This runs once per spectral ray instead of retracing the same path for all six quad vertices.
kernel void buildCaustics(constant Uniforms& u [[buffer(0)]],
    device CausticSplat* splats [[buffer(1)]], constant float4* spectrum [[buffer(2)]],
    device const RoomLight* lights [[buffer(3)]],
    texture2d<float> depth [[texture(0)]], texture2d<float> confidence [[texture(1)]],
    uint instance [[thread_position_in_grid]]) {
    splats[instance]={float4(0),float4(0)};
    uint wavelength=instance%25, aperture=instance/25;
    uint lightIndex=aperture%3;
    RoomLight light=lights[lightIndex];
    if(light.radiance.w<0.5) return;
    float3 axis=light.directionSpread.xyz;
    float3 axisT=normalize(cross(axis,abs(axis.y)>0.95 ? float3(1,0,0) : float3(0,1,0)));
    float3 axisB=cross(axis,axisT);
    float angle=float(aperture/3)*2.39996323;
    float spread=light.directionSpread.w*sqrt(fract(float(aperture/3+1)*0.618033989));
    float3 d=normalize(axis+spread*(cos(angle)*axisT+sin(angle)*axisB));
    float3 tangent=normalize(cross(d,abs(d.y)>0.95 ? float3(1,0,0) : float3(0,1,0)));
    float3 bitangent=normalize(cross(tangent,d));
    // A stable low-discrepancy aperture has no lattice and no frame-to-frame random shimmer.
    float2 sample=float2(apertureCoordinate(aperture,0.754877666),apertureCoordinate(aperture,0.569840296));
    float3 center=u.model[3].xyz+float3(0,0.075*u.glass.z,0);
    float3 o=center+(-d*0.40+tangent*sample.x*0.11+bitangent*sample.y*0.08)*u.glass.z;
    float3 localO=(u.inverseModel*float4(o,1)).xyz;
    float3 localD=normalize((u.inverseModel*float4(d,0)).xyz);
    Interval entry=intersectGlass(localO,localD);
    if(!entry.hit || entry.enter<0) return;
    float3 entryWorld=(u.model*float4(localO+entry.enter*localD,1)).xyz;
    float visibility=1;
    // Visible real geometry can interrupt the incoming virtual light, including a hand.
    // Never assume that geometry hidden from this camera has been reconstructed.
    for(uint j=0;j<12;j++) {
        float3 p=mix(o,entryWorld,(float(j)+0.5)/12);
        float2 uv=project(p,u);
        float measured=sensorDepth(uv,u,depth,confidence);
        float z=-(u.worldToCamera*float4(p,1)).z;
        float gap=z-measured;
        if(measured<99 && gap>0.008 && gap<0.08)
            visibility*=1-smoothstep(0.008,0.03,gap);
    }
    if(visibility<0.01) return;
    OpticalPath path=traceGlassEntry(localO,localD,spectrum[wavelength].w,entry);
    if(!path.escaped) return;
    float3 exit=(u.model*float4(path.origin,1)).xyz;
    float3 outgoing=normalize((u.model*float4(path.direction,0)).xyz);
    float denominator=dot(u.receiver.xyz,outgoing);
    if(denominator>=-0.001) return;
    float t=-(dot(u.receiver.xyz,exit)+u.receiver.w)/denominator;
    if(t<0 || t>0.6*u.glass.z) return;
    float3 hit=exit+outgoing*t;
    for(uint j=0;j<12;j++) {
        float3 p=mix(exit,hit,(float(j)+0.5)/12);
        float measured=sensorDepth(project(p,u),u,depth,confidence);
        float gap=-(u.worldToCamera*float4(p,1)).z-measured;
        if(measured<99 && gap>0.008 && gap<0.08)
            visibility*=1-smoothstep(0.008,0.03,gap);
    }
    // Overlapping finite footprints integrate the aperture; screen minimum keeps distant light stable.
    float4 clip=u.viewProjection*float4(hit,1);
    float worldPixel=2*max(clip.w,0.01)/(max(length(float3(u.viewProjection[0][1],u.viewProjection[1][1],u.viewProjection[2][1])),0.2)*u.viewport.y);
    float radius=max(0.007*u.glass.z+0.012*t,worldPixel*1.5);
    float area=(0.11*0.08*u.glass.z*u.glass.z)/128;
    // Integral of exp(-4r^2)-exp(-4) over the unit disk.
    float integral=3.14159265*radius*radius*(0.25-1.25*exp(-4.0));
    float3 energy=spectrum[wavelength].xyz * path.throughput * exp(-path.length*u.glass.z*0.35)
        * area/integral * light.radiance.xyz * visibility;
    splats[instance]={float4(hit,radius),float4(energy,1)};
}
vertex CausticVertex causticVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
    constant Uniforms& u [[buffer(0)]], device const CausticSplat* splats [[buffer(1)]]) {
    constexpr float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    CausticSplat splat=splats[instance];
    CausticVertex out={float4(2,2,2,1),corners[vertexID],splat.energy.xyz,float3(0)};
    if(splat.energy.w<0.5) return out;
    out.world=splat.hitRadius.xyz+float3(out.corner.x*splat.hitRadius.w,0.001,out.corner.y*splat.hitRadius.w);
    out.position=u.viewProjection*float4(out.world,1);
    return out;
}
fragment float4 causticFragment(CausticVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]],
    texture2d<float> y [[texture(0)]], texture2d<float> cbcr [[texture(1)]],
    texture2d<float> depth [[texture(2)]], texture2d<float> confidence [[texture(3)]]) {
    float2 uv=in.position.xy/u.viewport.xy;
    float z=-(u.worldToCamera*float4(in.world,1)).z;
    float measured=sensorDepth(uv,u,depth,confidence);
    // No projection through real foreground objects, or onto a different measured surface.
    if(measured>99) discard_fragment();
    float agreement=1-smoothstep(0.015,0.045,abs(measured-z));
    if(agreement<=0) discard_fragment();
    float3 o=(u.inverseModel*u.camera).xyz;
    float3 target=(u.inverseModel*float4(in.world,1)).xyz;
    Interval glass=intersectGlass(o,normalize(target-o));
    if(glass.hit && glass.enter>0 && glass.enter<length(target-o)-0.002) discard_fragment();
    float falloff=max(0.0,exp(-4*dot(in.corner,in.corner))-exp(-4.0))*agreement;
    float3 receiver=cameraColor(uv,u,y,cbcr);
    float3 energy=in.energy*falloff*sqrt(max(receiver,float3(0.015)));
    return float4(energy, min(1.0,length(energy)));
}
// Axial depth must be divided by the camera-space ray Z, never treated as ray length.
float3 surfacePoint(float2 uv, float z, constant Uniforms& u) {
    float3 ray=worldRay(uv,u);
    float axial=-(u.worldToCamera*float4(ray,0)).z;
    return u.camera.xyz+ray*(z/max(axial,0.001));
}

// Analytic light modifiers: bounded, smooth profiles, no texture or extra render pass.
// Coordinates are in the source's target plane, divided by the chosen radius.
float lightingProfile(float2 p, uint style) {
    float r2=dot(p,p);
    if(style==1) return 1-smoothstep(0.65,1.0,sqrt(r2)); // feathered spot
    if(style==2) { // narrow vertical strip, long axis feathered separately
        float x=p.x/0.24;
        return exp(-2*x*x)*(1-smoothstep(0.65,1.65,abs(p.y)))*(1-smoothstep(0.7,1.0,abs(p.x)));
    }
    if(style==3) { // window aperture; smooth edges and mullions
        float edge=(1-smoothstep(0.78,1.0,abs(p.x)))*(1-smoothstep(1.1,1.4,abs(p.y)));
        float panes=smoothstep(0.035,0.10,abs(p.x))*smoothstep(0.035,0.10,abs(p.y));
        return edge*panes;
    }
    if(style==4) { // backdrop halo; not a subject mask or simulated rim light
        float ring=(sqrt(r2)-0.82)/0.22;
        return exp(-2*ring*ring)*(1-smoothstep(1.25,1.5,sqrt(r2)));
    }
    return exp(-2*r2)*(1-smoothstep(1.5,2.0,sqrt(r2)));
}

// Local diffuse enhancement of an already-lit photograph. No inferred albedo,
// removal of existing shadows, or off-screen occluders are claimed here.
float3 surfaceFill(float2 uv, float3 base, constant Uniforms& u, constant StudioLight& light,
                   texture2d<float> depth, texture2d<float> confidence) {
    if(light.normalEnabled.w<0.5 || light.sourceGain.w<=0 || u.flags.y<0.5) return float3(0);
    float z=sensorDepth(uv,u,depth,confidence);
    if(z>=99) return float3(0);
    float3 p=surfacePoint(uv,z,u), offset=p-light.targetRadius.xyz;
    float radius=max(light.targetRadius.w,0.06);
    float normalizedDistance=length(offset)/radius;
    if(normalizedDistance>=2) return float3(0);
    uint style=uint(clamp(light.shapeRight.w,0.0,4.0));
    float profile;
    if(style==0) { // Preserve the original isotropic soft-fill footprint.
        profile=lightingProfile(float2(normalizedDistance,0),style);
    } else {
        float3 axis=normalize(light.targetRadius.xyz-light.sourceGain.xyz);
        float3 up=normalize(cross(light.shapeRight.xyz,axis));
        float3 sourceToPoint=p-light.sourceGain.xyz;
        float axial=dot(sourceToPoint,axis);
        if(axial<=0.01) return float3(0);
        // Project an aperture onto the measured surface; oblique planes stretch naturally.
        float projection=length(light.targetRadius.xyz-light.sourceGain.xyz)/axial;
        float2 aperture=float2(dot(sourceToPoint,light.shapeRight.xyz),dot(sourceToPoint,up))*projection/radius;
        profile=lightingProfile(aperture,style)*(1-smoothstep(1.65,2.0,normalizedDistance));
    }
    if(profile<=0.0001) return float3(0);
    // Derivatives span approximately one raw LiDAR pixel, not one RGB pixel.
    float2 step=float2(1.0/256.0);
    float zl=sensorDepth(uv-float2(step.x,0),u,depth,confidence);
    float zr=sensorDepth(uv+float2(step.x,0),u,depth,confidence);
    float zu=sensorDepth(uv-float2(0,step.y),u,depth,confidence);
    float zd=sensorDepth(uv+float2(0,step.y),u,depth,confidence);
    bool useLeft=abs(zl-z)<abs(zr-z), useUp=abs(zu-z)<abs(zd-z);
    float zx=useLeft?zl:zr, zy=useUp?zu:zd;
    float discontinuity=max(abs(zx-z),abs(zy-z));
    float trust=1-smoothstep(max(0.015,z*0.01),max(0.04,z*0.03),discontinuity);
    if(trust<=0 || zx>=99 || zy>=99) return float3(0);
    float sx=useLeft?-step.x:step.x, sy=useUp?-step.y:step.y;
    float3 dx=(surfacePoint(uv+float2(sx,0),zx,u)-p)/sx;
    float3 dy=(surfacePoint(uv+float2(0,sy),zy,u)-p)/sy;
    float3 n=cross(dx,dy);
    if(dot(n,n)<1e-12) return float3(0);
    n=normalize(n);
    if(dot(n,u.camera.xyz-p)<0) n=-n;
    float3 toLight=light.sourceGain.xyz-p;
    float d2=dot(toLight,toLight);
    if(d2<0.0025) return float3(0);
    float cosine=max(0.0,dot(n,toLight*rsqrt(d2)));
    if(cosine<=0) return float3(0);
    float visibility=1;
    // Bounded, conservative visible-geometry shadow probes. Unknown space adds no shadow.
    for(uint i=0;i<6;i++) {
        float3 q=p+n*0.015+toLight*((float(i)+1)/7);
        float2 pixel=project(q,u);
        float measured=sensorDepth(pixel,u,depth,confidence);
        float gap=-(u.worldToCamera*float4(q,1)).z-measured;
        if(measured<99 && gap>0.015 && gap<0.06) visibility*=1-smoothstep(0.015,0.04,gap);
    }
    float3 reference=light.sourceGain.xyz-light.targetRadius.xyz;
    float attenuation=min(2.0,dot(reference,reference)/d2);
    float feather=profile;
    return max(base,0.0)*light.colorSoftness.xyz*(light.sourceGain.w*cosine*attenuation*feather*trust*visibility);
}

float3 addFillWithHeadroom(float3 base, float3 fill) {
    float3 headroom=max(1-base,0.001);
    return base+headroom*(1-exp(-max(fill,0.0)/headroom));
}

fragment float4 opticalFinish(ScreenVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]],
    constant StudioLight& light [[buffer(2)]],
    texture2d<float> scene [[texture(0)]], texture2d<float> y [[texture(1)]], texture2d<float> cbcr [[texture(2)]],
    texture2d<float> depth [[texture(3)]], texture2d<float> confidence [[texture(4)]]) {
    float3 background=cameraColor(in.uv,u,y,cbcr);
    if(u.viewport.z>0.5) return float4(displayRGB(background),1);
    if(u.viewport.w>0.5) {
        float z=sensorDepth(in.uv,u,depth,confidence);
        if(z>99) return float4(displayRGB(background)*0.25,1);
        float t=saturate((z-0.2)/2.8);
        float3 color=t<0.5 ? mix(float3(0.05,0.15,0.8),float3(0.05,0.9,0.7),t*2)
                            : mix(float3(0.05,0.9,0.7),float3(1,0.85,0.1),(t-0.5)*2);
        return float4(color,1);
    }
    float3 fill=surfaceFill(in.uv,background,u,light,depth,confidence);
    // Light-only shots bypass all spectral compositing texture reads.
    if(u.flags.x<0.5) return float4(saturate(displayRGB(addFillWithHeadroom(background,fill))),1);
    float2 texel=1/float2(scene.get_width(),scene.get_height());
    float4 c=scene.sample(filtered,in.uv);
    float4 n=scene.sample(filtered,in.uv+float2(0,-1)*texel);
    float4 s=scene.sample(filtered,in.uv+float2(0,1)*texel);
    float4 e=scene.sample(filtered,in.uv+float2(1,0)*texel);
    float4 w=scene.sample(filtered,in.uv+float2(-1,0)*texel);
    float mask=max(c.a,max(max(n.a,s.a),max(e.a,w.a)));
    float3 difference=c.rgb;
    if(mask>0.001) {
        float3 luma=float3(0.2126,0.7152,0.0722);
        float lo=min(dot(c.rgb,luma),min(min(dot(n.rgb,luma),dot(s.rgb,luma)),min(dot(e.rgb,luma),dot(w.rgb,luma))));
        float hi=max(dot(c.rgb,luma),max(max(dot(n.rgb,luma),dot(s.rgb,luma)),max(dot(e.rgb,luma),dot(w.rgb,luma))));
        float edge=smoothstep(0.04,0.25,(hi-lo)/max(hi,0.1));
        difference=mix(difference,(n.rgb+s.rgb+e.rgb+w.rgb+4*c.rgb)/8,edge*0.4);
        // A local HDR bright pass affects virtual highlights only; camera whites stay unchanged.
        difference+=(0.06+0.10*u.light.w)*(max(n.rgb-0.8,0.0)*n.a+max(s.rgb-0.8,0.0)*s.a+max(e.rgb-0.8,0.0)*e.a+max(w.rgb-0.8,0.0)*w.a);
    }
    float3 result=max(background+difference,0.0);
    result=addFillWithHeadroom(result,fill*(1-saturate(c.a)));
    float peak=max(result.r,max(result.g,result.b));
    if(peak>1) result/=peak;
    return float4(saturate(displayRGB(result)),1);
}

// The host test runner invokes the production transport, not a second CPU implementation.
struct TestRay { float4 origin, direction, glass; };
struct TestResult { float4 exitPoint, outgoing, metrics; };
kernel void testTransport(device const TestRay* input [[buffer(0)]], device TestResult* output [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
    TestRay r=input[id];
    OpticalPath p=traceGlass(r.origin.xyz,normalize(r.direction.xyz),refractiveIndex(r.glass.x,r.glass.y,r.glass.z));
    output[id]={float4(p.origin,p.escaped?1:0),float4(p.direction,p.throughput),float4(p.length,p.bounces,0,0)};
}
