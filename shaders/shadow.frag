#version 330 core
in vec2 vUV;
out vec4 fragColor;
uniform vec3 uOrigin,uAxisU,uAxisV,uNormal;
uniform float uExtent;
uniform mat4 uPrismInverse;
float blocked(vec3 origin,vec3 direction) {
    vec3 o=(uPrismInverse*vec4(origin,1)).xyz;
    vec3 d=(uPrismInverse*vec4(direction,0)).xyz;
    vec3 ns[5]=vec3[5](vec3(0,0,1),vec3(0,0,-1),vec3(0,-1,0),normalize(vec3(-1.6,.9,0)),normalize(vec3(1.6,.9,0)));
    float ds[5]=float[5](.7,.7,.7,.81/sqrt(3.37),.81/sqrt(3.37));
    float enter=0,exit=100;
    for(int i=0;i<5;++i){
        float den=dot(ns[i],d),num=ds[i]-dot(ns[i],o);
        if(abs(den)<1e-6){if(num<0)return 0.;}
        else{float t=num/den;if(den<0)enter=max(enter,t);else exit=min(exit,t);}
    }
    return exit>enter?1.:0.;
}
void main(){
    vec2 p=(vUV*2-1)*uExtent;
    vec3 world=uOrigin+uAxisU*p.x+uAxisV*p.y+uNormal*.003;
    float occlusion=0;
    for(int i=0;i<32;++i){
        // Equal-area golden-angle disk: many overlapping silhouettes form a penumbra.
        float r=.85*sqrt((float(i)+.5)/32.),a=float(i)*2.39996323;
        vec3 light=vec3(-3,6,2)+vec3(cos(a)*r,0,sin(a)*r);
        occlusion+=blocked(world,normalize(light-world));
    }
    // Approximate glass attenuation, not an opaque-black blocker.
    fragColor=vec4(1.-.55*occlusion/32.,0,0,1);
}
