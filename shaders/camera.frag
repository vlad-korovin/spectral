#version 330 core
in vec2 vUV;
out vec4 fragColor;
uniform sampler2D uColor,uDepth,uMask,uCaustic;
uniform int uHasDepth,uHasMask;
uniform int uSynthetic;
uniform float uTime;
uniform vec4 uIntrinsics;
uniform vec2 uImageSize;
uniform mat4 uProjection,uCameraToWorld;
uniform vec3 uOrigin,uAxisU,uAxisV,uNormal;
uniform float uExtent;
void main(){
    vec2 imageUV=vec2(vUV.x,1-vUV.y);
    vec3 color=texture(uColor,imageUV).rgb;
    float depth=uHasDepth!=0?texture(uDepth,imageUV).r:0.;
    if(uSynthetic!=0){
        vec2 pixel=floor(imageUV*uImageSize)+.5;
        vec3 cameraRay=vec3((pixel.x-uIntrinsics.z)/uIntrinsics.x,
                            -(pixel.y-uIntrinsics.w)/uIntrinsics.y,-1);
        vec3 worldOrigin=(uCameraToWorld*vec4(0,0,0,1)).xyz;
        vec3 worldRay=(uCameraToWorld*vec4(cameraRay,0)).xyz;
        float floorHit=worldRay.y<-.0001?(-.85-worldOrigin.y)/worldRay.y:1e6;
        if(floorHit<=0)floorHit=1e6;
        vec3 sphereCenter=vec3(1.25+1.6*sin(uTime*.7),.05,-3.5);
        vec3 delta=worldOrigin-sphereCenter;
        float a=dot(worldRay,worldRay),b=dot(worldRay,delta),c=dot(delta,delta)-.3025;
        float discriminant=b*b-a*c;
        float sphereHit=discriminant>=0?(-b-sqrt(discriminant))/a:-1;
        bool foreground=sphereHit>0&&sphereHit<floorHit;
        float hit=foreground?sphereHit:floorHit;
        depth=hit<100?hit:0;
        if(foreground)color=vec3(.86,.15,.025);
        else if(hit<100){
            vec3 p=worldOrigin+worldRay*hit;
            // Analytic footprint filtering is the procedural equivalent of a
            // trilinear mip lookup and stays stable at grazing camera angles.
            float wave=sin(3.14159265*p.x)*sin(3.14159265*p.z);
            float footprint=max(fwidth(wave),.0001);
            float checker=smoothstep(-footprint,footprint,wave);
            color=mix(vec3(.60),vec3(.38),checker);
        }else color=vec3(.10,.14,.20);
    }
    bool valid=depth>0 && !isnan(depth) && !isinf(depth);
    if(uHasMask!=0)valid=valid && texture(uMask,imageUV).r>=.5;
    gl_FragDepth=1.;
    if(valid){
        // Reconstruct at the depth texel center; no interpolation across foreground edges.
        vec2 pixel=floor(imageUV*uImageSize)+.5;
        vec3 camera=vec3((pixel.x-uIntrinsics.z)/uIntrinsics.x,
                         -(pixel.y-uIntrinsics.w)/uIntrinsics.y,-1)*depth;
        vec4 clip=uProjection*vec4(camera,1);
        float ndc=clip.z/clip.w;
        if(ndc>=-1 && ndc<=1){
            gl_FragDepth=ndc*.5+.5;
            vec3 world=(uCameraToWorld*vec4(camera,1)).xyz,q=world-uOrigin;
            vec2 causticUV=vec2(dot(q,uAxisU),dot(q,uAxisV))/(2*uExtent)+.5;
            // Current optical receiver is planar. Reject other observed geometry.
            if(abs(dot(q,uNormal))<.035 && all(greaterThan(causticUV,vec2(0))) && all(lessThan(causticUV,vec2(1)))){
                vec3 xyz=texture(uCaustic,causticUV).rgb;
                vec3 energy=vec3(dot(xyz,vec3(3.2406,-1.5372,-.4986)),dot(xyz,vec3(-.9689,1.8758,.0415)),dot(xyz,vec3(.0557,-.2040,1.0570)));
                color+=max(energy,0)*color/3.14159265;
            }
        }
    }
    fragColor=vec4(color,1);
}
