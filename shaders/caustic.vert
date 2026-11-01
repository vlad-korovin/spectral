#version 330 core
layout(location=0) in vec3 aPosition;
layout(location=1) in vec3 aXYZ;
uniform vec3 uOrigin,uAxisU,uAxisV;
uniform float uExtent;
out vec2 vKernel;
flat out vec3 vXYZ;
const vec2 corners[6]=vec2[6](vec2(-1,-1),vec2(1,-1),vec2(1,1),vec2(-1,-1),vec2(1,1),vec2(-1,1));
const float radius=.045;
void main(){vKernel=corners[gl_VertexID];vXYZ=aXYZ;vec3 q=aPosition-uOrigin;vec2 p=vec2(dot(q,uAxisU),dot(q,uAxisV));gl_Position=vec4((p+vKernel*radius)/uExtent,0,1);}
