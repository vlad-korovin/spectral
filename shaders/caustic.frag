#version 330 core
in vec2 vKernel;
flat in vec3 vXYZ;
out vec4 fragColor;
void main(){float r2=dot(vKernel,vKernel);if(r2>1)discard;
 // Unit-integral truncated Gaussian in world square units. Independent of map resolution.
 float kernel=exp(-4*r2)*4/(3.14159265*.045*.045*(1-exp(-4.0)));
 fragColor=vec4(vXYZ*kernel,0);}
