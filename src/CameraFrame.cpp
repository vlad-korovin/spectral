#include "CameraFrame.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace camera_input {
void Intrinsics::validate() const {
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
        !std::isfinite(fx) || !std::isfinite(fy) || !std::isfinite(cx) || !std::isfinite(cy) ||
        fx <= 0 || fy <= 0 || cx < 0 || cy < 0 || cx > width || cy > height)
        throw std::runtime_error("Invalid camera dimensions or intrinsics");
}
hero::Transform Intrinsics::projection(float n, float f) const {
    validate();
    if (!(n > 0 && f > n)) throw std::runtime_error("Invalid camera clip planes");
    hero::Transform p{};
    p[0] = 2 * fx / width; p[5] = 2 * fy / height;
    p[8] = 1 - 2 * cx / width; p[9] = 2 * cy / height - 1;
    p[10] = -(f+n)/(f-n); p[11] = -1; p[14] = -2*f*n/(f-n);
    return p;
}
hero::V3 Intrinsics::cameraPoint(float x, float y, float z) const {
    return {(x-cx)*z/fx, -(y-cy)*z/fy, -z};
}
void Frame::validate() const {
    intrinsics.validate();
    const auto count = static_cast<std::size_t>(intrinsics.width) * intrinsics.height;
    if (rgb.size() != count*3 || (!depth.empty() && depth.size() != count) ||
        (!occlusionMask.empty() && occlusionMask.size() != count))
        throw std::runtime_error("Camera color/depth/mask dimensions do not match");
    if (!occlusionMask.empty() && depth.empty())
        throw std::runtime_error("Occlusion mask requires depth; RGB alone supplies no geometry");
    if (!std::isfinite(timestampSeconds)) throw std::runtime_error("Invalid frame timestamp");
    for (float x : cameraToWorld) if (!std::isfinite(x)) throw std::runtime_error("Invalid camera pose");
    auto x = hero::vector(cameraToWorld, {1,0,0});
    auto y = hero::vector(cameraToWorld, {0,1,0});
    auto z = hero::vector(cameraToWorld, {0,0,1});
    hero::V3 crossXY{x.y*y.z-x.z*y.y,x.z*y.x-x.x*y.z,x.x*y.y-x.y*y.x};
    if (std::abs(hero::dot(x,x)-1) > .001f || std::abs(hero::dot(y,y)-1) > .001f ||
        std::abs(hero::dot(z,z)-1) > .001f || std::abs(hero::dot(x,y)) > .001f ||
        std::abs(hero::dot(x,z)) > .001f || std::abs(hero::dot(y,z)) > .001f ||
        std::abs(cameraToWorld[3])+std::abs(cameraToWorld[7])+std::abs(cameraToWorld[11]) > .001f ||
        std::abs(cameraToWorld[15]-1) > .001f || hero::dot(crossXY,z)<.999f)
        throw std::runtime_error("Camera pose must be a rigid transform without scale");
}

std::vector<float> loadDepthPFM(const std::string& path, int width, int height) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open depth: " + path);
    auto line = [&]() {
        std::string s;
        while (std::getline(file,s)) {
            if (!s.empty() && s.back()=='\r') s.pop_back();
            if (!s.empty() && s.front()!='#') return s;
        }
        throw std::runtime_error("Truncated PFM header: " + path);
    };
    if (line() != "Pf") throw std::runtime_error("Depth must be single-channel Pf PFM");
    int w=0,h=0; std::istringstream dimensions(line()); dimensions >> w >> h;
    if (w!=width || h!=height) throw std::runtime_error("PFM dimensions must match RGB/intrinsics");
    float scale=0; std::istringstream scaleLine(line()); scaleLine >> scale;
    if (!std::isfinite(scale) || scale==0) throw std::runtime_error("Invalid PFM scale");
    std::vector<float> result(static_cast<std::size_t>(w)*h);
    std::vector<std::uint32_t> row(w);
    const bool swap = (scale < 0) != (std::endian::native == std::endian::little);
    for (int y=h-1; y>=0; --y) {
        if (!file.read(reinterpret_cast<char*>(row.data()),w*sizeof(float)))
            throw std::runtime_error("Truncated PFM pixels: " + path);
        for (int x=0; x<w; ++x) {
            auto bits=row[x];
            if (swap) bits=(bits>>24)|((bits>>8)&0xff00)|((bits<<8)&0xff0000)|(bits<<24);
            float d=std::bit_cast<float>(bits)*std::abs(scale);
            result[y*w+x]=std::isfinite(d)&&d>0 ? d : 0;
        }
    }
    return result;
}

Frame makeOcclusionDemo(const Intrinsics& k, const hero::Transform& pose, double time) {
    k.validate();
    Frame f; f.intrinsics=k; f.cameraToWorld=pose; f.timestampSeconds=time;
    f.sequence=static_cast<std::uint64_t>(std::max(0.,time)*1000000);
    auto count=static_cast<std::size_t>(k.width)*k.height;
    f.rgb.resize(count*3); f.depth.resize(count); f.occlusionMask.assign(count,255);
    auto origin=hero::point(pose,{});
    hero::V3 center{1.25f+1.6f*static_cast<float>(std::sin(time*.7)), .05f, -3.5f};
    for (int y=0; y<k.height; ++y) for (int x=0; x<k.width; ++x) {
        auto ray=hero::vector(pose,k.cameraPoint(x+.5f,y+.5f,1));
        float t=ray.y<-.0001f ? (-.85f-origin.y)/ray.y : 1e6f;
        if(t<=0)t=1e6f;
        auto delta=origin-center;
        float a=hero::dot(ray,ray), b=hero::dot(ray,delta), c=hero::dot(delta,delta)-.55f*.55f;
        float disc=b*b-a*c, sphere=disc>=0 ? (-b-std::sqrt(disc))/a : -1;
        bool foreground=sphere>0 && sphere<t;
        if(foreground)t=sphere;
        const auto i=static_cast<std::size_t>(y)*k.width+x;
        f.depth[i]=t<100 ? t : 0;
        auto p=origin+ray*t;
        int checker=t<100 ? (static_cast<int>(std::floor(p.x))+static_cast<int>(std::floor(p.z)))&1 : 0;
        unsigned char shade=checker?125:150;
        f.rgb[i*3]=foreground?220:(t<100?shade:90);
        f.rgb[i*3+1]=foreground?95:(t<100?shade:100);
        f.rgb[i*3+2]=foreground?35:(t<100?shade:115);
    }
    return f;
}
} // namespace camera_input
