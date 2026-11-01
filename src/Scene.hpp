#pragma once

#include <vector>

enum class ScenePreset
{
    HeroLab
};

struct ScenePrism
{
    float x;
    float y;
    float z;
    float phase;
};

struct SceneDescription
{
    std::vector<ScenePrism> prisms;
};

SceneDescription buildScene(
    ScenePreset preset);

const char *scenePresetName(
    ScenePreset preset);
