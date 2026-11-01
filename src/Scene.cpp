#include "Scene.hpp"

SceneDescription buildScene(ScenePreset preset)
{
    (void)preset;
    SceneDescription scene;
    scene.prisms.reserve(1);

    // One optical object and one deliberate composition. Rendering, transport,
    // camera integration, and diagnostics all consume this same scene.
    scene.prisms.push_back({1.25f, -0.15f, -5.2f, 0.35f});
    return scene;
}

const char *scenePresetName(ScenePreset preset)
{
    (void)preset;
    return "HERO";
}
