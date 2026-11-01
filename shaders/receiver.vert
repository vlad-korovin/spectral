#version 330 core
uniform mat4 uView,uProjection;
uniform vec3 uOrigin,uAxisU,uAxisV;
uniform float uExtent;
out vec3 vWorld;
out vec2 vUV;
const vec2 corners[6]=vec2[6](vec2(-1,-1),vec2(1,-1),vec2(1,1),vec2(-1,-1),vec2(1,1),vec2(-1,1));
void main(){vec2 p=corners[gl_VertexID];vUV=p*.5+.5;vWorld=uOrigin+(uAxisU*p.x+uAxisV*p.y)*uExtent;gl_Position=uProjection*uView*vec4(vWorld,1);}
