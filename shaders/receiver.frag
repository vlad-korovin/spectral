#version 330 core
in vec3 vWorld;
in vec2 vUV;
out vec4 fragColor;
uniform sampler2D uCaustic,uAlbedo,uNormalMap,uRoughness,uEnvironment,uShadow;
uniform vec3 uOrigin,uAxisU,uAxisV,uNormal,uCamera,uEmitter;
uniform mat4 uPrismInverse;
const float PI=3.14159265;
vec3 environment(vec3 d){d=normalize(d);return texture(uEnvironment,vec2(atan(d.z,d.x)/(2*PI)+.5,.5-asin(clamp(d.y,-1,1))/PI)).rgb;}
float blocked(vec3 o,vec3 d){o=(uPrismInverse*vec4(o,1)).xyz;d=(uPrismInverse*vec4(d,0)).xyz;
 vec3 ns[5]=vec3[5](vec3(0,0,1),vec3(0,0,-1),vec3(0,-1,0),normalize(vec3(-1.6,.9,0)),normalize(vec3(1.6,.9,0)));
 float ds[5]=float[5](.7,.7,.7,.81/sqrt(3.37),.81/sqrt(3.37));float a=0,b=100;
 for(int i=0;i<5;++i){float den=dot(ns[i],d),num=ds[i]-dot(ns[i],o);if(abs(den)<1e-6){if(num<0)return 0.;}else{float t=num/den;if(den<0)a=max(a,t);else b=min(b,t);}}
 return b>a?1.:0.;}
void main(){
 vec2 uv=(vUV-.5)*10.;vec3 base=texture(uAlbedo,uv).rgb;
 vec3 map=texture(uNormalMap,uv).xyz*2-1;map.xy*=.35;
 vec3 N=normalize(uAxisU*map.x+uAxisV*map.y+uNormal*map.z);
 float rough=clamp(texture(uRoughness,uv).r,.35,.98);
 vec3 V=normalize(uCamera-vWorld),L=normalize(vec3(-3,6,2)-vWorld),H=normalize(V+L);
 float nl=max(dot(N,L),0.),nv=max(dot(N,V),.001),nh=max(dot(N,H),0.),vh=max(dot(V,H),0.);
 float a=rough*rough,a2=a*a,d=nh*nh*(a2-1)+1;
 float D=a2/(PI*d*d),k=(rough+1)*(rough+1)/8;
 float G=nl/(nl*(1-k)+k)*nv/(nv*(1-k)+k);
 vec3 F=vec3(.04)+.96*pow(1-vh,5);
 float shadow=texture(uShadow,vUV).r;
 // Finite hemisphere samples soften the environment; this is approximate IBL.
 vec3 ambient=(environment(uNormal)+environment(normalize(uNormal+uAxisU))+environment(normalize(uNormal-uAxisU))+environment(normalize(uNormal+uAxisV))+environment(normalize(uNormal-uAxisV)))*.20;
 vec3 local=(uPrismInverse*vec4(vWorld,1)).xyz;
 float contact=1-.38*exp(-dot(local.xz,local.xz)*2.0)*exp(-abs(local.y+.7)*8);
 vec3 lit=base*(ambient*.22*contact+vec3(.9)*nl*shadow/PI)+D*G*F/(4*nv*max(nl,.001))*nl*shadow;
 vec3 xyz=texture(uCaustic,vUV).rgb;
 // XYZ -> linear sRGB only after accumulation. Negative out-of-gamut channels clipped here.
 vec3 rgb=vec3(dot(xyz,vec3(3.2406,-1.5372,-.4986)),dot(xyz,vec3(-.9689,1.8758,.0415)),dot(xyz,vec3(.0557,-.2040,1.0570)));
 lit+=max(rgb,0)*base/PI;
 fragColor=vec4(max(lit,0),1);
}
