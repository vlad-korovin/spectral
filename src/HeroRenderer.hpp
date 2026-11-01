#pragma once
#include <glad/glad.h>
#include "SpectralTransport.hpp"
#include "CameraFrame.hpp"
#include <string>
// Owns only optical/receiver GPU resources. Frame transforms are supplied by scene.
class HeroRenderer {
 GLuint incidentProgram=0,incidentDepth=0;
 int depthWidth=0,depthHeight=0;
 GLuint splatProgram=0,receiverProgram=0,vao=0,vbo=0,tableVAO=0,fbo=0,texture=0;
 GLuint albedo=0,normal=0,roughness=0;
 GLuint shadowProgram=0,shadowFbo=0,shadowTexture=0;
 GLuint cameraProgram=0,cameraColor=0,cameraDepth=0,cameraMask=0;
 int cameraWidth=0,cameraHeight=0;
 camera_input::Frame inputFrame;
 bool cameraEnabled=false;
 bool syntheticDemo=false;
 double syntheticTime=0;
 bool opticalCacheValid=false;
 hero::Transform cachedModel{};
 hero::Settings cachedSettings;
 hero::Receiver cachedReceiver;
 static constexpr int resolution=2048;
public:
 hero::Receiver receiver;
 hero::Result lastTransport;
 bool hasCameraFrame() const { return cameraEnabled; }
 bool isSyntheticDemo() const { return syntheticDemo; }
 void clearCameraFrame() { cameraEnabled=false; syntheticDemo=false; }
 const camera_input::Frame& cameraFrame() const { return inputFrame; }
 // Call on the render thread; a CV producer can deliver synchronized frames here.
 void setCameraFrame(camera_input::Frame frame);
 void setSyntheticDemo(const camera_input::Intrinsics&,const hero::Transform&);
 void setSyntheticTime(double value) { syntheticTime=value; }
 void drawCamera(const float* projection);
 void init(const std::string& shaderDirectory,const std::string& assets);
 void accumulate(const hero::Transform&,const hero::Settings&);
 void draw(const float* view,const float* projection,hero::V3 camera,GLuint environment,const hero::Transform&,const hero::Settings&);
 void drawIncident(int width,int height,hero::V3 camera,hero::V3 forward,hero::V3 right,hero::V3 up,float tanHalfFov,float nearPlane,float farPlane,const hero::Transform&,const hero::Settings&);
 ~HeroRenderer();
};
