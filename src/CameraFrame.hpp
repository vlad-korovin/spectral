#pragma once

#include "SpectralTransport.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace camera_input {

// Pixel coordinates have their origin at the upper left; depths are positive
// optical-axis Z, in the SAME units as the virtual scene (not Euclidean range).
struct Intrinsics {
    int width = 0, height = 0;
    float fx = 0, fy = 0, cx = 0, cy = 0;
    void validate() const;
    hero::Transform projection(float nearPlane, float farPlane) const;
    hero::V3 cameraPoint(float pixelX, float pixelY, float depth) const;
};

struct Frame {
    Intrinsics intrinsics;
    // OpenGL camera axes: +X right, +Y up, -Z forward. Rigid camera-to-world.
    hero::Transform cameraToWorld{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    std::uint64_t sequence = 0;
    double timestampSeconds = 0;
    std::vector<unsigned char> rgb; // Packed sRGB, RGB8, top row first.
    std::vector<float> depth;       // Optional; zero/nonfinite means unknown.
    // Optional segmentation/confidence gate for occlusion: 0 excludes, 255 accepts.
    // This gates depth occlusion only; camera RGB remains visible everywhere.
    std::vector<unsigned char> occlusionMask;
    void validate() const;
};

// Inputs must already be registered, undistorted, and use the same intrinsics.
Frame loadRecorded(const std::string& rgbPath, const std::string& depthPFM,
                   const std::string& maskPath, const Intrinsics&);
std::vector<float> loadDepthPFM(const std::string&, int expectedWidth, int expectedHeight);

// Explicit synthetic RGB-D fixture, not camera capture or an AI depth estimate.
Frame makeOcclusionDemo(const Intrinsics&, const hero::Transform&, double time);
} // namespace camera_input
