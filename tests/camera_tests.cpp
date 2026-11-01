#include "CameraFrame.hpp"
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

void check(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
template<class F> void rejects(F f,const char*message){bool threw=false;try{f();}catch(const std::exception&){threw=true;}check(threw,message);}

int main(){
    using namespace camera_input;
    Intrinsics k{640,360,520,515,302,174};
    auto projection=k.projection(.1f,100);
    // Off-center calibration projects measured pixels back to the same positions.
    for(float z:{.2f,2.f,30.f})for(float x:{.5f,130.5f,630.5f})for(float y:{.5f,80.5f,350.5f}){
        auto p=k.cameraPoint(x,y,z);
        float clipX=projection[0]*p.x+projection[8]*p.z;
        float clipY=projection[5]*p.y+projection[9]*p.z;
        check(std::abs((clipX/z*.5f+.5f)*k.width-x)<.001f,"X calibration round trip");
        check(std::abs((.5f-clipY/z*.5f)*k.height-y)<.001f,"Y calibration round trip");
        float ndc=(projection[10]*p.z+projection[14])/z;
        check(ndc>=-1&&ndc<=1,"valid depth outside frustum");
    }
    Frame frame;frame.intrinsics=k;frame.rgb.resize(640*360*3);frame.validate();
    frame.depth.resize(2);rejects([&]{frame.validate();},"unaligned depth accepted");frame.depth.clear();
    frame.occlusionMask.resize(640*360);rejects([&]{frame.validate();},"mask without depth accepted");frame.occlusionMask.clear();
    frame.cameraToWorld[0]=2;rejects([&]{frame.validate();},"scaled pose accepted");
    frame.cameraToWorld[0]=-1;rejects([&]{frame.validate();},"reflected camera axes accepted");
    k.fx=0;rejects([&]{k.validate();},"zero focal length accepted");

    // Portable depth fixture with explicit byte order, bottom-to-top PFM rows.
    const auto path=std::filesystem::temp_directory_path()/"prism-camera-depth-test.pfm";
    for(bool little:{false,true}){
        std::ofstream out(path,std::ios::binary);out<<"Pf\n2 2\n"<<(little?"-1\n":"1\n");
        for(std::uint32_t bits:{0x40400000u,0x40800000u,0x3f800000u,0x40000000u}){
            for(int byte=0;byte<4;++byte){int shift=little?byte*8:(3-byte)*8;out.put(static_cast<char>((bits>>shift)&255));}
        }
        out.close();auto values=loadDepthPFM(path.string(),2,2);
        check(values==std::vector<float>({1,2,3,4}),"PFM endian/row decoding");
        rejects([&]{loadDepthPFM(path.string(),3,2);},"PFM shape mismatch accepted");
    }
    std::filesystem::remove(path);
    Intrinsics demoK{64,36,49.4546f,49.4546f,32,18};
    hero::Transform pose{1,0,0,0,0,1,0,0,0,0,1,0,1.25f,.05f,3.8f,1};
    auto a=makeOcclusionDemo(demoK,pose,0),b=makeOcclusionDemo(demoK,pose,2);
    a.validate();b.validate();
    check(a.depth!=b.depth,"demo depth does not respond to foreground motion");
    int occluded=0;
    for(float z:a.depth)if(z>0&&z<8)++occluded;
    check(occluded>0,"demo contains no nearer occluder");
    std::cout<<"Camera calibration, frame validation, PFM endian/row decoding, and moving occluder tests passed\n";
}
