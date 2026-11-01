#version 330 core
out vec4 fragColor;
uniform sampler2D uDepth;
uniform vec2 uResolution;
uniform vec3 uCamera,uForward,uRight,uUp,uEmitter,uDirection,uBeamU,uBeamV;
uniform vec2 uSlit;
uniform mat4 uPrismInverse;
uniform float uTanHalfFov,uNear,uFar,uPower;
uniform vec4 uIntrinsics;
uniform vec2 uCameraImageSize;
float entryDistance(vec3 origin,vec3 direction){
 vec3 o=(uPrismInverse*vec4(origin,1)).xyz,d=(uPrismInverse*vec4(direction,0)).xyz;
 vec3 ns[5]=vec3[5](vec3(0,0,1),vec3(0,0,-1),vec3(0,-1,0),normalize(vec3(-1.6,.9,0)),normalize(vec3(1.6,.9,0)));
 float ds[5]=float[5](.7,.7,.7,.81/sqrt(3.37),.81/sqrt(3.37));float a=0,b=12;
 for(int i=0;i<5;++i){float den=dot(ns[i],d),num=ds[i]-dot(ns[i],o);if(abs(den)<1e-6){if(num<0)return 12.;}else{float t=num/den;if(den<0)a=max(a,t);else b=min(b,t);}}
 return b>a?a:12.;
}
void main(){
 vec2 uv=gl_FragCoord.xy/uResolution,ndc=uv*2-1;
 vec3 ray=normalize(uForward+uRight*ndc.x*(uResolution.x/uResolution.y)*uTanHalfFov+uUp*ndc.y*uTanHalfFov);
 if(uIntrinsics.x>0){
  vec2 pixel=vec2(uv.x,1-uv.y)*uCameraImageSize;
  ray=normalize(uForward+uRight*(pixel.x-uIntrinsics.z)/uIntrinsics.x-uUp*(pixel.y-uIntrinsics.w)/uIntrinsics.y);
 }
 vec3 q=uCamera-uEmitter;
 vec3 o=vec3(dot(q,uDirection),dot(q,uBeamU),dot(q,uBeamV));
 vec3 d=vec3(dot(ray,uDirection),dot(ray,uBeamU),dot(ray,uBeamV));
 vec3 lo=vec3(0,-uSlit*.5),hi=vec3(12,uSlit*.5);
 float first=0,last=100;
 for(int i=0;i<3;++i){if(abs(d[i])<1e-7){if(o[i]<lo[i]||o[i]>hi[i])discard;}else{float a=(lo[i]-o[i])/d[i],b=(hi[i]-o[i])/d[i];first=max(first,min(a,b));last=min(last,max(a,b));}}
 float depth=texture(uDepth,uv).r;
 float z=2*uNear*uFar/(uFar+uNear-(depth*2-1)*(uFar-uNear));
 last=min(last,z/max(dot(ray,uForward),.001));if(last<=first)discard;
 float stepLength=(last-first)/24,scatter=0;
 for(int i=0;i<24;++i){vec3 p=o+d*(first+(float(i)+.5)*stepLength);
  vec3 source=uEmitter+uBeamU*p.y+uBeamV*p.z;
  if(p.x<entryDistance(source,uDirection)){
   vec2 aperture=p.yz/(uSlit*.5);scatter+=exp(-2*dot(aperture,aperture))*stepLength;
  }
 }
 // Deliberate low-density single-scattering approximation. White until entry, no RGB geometry.
 fragColor=vec4(vec3(1,.985,.96)*scatter*uPower*.10,0);
}
