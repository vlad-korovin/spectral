#include "Beam.hpp"

#include <algorithm>
#include <cmath>

namespace
{
    constexpr float PI =
        3.14159265358979323846f;

    float cauchyIndex(
        float baseIndex,
        float dispersionC,
        float wavelengthMicrometers)
    {
        return baseIndex +
               dispersionC /
                   (wavelengthMicrometers *
                    wavelengthMicrometers);
    }

    float prismDeviation(
        float refractiveIndex)
    {
        // ----------------------------------------------------
        // Minimum-deviation approximation for an
        // equilateral 60-degree prism.
        //
        // delta =
        // 2 asin(n sin(A/2)) - A
        //
        // This gives us a physically meaningful,
        // wavelength-dependent angular separation.
        // ----------------------------------------------------

        constexpr float prismAngle =
            PI / 3.0f;

        float argument =
            refractiveIndex *
            std::sin(
                prismAngle * 0.5f);

        argument =
            std::clamp(
                argument,
                -0.999f,
                0.999f);

        return 2.0f *
                   std::asin(argument) -
               prismAngle;
    }

    BeamSegment makeBeam(
        float startX,
        float startY,
        float startZ,
        float endX,
        float endY,
        float endZ,
        float width,
        BeamColor color,
        float intensity)
    {
        return {
            startX,
            startY,
            startZ,

            endX,
            endY,
            endZ,

            width,

            color,

            intensity};
    }
}

std::vector<BeamSegment> buildHeroBeams(
    const BeamOptics &optics)
{
    std::vector<BeamSegment> beams;

    beams.reserve(
        4);

    constexpr float prismX =
        1.25f;

    constexpr float prismY =
        -0.15f;

    constexpr float prismZ =
        -5.2f;

    // ----------------------------------------------------
    // Incident white beam.
    // ----------------------------------------------------

    beams.push_back(
        makeBeam(
            -9.0f,
            0.15f,
            prismZ + 0.10f,

            -0.45f,
            0.15f,
            prismZ + 0.10f,

            0.16f,

            {1.0f,
             0.96f,
             0.88f},

            2.0f));

    // ----------------------------------------------------
    // Cauchy dispersion.
    //
    // Same wavelengths as engine.glsl:
    //
    // R = 660 nm
    // G = 550 nm
    // B = 440 nm
    // ----------------------------------------------------

    float nR =
        cauchyIndex(
            optics.refractiveIndex,
            optics.dispersionC,
            0.660f);

    float nG =
        cauchyIndex(
            optics.refractiveIndex,
            optics.dispersionC,
            0.550f);

    float nB =
        cauchyIndex(
            optics.refractiveIndex,
            optics.dispersionC,
            0.440f);

    float deviationR =
        prismDeviation(
            nR);

    float deviationG =
        prismDeviation(
            nG);

    float deviationB =
        prismDeviation(
            nB);

    // ----------------------------------------------------
    // We use relative deviation from green.
    //
    // The overall beam direction is chosen for the
    // Hero Lab composition, while the RGB separation
    // itself comes from the optical model.
    // ----------------------------------------------------

    constexpr float baseAngle =
        -0.10f;

    constexpr float visualDispersionScale =
        2.8f;

    float angleR =
        baseAngle +
        (deviationR -
         deviationG) *
            visualDispersionScale;

    float angleG =
        baseAngle;

    float angleB =
        baseAngle +
        (deviationB -
         deviationG) *
            visualDispersionScale;

    constexpr float beamLength =
        11.0f;

    float transmission =
        std::exp(
            -0.22f *
            optics.absorptionStrength);

    auto addExitBeam =
        [&](float angle,
            BeamColor color)
    {
        float endX =
            prismX +
            std::cos(angle) *
                beamLength;

        float endY =
            prismY +
            std::sin(angle) *
                beamLength;

        beams.push_back(
            makeBeam(
                0.40f,
                0.0f,
                prismZ + 0.12f,

                endX,
                endY,
                prismZ + 0.12f,

                0.13f,

                color,

                2.2f *
                    transmission));
    };

    addExitBeam(
        angleR,
        {1.0f,
         0.06f,
         0.03f});

    addExitBeam(
        angleG,
        {0.05f,
         1.0f,
         0.22f});

    addExitBeam(
        angleB,
        {0.08f,
         0.22f,
         1.0f});

    return beams;
}