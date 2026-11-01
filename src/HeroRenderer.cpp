#include "HeroRenderer.hpp"
#include "ImageLoader.hpp"
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <cstddef>
#include <utility>
namespace {
GLuint shader(const std::string&path,GLenum type){std::ifstream f(path);if(!f)throw std::runtime_error("Missing shader: "+path);std::stringstream ss;ss<<f.rdbuf();auto src=ss.str();const char*p=src.c_str();GLuint id=glCreateShader(type);glShaderSource(id,1,&p,nullptr);glCompileShader(id);GLint ok;glGetShaderiv(id,GL_COMPILE_STATUS,&ok);if(!ok){char log[4096];glGetShaderInfoLog(id,sizeof(log),nullptr,log);glDeleteShader(id);throw std::runtime_error(path+": "+log);}return id;}
GLuint program(const std::string&root,const char*name){GLuint v=shader(root+"/"+name+".vert",GL_VERTEX_SHADER),f=shader(root+"/"+name+".frag",GL_FRAGMENT_SHADER),p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);glDeleteShader(v);glDeleteShader(f);GLint ok;glGetProgramiv(p,GL_LINK_STATUS,&ok);if(!ok){char log[4096];glGetProgramInfoLog(p,sizeof(log),nullptr,log);glDeleteProgram(p);throw std::runtime_error(log);}return p;}
void vec(GLuint p,const char*n,hero::V3 v){glUniform3f(glGetUniformLocation(p,n),v.x,v.y,v.z);}
void frame(GLuint p,const hero::Receiver&r){vec(p,"uOrigin",r.origin);vec(p,"uAxisU",r.u);vec(p,"uAxisV",r.v);vec(p,"uNormal",r.normal);glUniform1f(glGetUniformLocation(p,"uExtent"),r.extent);}
void tex(GLuint p,const char*n,int unit,GLuint t){glActiveTexture(GL_TEXTURE0+unit);glBindTexture(GL_TEXTURE_2D,t);glUniform1i(glGetUniformLocation(p,n),unit);}
}
void HeroRenderer::init(const std::string&root,const std::string&assets){
 cameraProgram=program(root,"camera");
 shadowProgram=program(root,"shadow");
 glGenTextures(1,&cameraColor);glGenTextures(1,&cameraDepth);glGenTextures(1,&cameraMask);
 glGenTextures(1,&shadowTexture);glBindTexture(GL_TEXTURE_2D,shadowTexture);
 glTexImage2D(GL_TEXTURE_2D,0,GL_R16F,512,512,0,GL_RED,GL_FLOAT,nullptr);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
 glGenFramebuffers(1,&shadowFbo);glBindFramebuffer(GL_FRAMEBUFFER,shadowFbo);
 glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,shadowTexture,0);
 if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Shadow framebuffer incomplete");
 incidentProgram=program(root,"incident");glGenTextures(1,&incidentDepth);
 splatProgram=program(root,"caustic");receiverProgram=program(root,"receiver");
 albedo=loadTexture2D((assets+"/materials/rough_concrete/albedo.jpg").c_str(),true);
 normal=loadTexture2D((assets+"/materials/rough_concrete/normal_gl.jpg").c_str(),false);
 roughness=loadTexture2D((assets+"/materials/rough_concrete/roughness.jpg").c_str(),false);
 glGenVertexArrays(1,&vao);glGenVertexArrays(1,&tableVAO);glGenBuffers(1,&vbo);
 glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);
 for(int i=0;i<2;++i){glEnableVertexAttribArray(i);glVertexAttribPointer(i,3,GL_FLOAT,GL_FALSE,sizeof(hero::Deposit),reinterpret_cast<void*>(i*sizeof(hero::V3)));glVertexAttribDivisor(i,1);}glBindVertexArray(0);
 glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA16F,resolution,resolution,0,GL_RGBA,GL_FLOAT,nullptr);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_BORDER);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_BORDER);
 glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
 if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Caustic HDR framebuffer incomplete");glBindFramebuffer(GL_FRAMEBUFFER,0);
}
void HeroRenderer::accumulate(const hero::Transform&m,const hero::Settings&s){
 if(opticalCacheValid && m==cachedModel && s==cachedSettings && receiver==cachedReceiver)return;
 lastTransport=hero::transport(m,receiver,s);
 glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,resolution,resolution);glDisable(GL_DEPTH_TEST);glDisable(GL_CULL_FACE);glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);
 glUseProgram(splatProgram);frame(splatProgram,receiver);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);
 glBufferData(GL_ARRAY_BUFFER,lastTransport.deposits.size()*sizeof(hero::Deposit),lastTransport.deposits.data(),GL_STREAM_DRAW);
 glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_ONE,GL_ONE);
 glDrawArraysInstanced(GL_TRIANGLES,0,6,static_cast<GLsizei>(lastTransport.deposits.size()));glDisable(GL_BLEND);glBindVertexArray(0);
 // Evaluate area-light visibility once in receiver space instead of per display sample.
 glBindFramebuffer(GL_FRAMEBUFFER,shadowFbo);glViewport(0,0,512,512);
 glUseProgram(shadowProgram);frame(shadowProgram,receiver);
 auto inverse=hero::inverseRigid(m);
 glUniformMatrix4fv(glGetUniformLocation(shadowProgram,"uPrismInverse"),1,GL_FALSE,inverse.data());
 glBindVertexArray(tableVAO);glDrawArrays(GL_TRIANGLES,0,3);glBindVertexArray(0);
 cachedModel=m;cachedSettings=s;cachedReceiver=receiver;opticalCacheValid=true;
}
void HeroRenderer::draw(const float*view,const float*projection,hero::V3 camera,GLuint env,const hero::Transform&m,const hero::Settings&s){
 glEnable(GL_DEPTH_TEST);glDepthMask(GL_TRUE);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glUseProgram(receiverProgram);frame(receiverProgram,receiver);
 glUniformMatrix4fv(glGetUniformLocation(receiverProgram,"uView"),1,GL_FALSE,view);glUniformMatrix4fv(glGetUniformLocation(receiverProgram,"uProjection"),1,GL_FALSE,projection);
 auto inv=hero::inverseRigid(m);glUniformMatrix4fv(glGetUniformLocation(receiverProgram,"uPrismInverse"),1,GL_FALSE,inv.data());
 vec(receiverProgram,"uCamera",camera);vec(receiverProgram,"uEmitter",s.emitter);
 tex(receiverProgram,"uCaustic",0,texture);tex(receiverProgram,"uAlbedo",1,albedo);tex(receiverProgram,"uNormalMap",2,normal);tex(receiverProgram,"uRoughness",3,roughness);tex(receiverProgram,"uEnvironment",4,env);
 tex(receiverProgram,"uShadow",5,shadowTexture);
 glBindVertexArray(tableVAO);glDrawArrays(GL_TRIANGLES,0,6);glBindVertexArray(0);glActiveTexture(GL_TEXTURE0);
}
HeroRenderer::~HeroRenderer(){
 glDeleteProgram(cameraProgram);glDeleteProgram(shadowProgram);glDeleteFramebuffers(1,&shadowFbo);
 GLuint inputTextures[]={cameraColor,cameraDepth,cameraMask,shadowTexture};glDeleteTextures(4,inputTextures);
 glDeleteProgram(incidentProgram);glDeleteTextures(1,&incidentDepth);glDeleteProgram(splatProgram);glDeleteProgram(receiverProgram);glDeleteVertexArrays(1,&vao);glDeleteVertexArrays(1,&tableVAO);glDeleteBuffers(1,&vbo);glDeleteFramebuffers(1,&fbo);GLuint textures[]={texture,albedo,normal,roughness};glDeleteTextures(4,textures);
}

void HeroRenderer::drawIncident(int width,int height,hero::V3 camera,hero::V3 forward,hero::V3 right,hero::V3 up,float tanHalfFov,float nearPlane,float farPlane,const hero::Transform&m,const hero::Settings&s){
 glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,incidentDepth);
 if(width!=depthWidth||height!=depthHeight){
  glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT24,width,height,0,GL_DEPTH_COMPONENT,GL_UNSIGNED_INT,nullptr);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
  depthWidth=width;depthHeight=height;
 }
 glCopyTexSubImage2D(GL_TEXTURE_2D,0,0,0,0,0,width,height);
 glUseProgram(incidentProgram);glUniform1i(glGetUniformLocation(incidentProgram,"uDepth"),0);
 const auto& k=inputFrame.intrinsics;
 glUniform4f(glGetUniformLocation(incidentProgram,"uIntrinsics"),cameraEnabled?k.fx:0,k.fy,k.cx,k.cy);
 glUniform2f(glGetUniformLocation(incidentProgram,"uCameraImageSize"),k.width,k.height);
 glUniform2f(glGetUniformLocation(incidentProgram,"uResolution"),width,height);
 vec(incidentProgram,"uCamera",camera);vec(incidentProgram,"uForward",forward);vec(incidentProgram,"uRight",right);vec(incidentProgram,"uUp",up);vec(incidentProgram,"uEmitter",s.emitter);
 auto dir=hero::normalized(s.direction);auto beamU=hero::normalized(hero::V3{dir.y,-dir.x,0});
 auto beamV=hero::normalized(hero::V3{dir.y*beamU.z-dir.z*beamU.y,dir.z*beamU.x-dir.x*beamU.z,dir.x*beamU.y-dir.y*beamU.x});
 vec(incidentProgram,"uDirection",dir);vec(incidentProgram,"uBeamU",beamU);vec(incidentProgram,"uBeamV",beamV);
 glUniform2f(glGetUniformLocation(incidentProgram,"uSlit"),s.slitWidth,s.slitHeight);
 auto inv=hero::inverseRigid(m);glUniformMatrix4fv(glGetUniformLocation(incidentProgram,"uPrismInverse"),1,GL_FALSE,inv.data());
 glUniform1f(glGetUniformLocation(incidentProgram,"uTanHalfFov"),tanHalfFov);glUniform1f(glGetUniformLocation(incidentProgram,"uNear"),nearPlane);glUniform1f(glGetUniformLocation(incidentProgram,"uFar"),farPlane);glUniform1f(glGetUniformLocation(incidentProgram,"uPower"),s.power);
 glDisable(GL_DEPTH_TEST);glDepthMask(GL_FALSE);glEnable(GL_BLEND);glBlendFunc(GL_ONE,GL_ONE);
 glBindVertexArray(tableVAO);glDrawArrays(GL_TRIANGLES,0,3);glBindVertexArray(0);glDisable(GL_BLEND);glDepthMask(GL_TRUE);
}

void HeroRenderer::setCameraFrame(camera_input::Frame next) {
 next.validate();
 int w=next.intrinsics.width,h=next.intrinsics.height;
 bool allocate=w!=cameraWidth||h!=cameraHeight;
 GLint alignment=4;glGetIntegerv(GL_UNPACK_ALIGNMENT,&alignment);glPixelStorei(GL_UNPACK_ALIGNMENT,1);
 auto upload=[&](GLuint texture,GLenum internal,GLenum format,GLenum type,const void* data) {
  glBindTexture(GL_TEXTURE_2D,texture);
  if(allocate)glTexImage2D(GL_TEXTURE_2D,0,internal,w,h,0,format,type,data);
  else if(data)glTexSubImage2D(GL_TEXTURE_2D,0,0,0,w,h,format,type,data);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
 };
 glActiveTexture(GL_TEXTURE0);
 upload(cameraColor,GL_SRGB8,GL_RGB,GL_UNSIGNED_BYTE,next.rgb.data());
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 upload(cameraDepth,GL_R32F,GL_RED,GL_FLOAT,next.depth.empty()?nullptr:next.depth.data());
 upload(cameraMask,GL_R8,GL_RED,GL_UNSIGNED_BYTE,next.occlusionMask.empty()?nullptr:next.occlusionMask.data());
 glPixelStorei(GL_UNPACK_ALIGNMENT,alignment);glBindTexture(GL_TEXTURE_2D,0);
 cameraWidth=w;cameraHeight=h;inputFrame=std::move(next);cameraEnabled=true;syntheticDemo=false;
}

void HeroRenderer::setSyntheticDemo(const camera_input::Intrinsics& intrinsics,
                                    const hero::Transform& cameraToWorld) {
 intrinsics.validate();
 inputFrame={};inputFrame.intrinsics=intrinsics;inputFrame.cameraToWorld=cameraToWorld;
 // Synthetic mode is generated in camera.frag. No CPU RGB-D buffers or uploads.
 cameraEnabled=true;syntheticDemo=true;
}

void HeroRenderer::drawCamera(const float* projection) {
 glUseProgram(cameraProgram);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_ALWAYS);glDepthMask(GL_TRUE);
 frame(cameraProgram,receiver);
 const auto& k=inputFrame.intrinsics;
 glUniform4f(glGetUniformLocation(cameraProgram,"uIntrinsics"),k.fx,k.fy,k.cx,k.cy);
 glUniform2f(glGetUniformLocation(cameraProgram,"uImageSize"),k.width,k.height);
 glUniformMatrix4fv(glGetUniformLocation(cameraProgram,"uProjection"),1,GL_FALSE,projection);
 glUniformMatrix4fv(glGetUniformLocation(cameraProgram,"uCameraToWorld"),1,GL_FALSE,inputFrame.cameraToWorld.data());
 glUniform1i(glGetUniformLocation(cameraProgram,"uHasDepth"),!inputFrame.depth.empty());
 glUniform1i(glGetUniformLocation(cameraProgram,"uHasMask"),!inputFrame.occlusionMask.empty());
 glUniform1i(glGetUniformLocation(cameraProgram,"uSynthetic"),syntheticDemo);
 glUniform1f(glGetUniformLocation(cameraProgram,"uTime"),static_cast<float>(syntheticTime));
 tex(cameraProgram,"uColor",0,cameraColor);tex(cameraProgram,"uDepth",1,cameraDepth);tex(cameraProgram,"uMask",2,cameraMask);tex(cameraProgram,"uCaustic",3,texture);
 glBindVertexArray(tableVAO);glDrawArrays(GL_TRIANGLES,0,3);glBindVertexArray(0);glDepthFunc(GL_LESS);glActiveTexture(GL_TEXTURE0);
}
