#pragma once

// Legacy engineering overlay only. HeroRenderer/SpectralTransport own Hero illumination.

#include <vector>

struct BeamColor
{
    float r;
    float g;
    float b;
};

struct BeamSegment
{
    float startX;
    float startY;
    float startZ;

    float endX;
    float endY;
    float endZ;

    float width;

    BeamColor color;

    float intensity;
};

struct BeamOptics
{
    float refractiveIndex;
    float dispersionC;
    float absorptionStrength;
};

std::vector<BeamSegment> buildHeroBeams(
    const BeamOptics &optics);