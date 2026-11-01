#include "CameraFrame.hpp"
#include "../third_party/stb_image.h"
#include <memory>
#include <stdexcept>

namespace camera_input {
Frame loadRecorded(const std::string& colorPath, const std::string& depthPath,
                   const std::string& maskPath, const Intrinsics& k) {
    k.validate();
    // Match documented top-left order; stb's global flip flag was changed by material loading.
    stbi_set_flip_vertically_on_load(false);
    auto load=[&](const std::string& path,int channels) {
        int w=0,h=0,c=0;
        std::unique_ptr<unsigned char,decltype(&stbi_image_free)> pixels(
            stbi_load(path.c_str(),&w,&h,&c,channels),stbi_image_free);
        if(!pixels)throw std::runtime_error("Cannot load camera image: "+path);
        if(w!=k.width || h!=k.height)throw std::runtime_error("Camera image does not match intrinsics: "+path);
        return std::vector<unsigned char>(pixels.get(),pixels.get()+w*h*channels);
    };
    Frame frame;frame.intrinsics=k;frame.rgb=load(colorPath,3);
    if(!depthPath.empty())frame.depth=loadDepthPFM(depthPath,k.width,k.height);
    if(!maskPath.empty())frame.occlusionMask=load(maskPath,1);
    frame.validate();return frame;
}
} // namespace camera_input
