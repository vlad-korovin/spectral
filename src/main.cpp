#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <stdexcept>
#include <cstddef>

// Include GLAD before GLFW.
#include <glad/glad.h>
#include <GLFW/glfw3.h>

#include "Scene.hpp"
#include "Beam.hpp"
#include "ImageLoader.hpp"
#include "HeroRenderer.hpp"
#include <cstdlib>
#include <optional>
#include <functional>

// ------------------------------------------------------------
// Shader path
//
// CMake can override this with -DENGINE_SHADER_PATH=...
// Otherwise we expect engine.glsl next to the executable.
// ------------------------------------------------------------
#ifndef ENGINE_SHADER_PATH
#define ENGINE_SHADER_PATH "engine.glsl"
#endif

#ifndef ENGINE_ASSET_PATH
#define ENGINE_ASSET_PATH "assets"
#endif
// ============================================================
// Basic Math
// ============================================================
struct Vec3
{
    float x;
    float y;
    float z;
};
static Vec3 operator-(Vec3 a, Vec3 b)
{
    return {
        a.x - b.x,
        a.y - b.y,
        a.z - b.z};
}
static Vec3 operator*(Vec3 v, float s)
{
    return {
        v.x * s,
        v.y * s,
        v.z * s};
}
static float dot(Vec3 a, Vec3 b)
{
    return a.x * b.x +
           a.y * b.y +
           a.z * b.z;
}
static Vec3 normalize(Vec3 v)
{
    float length =
        std::sqrt(dot(v, v));
    if (length <= 0.000001f)
    {
        return {
            0.0f,
            0.0f,
            0.0f};
    }
    return v * (1.0f / length);
}
// ============================================================
// 4x4 Matrix
//
// Column-major layout for OpenGL.
// ============================================================
struct Mat4
{
    float m[16] = {};
    static Mat4 identity()
    {
        Mat4 result;
        result.m[0] = 1.0f;
        result.m[5] = 1.0f;
        result.m[10] = 1.0f;
        result.m[15] = 1.0f;
        return result;
    }
};
// ------------------------------------------------------------
// Perspective Projection
// ------------------------------------------------------------
static Mat4 perspective(
    float fovRadians,
    float aspect,
    float nearPlane,
    float farPlane)
{
    Mat4 result{};
    float f =
        1.0f /
        std::tan(fovRadians * 0.5f);
    result.m[0] =
        f / aspect;
    result.m[5] =
        f;
    result.m[10] =
        (farPlane + nearPlane) /
        (nearPlane - farPlane);
    result.m[11] =
        -1.0f;
    result.m[14] =
        (2.0f * farPlane * nearPlane) /
        (nearPlane - farPlane);
    return result;
}
// ------------------------------------------------------------
// Matrix Multiplication
//
// result = a * b
// ------------------------------------------------------------
static Mat4 multiply(
    const Mat4 &a,
    const Mat4 &b)
{
    Mat4 result{};
    for (int column = 0; column < 4; ++column)
    {
        for (int row = 0; row < 4; ++row)
        {
            result.m[column * 4 + row] =
                a.m[0 * 4 + row] *
                    b.m[column * 4 + 0] +
                a.m[1 * 4 + row] *
                    b.m[column * 4 + 1] +
                a.m[2 * 4 + row] *
                    b.m[column * 4 + 2] +
                a.m[3 * 4 + row] *
                    b.m[column * 4 + 3];
        }
    }
    return result;
}

static Mat4 inverseMatrix(const Mat4 &input)
{
    double augmented[4][8] = {};
    for (int row = 0; row < 4; ++row)
    {
        for (int column = 0; column < 4; ++column)
            augmented[row][column] = input.m[column * 4 + row];
        augmented[row][row + 4] = 1.0;
    }
    for (int column = 0; column < 4; ++column)
    {
        int pivot = column;
        for (int row = column + 1; row < 4; ++row)
            if (std::abs(augmented[row][column]) > std::abs(augmented[pivot][column])) pivot = row;
        if (std::abs(augmented[pivot][column]) < 1e-12)
            return Mat4::identity();
        if (pivot != column)
            for (int i = 0; i < 8; ++i) std::swap(augmented[pivot][i], augmented[column][i]);
        const double divisor = augmented[column][column];
        for (double &value : augmented[column]) value /= divisor;
        for (int row = 0; row < 4; ++row)
        {
            if (row == column) continue;
            const double factor = augmented[row][column];
            for (int i = 0; i < 8; ++i) augmented[row][i] -= factor * augmented[column][i];
        }
    }
    Mat4 result{};
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            result.m[column * 4 + row] = static_cast<float>(augmented[row][column + 4]);
    return result;
}

// ------------------------------------------------------------
// Inverse of a rigid-body transform.
// Our model matrix currently contains rotation + translation.
// ------------------------------------------------------------
static Mat4 inverseRigid(const Mat4 &m)
{
    Mat4 result = Mat4::identity();

    // Transpose the 3x3 rotation.
    result.m[0] = m.m[0];
    result.m[1] = m.m[4];
    result.m[2] = m.m[8];

    result.m[4] = m.m[1];
    result.m[5] = m.m[5];
    result.m[6] = m.m[9];

    result.m[8] = m.m[2];
    result.m[9] = m.m[6];
    result.m[10] = m.m[10];

    // Inverse translation.
    result.m[12] =
        -(result.m[0] * m.m[12] +
          result.m[4] * m.m[13] +
          result.m[8] * m.m[14]);

    result.m[13] =
        -(result.m[1] * m.m[12] +
          result.m[5] * m.m[13] +
          result.m[9] * m.m[14]);

    result.m[14] =
        -(result.m[2] * m.m[12] +
          result.m[6] * m.m[13] +
          result.m[10] * m.m[14]);

    return result;
}

// ------------------------------------------------------------
// Camera LookAt Matrix
// ------------------------------------------------------------
static Mat4 lookAt(
    Vec3 eye,
    Vec3 target,
    Vec3 worldUp)
{
    Vec3 forward =
        normalize(target - eye);
    Vec3 right =
        normalize({forward.y * worldUp.z -
                       forward.z * worldUp.y,
                   forward.z * worldUp.x -
                       forward.x * worldUp.z,
                   forward.x * worldUp.y -
                       forward.y * worldUp.x});
    Vec3 up = {
        right.y * forward.z -
            right.z * forward.y,
        right.z * forward.x -
            right.x * forward.z,
        right.x * forward.y -
            right.y * forward.x};
    Mat4 result = Mat4::identity();
    result.m[0] = right.x;
    result.m[4] = right.y;
    result.m[8] = right.z;
    result.m[1] = up.x;
    result.m[5] = up.y;
    result.m[9] = up.z;
    result.m[2] = -forward.x;
    result.m[6] = -forward.y;
    result.m[10] = -forward.z;
    result.m[12] =
        -dot(right, eye);
    result.m[13] =
        -dot(up, eye);
    result.m[14] =
        dot(forward, eye);
    return result;
}
// ------------------------------------------------------------
// Rotation around Y
// ------------------------------------------------------------
static Mat4 rotationY(float angle)
{
    Mat4 result =
        Mat4::identity();
    float c =
        std::cos(angle);
    float s =
        std::sin(angle);
    result.m[0] =
        c;
    result.m[2] =
        -s;
    result.m[8] =
        s;
    result.m[10] =
        c;
    return result;
}
// ------------------------------------------------------------
// Rotation around X
// ------------------------------------------------------------
static Mat4 rotationX(float angle)
{
    Mat4 result =
        Mat4::identity();
    float c =
        std::cos(angle);
    float s =
        std::sin(angle);
    result.m[5] =
        c;
    result.m[6] =
        s;
    result.m[9] =
        -s;
    result.m[10] =
        c;
    return result;
}

static Mat4 translation(Vec3 p)
{
    Mat4 result =
        Mat4::identity();

    result.m[12] = p.x;
    result.m[13] = p.y;
    result.m[14] = p.z;

    return result;
}

// ============================================================
// Render Target
// ============================================================
struct RenderTarget
{
    GLuint fbo = 0;
    GLuint texture = 0;
    GLuint depthRBO = 0;
    GLuint depthTexture = 0;
    int width = 0;
    int height = 0;
};

struct MultisampleTarget
{
    GLuint fbo = 0;
    GLuint colorRBO = 0;
    GLuint depthRBO = 0;
    int width = 0;
    int height = 0;
    int samples = 1;
};
// ============================================================
// Prism Engine
// ============================================================
class PrismEngineNative
{
public:
    // --------------------------------------------------------
    // Resolution
    // --------------------------------------------------------
    int width = 1280;
    int height = 720;
    int outputWidth = 1280, outputHeight = 720;
    float heroRenderScale = 1.0f;
    bool qualityKeyWasDown = false;
    bool cameraDemo = false;
    bool demoKeyWasDown = false;
    bool taaEnabled = true;
    bool taaKeyWasDown = false;
    bool msaaKeyWasDown = false;
    bool historyValid = false;
    int temporalFrame = 0;
    int historyIndex = 0;
    int msaaSamples = 2;
    Mat4 previousView{};
    bool previousViewValid = false;
    Mat4 previousViewProjection{};
    bool previousViewProjectionValid = false;
    // A capture/CV worker can queue frames; consume/upload only on the GL thread.
    std::function<std::optional<camera_input::Frame>(double)> frameProvider;
    int blurWidth = 640;
    int blurHeight = 360;
    // --------------------------------------------------------
    // Shader Parameters
    // --------------------------------------------------------
    struct ShaderParams
    {
        float refractiveIndex = 1.5046f;
        float dispersionC = 0.00420f;

        float absorptionStrength = 1.0f;
        float bloomStrength = 0.12f;

        int debugMode = 0;
    } params;
    // --------------------------------------------------------
    // Camera
    // --------------------------------------------------------
    struct Camera
    {
        Vec3 position = {
            0.0f,
            0.0f,
            18.0f};

        Vec3 target = {
            0.0f,
            0.0f,
            -10.0f};
        float fovDegrees = 60.0f;
        float nearPlane = 0.1f;
        float farPlane = 150.0f;
    } camera;
    // ========================================================
    // OpenGL Programs
    // ========================================================
    GLuint sceneProgram = 0;
    GLuint blurProgram = 0;
    GLuint temporalProgram = 0;
    GLuint compositeProgram = 0;
    // ========================================================
    // Fullscreen Quad
    // ========================================================
    GLuint quadVAO = 0;
    GLuint quadVBO = 0;
    // ========================================================
    // Prism Geometry
    // ========================================================
    GLuint prismVAO = 0;
    GLuint prismVBO = 0;
    GLsizei prismVertexCount = 0;
    // ========================================================
    // Instancing
    // ========================================================
    struct BeamVertex
    {
        float position[3];
        float color[3];
        float intensity;
    };

    GLuint beamVAO = 0;
    GLuint beamVBO = 0;

    std::vector<BeamVertex> beamVertices;

    GLsizei beamVertexCount = 0;
    GLuint beamProgram = 0;
    GLuint backgroundProgram = 0;
    GLuint environmentHDR = 0;
    HeroRenderer heroRenderer;
    Mat4 heroModel = Mat4::identity();
    hero::Settings heroSettings;
    float heroTime = 0, heroYaw = 0, exposure = 1.0f;
    bool heroPaused = false, spaceWasDown = false;
    hero::Transform opticalModel() const
    {
        hero::Transform result;
        std::copy(heroModel.m, heroModel.m + 16, result.begin());
        return result;
    }
    void updateHeroModel()
    {
        if (instances.empty())
            return;
        const auto &p = instances.front().position;
        // Yaw preserves contact with the table. The same matrix feeds mesh and transport.
        heroModel = multiply(translation(p), rotationY(.12f + .10f * std::sin(heroTime * .22f) + heroYaw));
        heroSettings.A = params.refractiveIndex;
        heroSettings.B = params.dispersionC;
        heroSettings.absorption = .025f * params.absorptionStrength;
        heroSettings.emitter = {p.x - 5.25f, p.y + .60f, p.z};
        heroRenderer.receiver.origin = {p.x, p.y - .7f, p.z};
    }

    struct PrismInstance
    {
        Vec3 position;
        float phase;
    };

    struct InstanceData
    {
        Mat4 model;
        float opticalLOD = 0.0f;
    };

    GLuint instanceVBO = 0;

    std::vector<PrismInstance> instances;
    std::vector<InstanceData> visibleInstances;

    int visibleInstanceCount = 0;
    int culledInstanceCount = 0;

    int fullOpticsCount = 0;
    int cheapOpticsCount = 0;

    bool enableCulling = true;
    bool enableOpticalLOD = true;
    bool useInstancing = true;

    ScenePreset activeScenePreset =
        ScenePreset::HeroLab;

    // --------------------------------------------------------
    // Performance measurements
    // --------------------------------------------------------

    double cpuCullingMs = 0.0;

    double gpuSceneMs = 0.0;
    double gpuBlurMs = 0.0;
    double gpuCompositeMs = 0.0;

    GLuint sceneQueries[2] = {0, 0};
    GLuint blurQueries[2] = {0, 0};
    GLuint compositeQueries[2] = {0, 0};

    int queryWriteIndex = 0;

    int sceneDrawCalls = 0;
    // ========================================================
    // Render Targets
    // ========================================================
    RenderTarget backgroundTarget;
    RenderTarget sceneTarget;
    RenderTarget blurTargetA;
    RenderTarget blurTargetB;
    RenderTarget historyTargets[2];
    MultisampleTarget multisampleTarget;
    // ========================================================
    // Uniform Caches
    // ========================================================
    std::map<std::string, GLint> sceneUniforms;
    std::map<std::string, GLint> blurUniforms;
    std::map<std::string, GLint> compositeUniforms;
    std::map<std::string, GLint> beamUniforms;
    std::map<std::string, GLint> backgroundUniforms;
    // ========================================================
    // Destructor
    // ========================================================
    ~PrismEngineNative()
    {
        destroyRenderTarget(
            backgroundTarget);
        destroyRenderTarget(sceneTarget);
        destroyRenderTarget(blurTargetA);
        destroyRenderTarget(blurTargetB);
        destroyRenderTarget(historyTargets[0]);
        destroyRenderTarget(historyTargets[1]);
        destroyMultisampleTarget(multisampleTarget);
        if (instanceVBO)
        {
            glDeleteBuffers(
                1,
                &instanceVBO);
        }
        if (prismVBO)
        {
            glDeleteBuffers(
                1,
                &prismVBO);
        }
        if (prismVAO)
        {
            glDeleteVertexArrays(
                1,
                &prismVAO);
        }
        if (quadVBO)
        {
            glDeleteBuffers(
                1,
                &quadVBO);
        }
        if (quadVAO)
        {
            glDeleteVertexArrays(
                1,
                &quadVAO);
        }
        if (sceneProgram)
        {
            glDeleteProgram(
                sceneProgram);
        }
        if (blurProgram)
        {
            glDeleteProgram(
                blurProgram);
        }
        if (compositeProgram)
        {
            glDeleteProgram(
                compositeProgram);
        }
        if (temporalProgram)
        {
            glDeleteProgram(temporalProgram);
        }
        if (beamVBO != 0)
        {
            glDeleteBuffers(
                1,
                &beamVBO);
        }

        if (beamVAO != 0)
        {
            glDeleteVertexArrays(
                1,
                &beamVAO);
        }
        if (beamProgram != 0)
        {
            glDeleteProgram(
                beamProgram);
        }

        if (backgroundProgram != 0)
        {
            glDeleteProgram(
                backgroundProgram);
        }
        if (environmentHDR != 0)
        {
            glDeleteTextures(
                1,
                &environmentHDR);

            environmentHDR =
                0;
        }
        glDeleteQueries(
            2,
            sceneQueries);

        glDeleteQueries(
            2,
            blurQueries);

        glDeleteQueries(
            2,
            compositeQueries);
    }
    // ========================================================
    // File Loading
    // ========================================================
    std::string loadFileToString(
        const std::string &filepath)
    {
        std::ifstream file(filepath);
        if (!file.is_open())
        {
            throw std::runtime_error(
                "Failed to open shader file: " +
                filepath);
        }
        std::stringstream buffer;
        buffer << file.rdbuf();
        return buffer.str();
    }
    // ========================================================
    // Shader Parsing
    // ========================================================
    std::map<std::string, std::string>
    splitShaderSource(
        const std::string &src)
    {
        std::map<std::string, std::string> markers = {
            {"meshVertex",
             "//#MESH_VERTEX_SHADER"},

            {"fullscreenVertex",
             "//#FULLSCREEN_VERTEX_SHADER"},

            {"scene",
             "//#SCENE_FRAGMENT_SHADER"},

            {"blur",
             "//#BLUR_FRAGMENT_SHADER"},

            {"temporal",
             "//#TEMPORAL_FRAGMENT_SHADER"},

            {"composite",
             "//#COMPOSITE_FRAGMENT_SHADER"},

            {"backgroundVertex",
             "//#BACKGROUND_VERTEX_SHADER"},

            {"background",
             "//#BACKGROUND_FRAGMENT_SHADER"},

            {"beamVertex",
             "//#BEAM_VERTEX_SHADER"},

            {"beamFragment",
             "//#BEAM_FRAGMENT_SHADER"}};
        std::map<std::string, std::string>
            sections;
        for (auto const &[key, marker] : markers)
        {
            size_t start =
                src.find(marker);
            if (start == std::string::npos)
            {
                throw std::runtime_error(
                    "Missing GLSL marker: " +
                    marker);
            }
            start += marker.length();
            size_t end =
                src.length();
            for (auto const &[otherKey, otherMarker] : markers)
            {
                size_t pos =
                    src.find(
                        otherMarker,
                        start);
                if (
                    pos != std::string::npos &&
                    pos < end)
                {
                    end = pos;
                }
            }
            sections[key] =
                src.substr(
                    start,
                    end - start);
        }
        return sections;
    }
    // ========================================================
    // Shader Compilation + Linking
    // ========================================================
    GLuint buildProgram(
        const std::string &vsSrc,
        const std::string &fsSrc)
    {
        auto compileShader =
            [](const std::string &src,
               GLenum type) -> GLuint
        {
            GLuint shader =
                glCreateShader(type);
            const char *code =
                src.c_str();
            glShaderSource(
                shader,
                1,
                &code,
                nullptr);
            glCompileShader(shader);
            GLint success =
                GL_FALSE;
            glGetShaderiv(
                shader,
                GL_COMPILE_STATUS,
                &success);
            if (!success)
            {
                char infoLog[2048];
                glGetShaderInfoLog(
                    shader,
                    sizeof(infoLog),
                    nullptr,
                    infoLog);
                std::cerr
                    << "Shader Compile Error:\n"
                    << infoLog
                    << std::endl;
                glDeleteShader(shader);
                throw std::runtime_error(
                    "Failed to compile GLSL shader.");
            }
            return shader;
        };
        GLuint vs =
            compileShader(
                vsSrc,
                GL_VERTEX_SHADER);
        GLuint fs = 0;
        try
        {
            fs =
                compileShader(
                    fsSrc,
                    GL_FRAGMENT_SHADER);
        }
        catch (...)
        {
            glDeleteShader(vs);
            throw;
        }
        GLuint program =
            glCreateProgram();
        glAttachShader(
            program,
            vs);
        glAttachShader(
            program,
            fs);
        glLinkProgram(program);
        GLint success =
            GL_FALSE;
        glGetProgramiv(
            program,
            GL_LINK_STATUS,
            &success);
        if (!success)
        {
            char infoLog[2048];
            glGetProgramInfoLog(
                program,
                sizeof(infoLog),
                nullptr,
                infoLog);
            std::cerr
                << "Program Link Error:\n"
                << infoLog
                << std::endl;
            glDeleteProgram(program);
            glDeleteShader(vs);
            glDeleteShader(fs);
            throw std::runtime_error(
                "Failed to link GLSL program.");
        }
        glDeleteShader(vs);
        glDeleteShader(fs);
        return program;
    }
    // ========================================================
    // Prism Mesh
    // ========================================================
    void createPrismMesh()
    {
        struct Vertex
        {
            float px;
            float py;
            float pz;
            float nx;
            float ny;
            float nz;
        };
        std::vector<Vertex> vertices;
        // Extrusion depth.
        const float zFront = hero::prismVertices[0].z;
        const float zBack = hero::prismVertices[3].z;
        // Triangle cross-section.
        const auto &pv = hero::prismVertices;
        Vec3 A = {pv[0].x, pv[0].y, 0}, B = {pv[1].x, pv[1].y, 0}, C = {pv[2].x, pv[2].y, 0};
        // ----------------------------------------------------
        // Helper for generating a triangle with a flat normal.
        // ----------------------------------------------------
        auto addTriangle =
            [&](Vec3 p0,
                Vec3 p1,
                Vec3 p2)
        {
            Vec3 e1 =
                p1 - p0;
            Vec3 e2 =
                p2 - p0;
            Vec3 n = normalize({e1.y * e2.z -
                                    e1.z * e2.y,
                                e1.z * e2.x -
                                    e1.x * e2.z,
                                e1.x * e2.y -
                                    e1.y * e2.x});
            vertices.push_back({p0.x,
                                p0.y,
                                p0.z,
                                n.x,
                                n.y,
                                n.z});
            vertices.push_back({p1.x,
                                p1.y,
                                p1.z,
                                n.x,
                                n.y,
                                n.z});
            vertices.push_back({p2.x,
                                p2.y,
                                p2.z,
                                n.x,
                                n.y,
                                n.z});
        };
        auto F =
            [&](Vec3 p)
        {
            return Vec3{
                p.x,
                p.y,
                zFront};
        };
        auto Back =
            [&](Vec3 p)
        {
            return Vec3{
                p.x,
                p.y,
                zBack};
        };
        // ====================================================
        // Front Cap
        //
        // Winding gives +Z normal.
        // ====================================================
        addTriangle(
            F(A),
            F(B),
            F(C));
        // ====================================================
        // Back Cap
        //
        // Reverse winding gives -Z normal.
        // ====================================================
        addTriangle(
            Back(A),
            Back(C),
            Back(B));
        // ====================================================
        // Side A-B
        // ====================================================
        addTriangle(
            F(A),
            Back(A),
            F(B));
        addTriangle(
            F(B),
            Back(A),
            Back(B));
        // ====================================================
        // Side B-C
        // ====================================================
        addTriangle(
            F(B),
            Back(B),
            F(C));
        addTriangle(
            F(C),
            Back(B),
            Back(C));
        // ====================================================
        // Side C-A
        // ====================================================
        addTriangle(
            F(C),
            Back(C),
            F(A));
        addTriangle(
            F(A),
            Back(C),
            Back(A));
        // ====================================================
        // Upload mesh to GPU
        // ====================================================
        prismVertexCount =
            static_cast<GLsizei>(
                vertices.size());
        glGenVertexArrays(
            1,
            &prismVAO);
        glGenBuffers(
            1,
            &prismVBO);
        glBindVertexArray(
            prismVAO);
        glBindBuffer(
            GL_ARRAY_BUFFER,
            prismVBO);
        glBufferData(
            GL_ARRAY_BUFFER,
            vertices.size() *
                sizeof(Vertex),
            vertices.data(),
            GL_STATIC_DRAW);
        // ----------------------------------------------------
        // Position attribute
        // ----------------------------------------------------
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(
            0,
            3,
            GL_FLOAT,
            GL_FALSE,
            sizeof(Vertex),
            (void *)0);
        // ----------------------------------------------------
        // Normal attribute
        // ----------------------------------------------------
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(
            1,
            3,
            GL_FLOAT,
            GL_FALSE,
            sizeof(Vertex),
            (void *)(3 * sizeof(float)));
        glBindVertexArray(0);
    }

    void loadScene(
        ScenePreset preset)
    {
        historyValid = false;
        previousViewValid = false;
        previousViewProjectionValid = false;
        activeScenePreset =
            preset;

        if (preset == ScenePreset::HeroLab)
        {
            camera.position = {5.5f, 3.3f, 3.8f};
            camera.target = {1.5f, -.25f, -5.2f};
            camera.fovDegrees = 40;
        }
        else
        {
            camera.position = {0, 0, 18};
            camera.target = {0, 0, -10};
            camera.fovDegrees = 60;
        }
        SceneDescription scene =
            buildScene(
                preset);

        instances.clear();

        instances.reserve(
            scene.prisms.size());

        for (const ScenePrism &prism :
             scene.prisms)
        {
            PrismInstance instance;

            instance.position =
                {
                    prism.x,
                    prism.y,
                    prism.z};

            instance.phase =
                prism.phase;

            instances.push_back(
                instance);
        }

        visibleInstances.clear();

        visibleInstances.reserve(
            instances.size());

        if (backgroundTarget.fbo != 0)
            resize(outputWidth, outputHeight);

        // ----------------------------------------------------
        // Resize instance GPU storage for this scene.
        // ----------------------------------------------------

        glBindBuffer(
            GL_ARRAY_BUFFER,
            instanceVBO);

        glBufferData(
            GL_ARRAY_BUFFER,
            static_cast<GLsizeiptr>(
                instances.size() *
                sizeof(InstanceData)),
            nullptr,
            GL_DYNAMIC_DRAW);

        glBindBuffer(
            GL_ARRAY_BUFFER,
            0);
    }

    void createPrismInstances()
    {
        instances.clear();

        visibleInstances.reserve(
            instances.size());

        // --------------------------------------------------------
        // GPU instance buffer
        // --------------------------------------------------------

        glBindVertexArray(
            prismVAO);

        glGenBuffers(
            1,
            &instanceVBO);

        glBindBuffer(
            GL_ARRAY_BUFFER,
            instanceVBO);

        glBufferData(
            GL_ARRAY_BUFFER,
            instances.size() *
                sizeof(InstanceData),
            nullptr,
            GL_DYNAMIC_DRAW);

        GLsizei stride =
            sizeof(InstanceData);

        // --------------------------------------------------------
        // mat4 consumes four vec4 attribute locations:
        // 2, 3, 4, 5
        // --------------------------------------------------------

        for (int i = 0; i < 4; ++i)
        {
            GLuint location =
                2 + i;

            glEnableVertexAttribArray(
                location);

            glVertexAttribPointer(
                location,
                4,
                GL_FLOAT,
                GL_FALSE,
                stride,
                reinterpret_cast<void *>(
                    sizeof(float) *
                    4 *
                    i));

            glVertexAttribDivisor(
                location,
                1);
        }

        // --------------------------------------------------------
        // Optical LOD
        // 0 = full spectral optics
        // 1 = cheap far-field optics
        // --------------------------------------------------------

        glEnableVertexAttribArray(6);

        glVertexAttribPointer(
            6,
            1,
            GL_FLOAT,
            GL_FALSE,
            stride,
            reinterpret_cast<void *>(
                sizeof(Mat4)));

        glVertexAttribDivisor(
            6,
            1);

        glBindVertexArray(
            0);

        glBindBuffer(
            GL_ARRAY_BUFFER,
            0);

        // Load our initial showcase scene.
        loadScene(
            ScenePreset::HeroLab);
    }

    // ========================================================
    // Render Target Creation
    // ========================================================
    RenderTarget createRenderTarget(
        int w,
        int h,
        bool readableDepth = false)
    {
        RenderTarget rt;
        rt.width = w;
        rt.height = h;
        // ----------------------------------------------------
        // Framebuffer
        // ----------------------------------------------------
        glGenFramebuffers(
            1,
            &rt.fbo);
        glBindFramebuffer(
            GL_FRAMEBUFFER,
            rt.fbo);
        // ----------------------------------------------------
        // HDR color texture
        // ----------------------------------------------------
        glGenTextures(
            1,
            &rt.texture);
        glBindTexture(
            GL_TEXTURE_2D,
            rt.texture);
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA16F,
            w,
            h,
            0,
            GL_RGBA,
            GL_HALF_FLOAT,
            nullptr);
        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_MIN_FILTER,
            GL_LINEAR);
        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_MAG_FILTER,
            GL_LINEAR);
        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_WRAP_S,
            GL_CLAMP_TO_EDGE);
        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_WRAP_T,
            GL_CLAMP_TO_EDGE);
        glFramebufferTexture2D(
            GL_FRAMEBUFFER,
            GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D,
            rt.texture,
            0);
        // ----------------------------------------------------
        // Depth + stencil renderbuffer
        // ----------------------------------------------------
        if (readableDepth)
        {
            glGenTextures(1, &rt.depthTexture);
            glBindTexture(GL_TEXTURE_2D, rt.depthTexture);
            // Match the multisample depth-stencil format exactly so the resolve
            // remains valid on macOS OpenGL while the depth aspect stays sampleable.
            glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, w, h, 0,
                         GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nullptr);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                   GL_TEXTURE_2D, rt.depthTexture, 0);
        }
        else
        {
            glGenRenderbuffers(1, &rt.depthRBO);
            glBindRenderbuffer(GL_RENDERBUFFER, rt.depthRBO);
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                      GL_RENDERBUFFER, rt.depthRBO);
        }
        // ----------------------------------------------------
        // Validate framebuffer
        // ----------------------------------------------------
        if (
            glCheckFramebufferStatus(
                GL_FRAMEBUFFER) !=
            GL_FRAMEBUFFER_COMPLETE)
        {
            glBindFramebuffer(
                GL_FRAMEBUFFER,
                0);
            throw std::runtime_error(
                "Framebuffer completeness check failed.");
        }
        glBindFramebuffer(
            GL_FRAMEBUFFER,
            0);
        glBindRenderbuffer(
            GL_RENDERBUFFER,
            0);
        glBindTexture(
            GL_TEXTURE_2D,
            0);
        return rt;
    }

    RenderTarget createHistoryTarget(int w, int h)
    {
        RenderTarget rt;
        rt.width = w;
        rt.height = h;
        glGenFramebuffers(1, &rt.fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, rt.fbo);
        glGenTextures(1, &rt.texture);
        glBindTexture(GL_TEXTURE_2D, rt.texture);
        // Compact floating-point history: HDR range without an unused alpha channel.
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R11F_G11F_B10F, w, h, 0, GL_RGB, GL_FLOAT, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt.texture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            throw std::runtime_error("Temporal history framebuffer incomplete.");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
        return rt;
    }

    MultisampleTarget createMultisampleTarget(int w, int h, int requestedSamples)
    {
        MultisampleTarget rt;
        GLint maximum = 1;
        glGetIntegerv(GL_MAX_SAMPLES, &maximum);
        rt.samples = std::max(1, std::min(requestedSamples, maximum));
        rt.width = w;
        rt.height = h;
        glGenFramebuffers(1, &rt.fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, rt.fbo);
        glGenRenderbuffers(1, &rt.colorRBO);
        glBindRenderbuffer(GL_RENDERBUFFER, rt.colorRBO);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, rt.samples, GL_RGBA16F, w, h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rt.colorRBO);
        glGenRenderbuffers(1, &rt.depthRBO);
        glBindRenderbuffer(GL_RENDERBUFFER, rt.depthRBO);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, rt.samples, GL_DEPTH24_STENCIL8, w, h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rt.depthRBO);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            throw std::runtime_error("Multisample HDR framebuffer incomplete.");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
        return rt;
    }

    void destroyMultisampleTarget(MultisampleTarget &rt)
    {
        if (rt.colorRBO) glDeleteRenderbuffers(1, &rt.colorRBO);
        if (rt.depthRBO) glDeleteRenderbuffers(1, &rt.depthRBO);
        if (rt.fbo) glDeleteFramebuffers(1, &rt.fbo);
        rt = {};
    }
    // ========================================================
    // Render Target Destruction
    // ========================================================
    void destroyRenderTarget(
        RenderTarget &rt)
    {
        if (rt.depthRBO)
        {
            glDeleteRenderbuffers(
                1,
                &rt.depthRBO);
            rt.depthRBO = 0;
        }
        if (rt.texture)
        {
            glDeleteTextures(
                1,
                &rt.texture);
            rt.texture = 0;
        }
        if (rt.depthTexture)
        {
            glDeleteTextures(1, &rt.depthTexture);
            rt.depthTexture = 0;
        }
        if (rt.fbo)
        {
            glDeleteFramebuffers(
                1,
                &rt.fbo);
            rt.fbo = 0;
        }
        rt.width = 0;
        rt.height = 0;
    }
    // ========================================================
    // Resize
    // ========================================================
    void resize(
        int newWidth,
        int newHeight)
    {
        historyValid = false;
        previousViewValid = false;
        previousViewProjectionValid = false;
        if (
            newWidth <= 0 ||
            newHeight <= 0)
        {
            return;
        }
        outputWidth = newWidth;
        outputHeight = newHeight;
        const float scale = activeScenePreset == ScenePreset::HeroLab ? heroRenderScale : 1.0f;
        newWidth = static_cast<int>(std::round(newWidth * scale));
        newHeight = static_cast<int>(std::round(newHeight * scale));
        if (
            newWidth == width &&
            newHeight == height)
        {
            return;
        }
        width =
            newWidth;
        height =
            newHeight;
        blurWidth = std::max(1, outputWidth / 2);
        blurHeight = std::max(1, outputHeight / 2);
        // ----------------------------------------------------
        // Destroy old targets completely.
        // ----------------------------------------------------
        destroyRenderTarget(
            backgroundTarget);
        destroyRenderTarget(
            sceneTarget);
        destroyRenderTarget(
            blurTargetA);
        destroyRenderTarget(
            blurTargetB);
        destroyRenderTarget(historyTargets[0]);
        destroyRenderTarget(historyTargets[1]);
        destroyMultisampleTarget(multisampleTarget);

        // ----------------------------------------------------
        // Recreate targets at new framebuffer resolution.
        // ----------------------------------------------------

        backgroundTarget =
            createRenderTarget(
                width,
                height);
        sceneTarget =
            createRenderTarget(
                width,
                height,
                true);
        blurTargetA =
            createRenderTarget(
                blurWidth,
                blurHeight);
        blurTargetB =
            createRenderTarget(
                blurWidth,
                blurHeight);
        historyTargets[0] = createHistoryTarget(width, height);
        historyTargets[1] = createHistoryTarget(width, height);
        multisampleTarget = createMultisampleTarget(width, height, msaaSamples);
    }
    void updateHeroBeamGeometry()
    {
        beamVertices.clear();

        if (activeScenePreset !=
            ScenePreset::HeroLab)
        {
            beamVertexCount =
                0;

            return;
        }

        BeamOptics optics;

        optics.refractiveIndex =
            params.refractiveIndex;

        optics.dispersionC =
            params.dispersionC;

        optics.absorptionStrength =
            params.absorptionStrength;

        std::vector<BeamSegment> beams =
            buildHeroBeams(
                optics);

        // ----------------------------------------------------
        // The camera currently looks approximately along -Z,
        // so beam ribbons can live in XY and face it.
        //
        // When we add the orbit camera, we'll upgrade these
        // into true camera-facing ribbons.
        // ----------------------------------------------------

        for (const BeamSegment &beam :
             beams)
        {
            float dx =
                beam.endX -
                beam.startX;

            float dy =
                beam.endY -
                beam.startY;

            float length =
                std::sqrt(
                    dx * dx +
                    dy * dy);

            if (length <
                0.0001f)
            {
                continue;
            }

            dx /= length;
            dy /= length;

            float px =
                -dy *
                beam.width;

            float py =
                dx *
                beam.width;

            BeamVertex a =
                {
                    {beam.startX + px,
                     beam.startY + py,
                     beam.startZ},

                    {beam.color.r,
                     beam.color.g,
                     beam.color.b},

                    beam.intensity};

            BeamVertex b =
                {
                    {beam.startX - px,
                     beam.startY - py,
                     beam.startZ},

                    {beam.color.r,
                     beam.color.g,
                     beam.color.b},

                    beam.intensity};

            BeamVertex c =
                {
                    {beam.endX - px,
                     beam.endY - py,
                     beam.endZ},

                    {beam.color.r,
                     beam.color.g,
                     beam.color.b},

                    beam.intensity};

            BeamVertex d =
                {
                    {beam.endX + px,
                     beam.endY + py,
                     beam.endZ},

                    {beam.color.r,
                     beam.color.g,
                     beam.color.b},

                    beam.intensity};

            // Triangle 1
            beamVertices.push_back(a);
            beamVertices.push_back(b);
            beamVertices.push_back(c);

            // Triangle 2
            beamVertices.push_back(a);
            beamVertices.push_back(c);
            beamVertices.push_back(d);
        }

        beamVertexCount =
            static_cast<GLsizei>(
                beamVertices.size());

        glBindBuffer(
            GL_ARRAY_BUFFER,
            beamVBO);

        if (!beamVertices.empty())
        {
            glBufferData(
                GL_ARRAY_BUFFER,
                static_cast<GLsizeiptr>(
                    beamVertices.size() *
                    sizeof(BeamVertex)),
                beamVertices.data(),
                GL_DYNAMIC_DRAW);
        }

        glBindBuffer(
            GL_ARRAY_BUFFER,
            0);
    }
    void createBeamMesh()
    {
        glGenVertexArrays(
            1,
            &beamVAO);

        glGenBuffers(
            1,
            &beamVBO);

        glBindVertexArray(
            beamVAO);

        glBindBuffer(
            GL_ARRAY_BUFFER,
            beamVBO);

        glBufferData(
            GL_ARRAY_BUFFER,
            sizeof(BeamVertex) *
                64,
            nullptr,
            GL_DYNAMIC_DRAW);

        // Position.
        glEnableVertexAttribArray(
            0);

        glVertexAttribPointer(
            0,
            3,
            GL_FLOAT,
            GL_FALSE,
            sizeof(BeamVertex),
            reinterpret_cast<void *>(
                offsetof(
                    BeamVertex,
                    position)));

        // Color.
        glEnableVertexAttribArray(
            1);

        glVertexAttribPointer(
            1,
            3,
            GL_FLOAT,
            GL_FALSE,
            sizeof(BeamVertex),
            reinterpret_cast<void *>(
                offsetof(
                    BeamVertex,
                    color)));

        // Intensity.
        glEnableVertexAttribArray(
            2);

        glVertexAttribPointer(
            2,
            1,
            GL_FLOAT,
            GL_FALSE,
            sizeof(BeamVertex),
            reinterpret_cast<void *>(
                offsetof(
                    BeamVertex,
                    intensity)));

        glBindVertexArray(
            0);

        glBindBuffer(
            GL_ARRAY_BUFFER,
            0);
    }
    // ========================================================
    // Initialization
    // ========================================================
    void init(
        int initialWidth,
        int initialHeight)
    {
        outputWidth = initialWidth;
        outputHeight = initialHeight;
        initialWidth = static_cast<int>(std::round(initialWidth * heroRenderScale));
        initialHeight = static_cast<int>(std::round(initialHeight * heroRenderScale));
        width =
            initialWidth;
        height =
            initialHeight;
        blurWidth = std::max(1, outputWidth / 2);
        blurHeight = std::max(1, outputHeight / 2);
        // ====================================================
        // 1. Load + Parse Shader File
        // ====================================================
        std::string rawSrc =
            loadFileToString(
                ENGINE_SHADER_PATH);
        auto sections =
            splitShaderSource(
                rawSrc);
        const std::string glslHeader =
            "#version 330 core\n";
        // ====================================================
        // 2. Build Shader Programs
        // ====================================================
        sceneProgram =
            buildProgram(
                glslHeader +
                    sections["meshVertex"],
                glslHeader +
                    sections["scene"]);
        blurProgram =
            buildProgram(
                glslHeader +
                    sections["fullscreenVertex"],
                glslHeader +
                    sections["blur"]);
        temporalProgram =
            buildProgram(
                glslHeader +
                    sections["fullscreenVertex"],
                glslHeader +
                    sections["temporal"]);
        compositeProgram =
            buildProgram(
                glslHeader +
                    sections["fullscreenVertex"],
                glslHeader +
                    sections["composite"]);
        backgroundProgram =
            buildProgram(
                glslHeader +
                    sections["backgroundVertex"],
                glslHeader +
                    sections["background"]);

        beamProgram =
            buildProgram(
                glslHeader +
                    sections["beamVertex"],
                glslHeader +
                    sections["beamFragment"]);

        // ====================================================
        // 3. Cache Uniform Locations
        // ====================================================
        sceneUniforms["uResolution"] =
            glGetUniformLocation(
                sceneProgram,
                "uResolution");
        sceneUniforms["uTime"] =
            glGetUniformLocation(
                sceneProgram,
                "uTime");
        sceneUniforms["uRefractiveIndex"] =
            glGetUniformLocation(
                sceneProgram,
                "uRefractiveIndex");
        sceneUniforms["uDispersionC"] =
            glGetUniformLocation(
                sceneProgram,
                "uDispersionC");
        sceneUniforms["uAbsorptionStrength"] =
            glGetUniformLocation(
                sceneProgram,
                "uAbsorptionStrength");

        sceneUniforms["uDebugMode"] =
            glGetUniformLocation(
                sceneProgram,
                "uDebugMode");
        sceneUniforms["uModel"] =
            glGetUniformLocation(
                sceneProgram,
                "uModel");
        sceneUniforms["uInvModel"] =
            glGetUniformLocation(
                sceneProgram,
                "uInvModel");
        sceneUniforms["uView"] =
            glGetUniformLocation(
                sceneProgram,
                "uView");
        sceneUniforms["uProjection"] =
            glGetUniformLocation(
                sceneProgram,
                "uProjection");
        sceneUniforms["uCameraPosition"] =
            glGetUniformLocation(
                sceneProgram,
                "uCameraPosition");
        sceneUniforms["uSceneColor"] =
            glGetUniformLocation(
                sceneProgram,
                "uSceneColor");
        sceneUniforms["uUseSceneColor"] =
            glGetUniformLocation(
                sceneProgram,
                "uUseSceneColor");
        sceneUniforms["uEnvironment"] =
            glGetUniformLocation(
                sceneProgram,
                "uEnvironment");
        blurUniforms["uSource"] =
            glGetUniformLocation(
                blurProgram,
                "uSource");
        blurUniforms["uSourceResolution"] =
            glGetUniformLocation(
                blurProgram,
                "uSourceResolution");
        blurUniforms["uTargetResolution"] =
            glGetUniformLocation(
                blurProgram,
                "uTargetResolution");
        blurUniforms["uDirection"] =
            glGetUniformLocation(
                blurProgram,
                "uDirection");
        compositeUniforms["uScene"] =
            glGetUniformLocation(
                compositeProgram,
                "uScene");
        compositeUniforms["uBloom"] =
            glGetUniformLocation(
                compositeProgram,
                "uBloom");
        compositeUniforms["uResolution"] =
            glGetUniformLocation(
                compositeProgram,
                "uResolution");
        compositeUniforms["uBloomStrength"] =
            glGetUniformLocation(
                compositeProgram,
                "uBloomStrength");
        compositeUniforms["uDebugMode"] =
            glGetUniformLocation(
                compositeProgram,
                "uDebugMode");
        backgroundUniforms["uEnvironment"] =
            glGetUniformLocation(
                backgroundProgram,
                "uEnvironment");

        backgroundUniforms["uCameraForward"] =
            glGetUniformLocation(
                backgroundProgram,
                "uCameraForward");

        backgroundUniforms["uCameraRight"] =
            glGetUniformLocation(
                backgroundProgram,
                "uCameraRight");

        backgroundUniforms["uCameraUp"] =
            glGetUniformLocation(
                backgroundProgram,
                "uCameraUp");

        backgroundUniforms["uTanHalfFov"] =
            glGetUniformLocation(
                backgroundProgram,
                "uTanHalfFov");

        backgroundUniforms["uAspect"] =
            glGetUniformLocation(
                backgroundProgram,
                "uAspect");

        backgroundUniforms["uEnvironmentRotation"] =
            glGetUniformLocation(
                backgroundProgram,
                "uEnvironmentRotation");
        beamUniforms["uView"] =
            glGetUniformLocation(
                beamProgram,
                "uView");
        beamUniforms["uProjection"] =
            glGetUniformLocation(
                beamProgram,
                "uProjection");
        // ====================================================
        // 4. Fullscreen Quad
        // ====================================================
        float quadVertices[] = {
            -1.0f, -1.0f,
            1.0f, -1.0f,
            -1.0f, 1.0f,
            -1.0f, 1.0f,
            1.0f, -1.0f,
            1.0f, 1.0f};
        glGenVertexArrays(
            1,
            &quadVAO);
        glGenBuffers(
            1,
            &quadVBO);
        glBindVertexArray(
            quadVAO);
        glBindBuffer(
            GL_ARRAY_BUFFER,
            quadVBO);
        glBufferData(
            GL_ARRAY_BUFFER,
            sizeof(quadVertices),
            quadVertices,
            GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(
            0,
            2,
            GL_FLOAT,
            GL_FALSE,
            2 * sizeof(float),
            (void *)0);
        glBindVertexArray(0);
        // ====================================================
        // 5. Create Prism Geometry
        // ====================================================
        createPrismMesh();
        createPrismInstances();
        createBeamMesh();
        heroRenderer.init(ENGINE_HERO_SHADER_PATH, ENGINE_ASSET_PATH);
        // ========================================================
        // GPU timer queries
        // ========================================================

        glGenQueries(
            2,
            sceneQueries);

        glGenQueries(
            2,
            blurQueries);

        glGenQueries(
            2,
            compositeQueries);

        // ====================================================
        // 6. Load production assets
        // ====================================================

        environmentHDR =
            loadHDRTexture(
                ENGINE_ASSET_PATH
                "/hdri/studio_small_03_2k.hdr");
        // ====================================================
        // 7. Create HDR Render Targets
        // ====================================================
        backgroundTarget =
            createRenderTarget(
                width,
                height);
        sceneTarget =
            createRenderTarget(
                width,
                height,
                true);
        blurTargetA =
            createRenderTarget(
                blurWidth,
                blurHeight);
        blurTargetB =
            createRenderTarget(
                blurWidth,
                blurHeight);
        historyTargets[0] = createHistoryTarget(width, height);
        historyTargets[1] = createHistoryTarget(width, height);
        multisampleTarget = createMultisampleTarget(width, height, msaaSamples);
    }

    void handleInput(
        GLFWwindow *window,
        float deltaTime)
    {
        bool qualityDown = glfwGetKey(window, GLFW_KEY_F8) == GLFW_PRESS;
        if (qualityDown && !qualityKeyWasDown) {
            heroRenderScale = heroRenderScale < 1.5f ? 1.5f : (heroRenderScale < 2 ? 2.0f : 1.0f);
            resize(outputWidth, outputHeight);
        }
        qualityKeyWasDown = qualityDown;
        const bool demoDown=glfwGetKey(window,GLFW_KEY_F9)==GLFW_PRESS;
        if(demoDown && !demoKeyWasDown) {
            cameraDemo=!cameraDemo;
            if(!cameraDemo)heroRenderer.clearCameraFrame();
            loadScene(ScenePreset::HeroLab);
            glfwSetWindowAspectRatio(window,cameraDemo?16:GLFW_DONT_CARE,cameraDemo?9:GLFW_DONT_CARE);
        }
        demoKeyWasDown=demoDown;
        const bool taaDown=glfwGetKey(window,GLFW_KEY_F10)==GLFW_PRESS;
        if(taaDown && !taaKeyWasDown) {
            taaEnabled=!taaEnabled;
            historyValid=false;
        }
        taaKeyWasDown=taaDown;
        const bool msaaDown=glfwGetKey(window,GLFW_KEY_F11)==GLFW_PRESS;
        if(msaaDown && !msaaKeyWasDown) {
            msaaSamples=msaaSamples==1?2:(msaaSamples==2?4:1);
            width=0;
            resize(outputWidth,outputHeight);
        }
        msaaKeyWasDown=msaaDown;
        bool space = glfwGetKey(window, GLFW_KEY_SPACE) == GLFW_PRESS;
        if (space && !spaceWasDown)
            heroPaused = !heroPaused;
        spaceWasDown = space;
        if (!heroPaused)
            heroTime += deltaTime;
        if (glfwGetKey(window, GLFW_KEY_A) == GLFW_PRESS)
            heroYaw -= deltaTime * .3f;
        if (glfwGetKey(window, GLFW_KEY_D) == GLFW_PRESS)
            heroYaw += deltaTime * .3f;
        if (glfwGetKey(window, GLFW_KEY_Q) == GLFW_PRESS)
            exposure *= std::exp(-deltaTime);
        if (glfwGetKey(window, GLFW_KEY_E) == GLFW_PRESS)
            exposure *= std::exp(deltaTime);
        exposure = std::clamp(exposure, .05f, 8.f);
        const float nSpeed = 0.35f;
        const float dispersionSpeed = 0.025f;
        const float absorptionSpeed = 1.0f;
        const float bloomSpeed = 1.0f;

        // --------------------------------------------------------
        // Reset parameters to default values.
        // --------------------------------------------------------
        if (glfwGetKey(
                window,
                GLFW_KEY_R) == GLFW_PRESS)
        {
            heroYaw = 0;
            heroTime = 0;
            exposure = 1;
            params.refractiveIndex =
                1.5046f;

            params.dispersionC =
                0.00420f;

            params.absorptionStrength =
                1.0f;

            params.bloomStrength =
                0.12f;
        }

        // --------------------------------------------------------
        // Rendering architecture
        //
        // I = GPU instancing
        // N = naive one-draw-per-object
        // --------------------------------------------------------

        if (glfwGetKey(
                window,
                GLFW_KEY_I) == GLFW_PRESS)
        {
            useInstancing = true;
        }

        if (glfwGetKey(
                window,
                GLFW_KEY_N) == GLFW_PRESS)
        {
            useInstancing = false;
        }

        // --------------------------------------------------------
        // Enable / Disable Culling and Optical LOD.
        // --------------------------------------------------------

        if (glfwGetKey(
                window,
                GLFW_KEY_C) == GLFW_PRESS)
        {
            enableCulling = true;
        }

        if (glfwGetKey(
                window,
                GLFW_KEY_V) == GLFW_PRESS)
        {
            enableCulling = false;
        }

        if (glfwGetKey(
                window,
                GLFW_KEY_L) == GLFW_PRESS)
        {
            enableOpticalLOD = true;
        }

        if (glfwGetKey(
                window,
                GLFW_KEY_K) == GLFW_PRESS)
        {
            enableOpticalLOD = false;
        }

        if (glfwGetKey(window, GLFW_KEY_UP) == GLFW_PRESS)
            params.refractiveIndex += nSpeed * deltaTime;

        if (glfwGetKey(window, GLFW_KEY_DOWN) == GLFW_PRESS)
            params.refractiveIndex -= nSpeed * deltaTime;

        // --------------------------------------------------------
        // Cauchy dispersion coefficient
        // --------------------------------------------------------

        if (glfwGetKey(window, GLFW_KEY_RIGHT) == GLFW_PRESS)
            params.dispersionC += dispersionSpeed * deltaTime;

        if (glfwGetKey(window, GLFW_KEY_LEFT) == GLFW_PRESS)
            params.dispersionC -= dispersionSpeed * deltaTime;

        // --------------------------------------------------------
        // Beer-Lambert absorption
        // --------------------------------------------------------

        if (glfwGetKey(window, GLFW_KEY_RIGHT_BRACKET) == GLFW_PRESS)
            params.absorptionStrength += absorptionSpeed * deltaTime;

        if (glfwGetKey(window, GLFW_KEY_LEFT_BRACKET) == GLFW_PRESS)
            params.absorptionStrength -= absorptionSpeed * deltaTime;

        // --------------------------------------------------------
        // Bloom
        // --------------------------------------------------------

        if (glfwGetKey(window, GLFW_KEY_EQUAL) == GLFW_PRESS)
            params.bloomStrength += bloomSpeed * deltaTime;

        if (glfwGetKey(window, GLFW_KEY_MINUS) == GLFW_PRESS)
            params.bloomStrength -= bloomSpeed * deltaTime;

        // --------------------------------------------------------
        // Debug views
        // --------------------------------------------------------

        if (glfwGetKey(window, GLFW_KEY_1) == GLFW_PRESS)
            params.debugMode = 0;

        if (glfwGetKey(window, GLFW_KEY_2) == GLFW_PRESS)
            params.debugMode = 1;

        if (glfwGetKey(window, GLFW_KEY_3) == GLFW_PRESS)
            params.debugMode = 2;

        if (glfwGetKey(window, GLFW_KEY_4) == GLFW_PRESS)
            params.debugMode = 3;

        if (glfwGetKey(window, GLFW_KEY_5) == GLFW_PRESS)
            params.debugMode = 4;

        if (glfwGetKey(window, GLFW_KEY_6) == GLFW_PRESS)
            params.debugMode = 5;

        if (glfwGetKey(window, GLFW_KEY_7) == GLFW_PRESS)
            params.debugMode = 6;

        // --------------------------------------------------------
        // Keep parameters sane.
        // --------------------------------------------------------

        params.refractiveIndex =
            std::clamp(
                params.refractiveIndex,
                1.001f,
                2.0f);

        params.dispersionC =
            std::clamp(
                params.dispersionC,
                0.0f,
                0.075f);

        params.absorptionStrength =
            std::clamp(
                params.absorptionStrength,
                0.0f,
                3.0f);

        params.bloomStrength =
            std::clamp(
                params.bloomStrength,
                0.0f,
                2.5f);
    }

    bool isSphereVisible(
        Vec3 center,
        float radius) const
    {
        Vec3 forward =
            normalize(
                camera.target -
                camera.position);

        Vec3 worldUp =
            {0.0f, 1.0f, 0.0f};

        Vec3 right =
            normalize(
                {forward.y * worldUp.z -
                     forward.z * worldUp.y,

                 forward.z * worldUp.x -
                     forward.x * worldUp.z,

                 forward.x * worldUp.y -
                     forward.y * worldUp.x});

        Vec3 up =
            {
                right.y * forward.z -
                    right.z * forward.y,

                right.z * forward.x -
                    right.x * forward.z,

                right.x * forward.y -
                    right.y * forward.x};

        Vec3 relative =
            center -
            camera.position;

        float depth =
            dot(relative, forward);

        if (depth + radius <
            camera.nearPlane)
        {
            return false;
        }

        if (depth - radius >
            camera.farPlane)
        {
            return false;
        }

        if (depth <= 0.0f)
            return false;

        float fovRadians =
            camera.fovDegrees *
            3.14159265358979323846f /
            180.0f;

        float halfHeight =
            depth *
            std::tan(
                fovRadians * 0.5f);

        float aspect =
            static_cast<float>(width) /
            static_cast<float>(
                std::max(height, 1));

        float halfWidth =
            halfHeight *
            aspect;

        float horizontal =
            std::abs(
                dot(relative, right));

        float vertical =
            std::abs(
                dot(relative, up));

        if (horizontal >
            halfWidth + radius)
        {
            return false;
        }

        if (vertical >
            halfHeight + radius)
        {
            return false;
        }

        return true;
    }

    // ========================================================
    // Render
    // ========================================================
    void render(float timeSec)
    { // ========================================================
        // Camera state
        // ========================================================

        if (activeScenePreset == ScenePreset::HeroLab) {
            if (frameProvider) {
                if (auto frame = frameProvider(timeSec)) heroRenderer.setCameraFrame(std::move(*frame));
            }
            if (cameraDemo && !heroRenderer.isSyntheticDemo()) {
                // Fixed test pose independent of frame-to-frame tracked camera updates.
                auto cameraPose = inverseRigid(lookAt({5.5f,3.3f,3.8f},{1.5f,-.25f,-5.2f},{0,1,0}));
                hero::Transform pose;
                std::copy(cameraPose.m,cameraPose.m+16,pose.begin());
                camera_input::Intrinsics k{640,360,494.546f,494.546f,320,180};
                heroRenderer.setSyntheticDemo(k,pose);
            }
            if(cameraDemo)heroRenderer.setSyntheticTime(timeSec);
            if (heroRenderer.hasCameraFrame()) {
                const auto& pose=heroRenderer.cameraFrame().cameraToWorld;
                auto p=hero::point(pose,{}),f=hero::vector(pose,{0,0,-1});
                camera.position={p.x,p.y,p.z};camera.target={p.x+f.x,p.y+f.y,p.z+f.z};
            }
        }
        float aspect =
            static_cast<float>(width) /
            static_cast<float>(height);

        float fovRadians =
            camera.fovDegrees *
            3.14159265359f /
            180.0f;

        float tanHalfFov =
            std::tan(
                fovRadians *
                0.5f);

        Vec3 cameraForward =
            normalize(
                camera.target -
                camera.position);

        Vec3 worldUp =
            {
                0.0f,
                1.0f,
                0.0f};

        Vec3 cameraRight =
            normalize(
                {cameraForward.y *
                         worldUp.z -
                     cameraForward.z *
                         worldUp.y,

                 cameraForward.z *
                         worldUp.x -
                     cameraForward.x *
                         worldUp.z,

                 cameraForward.x *
                         worldUp.y -
                     cameraForward.y *
                         worldUp.x});

        Vec3 cameraUp =
            normalize(
                {cameraRight.y *
                         cameraForward.z -
                     cameraRight.z *
                         cameraForward.y,

                 cameraRight.z *
                         cameraForward.x -
                     cameraRight.x *
                         cameraForward.z,

                 cameraRight.x *
                         cameraForward.y -
                     cameraRight.y *
                         cameraForward.x});

        Mat4 view =
            lookAt(
                camera.position,
                camera.target,
                worldUp);

        Mat4 projection =
            perspective(
                fovRadians,
                aspect,
                camera.nearPlane,
                camera.farPlane);

        const bool cameraInput = activeScenePreset == ScenePreset::HeroLab && heroRenderer.hasCameraFrame();
        if (cameraInput) {
            const auto& frame=heroRenderer.cameraFrame();
            const auto inverse=hero::inverseRigid(frame.cameraToWorld);
            const auto calibrated=frame.intrinsics.projection(camera.nearPlane,camera.farPlane);
            std::copy(inverse.begin(),inverse.end(),view.m);
            std::copy(calibrated.begin(),calibrated.end(),projection.m);
            auto r=hero::vector(frame.cameraToWorld,{1,0,0});
            auto u=hero::vector(frame.cameraToWorld,{0,1,0});
            cameraRight={r.x,r.y,r.z};cameraUp={u.x,u.y,u.z};
        }

        // Reset temporal history on tracked-camera jumps. Fine object motion is
        // handled in the temporal shader with neighborhood and luminance rejection.
        if (previousViewValid)
        {
            float maximumDelta = 0.0f;
            for (int i = 0; i < 16; ++i)
                maximumDelta = std::max(maximumDelta, std::abs(view.m[i] - previousView.m[i]));
            if (maximumDelta > 0.08f)
                historyValid = false;
        }
        previousView = view;
        previousViewValid = true;

        if (taaEnabled && params.debugMode == 0)
        {
            static constexpr float jitter[8][2] = {
                {0.0f, -0.166667f}, {-0.25f, 0.166667f}, {0.25f, -0.388889f},
                {-0.375f, -0.055556f}, {0.125f, 0.277778f}, {-0.125f, -0.277778f},
                {0.375f, 0.055556f}, {-0.4375f, 0.388889f}};
            const auto &sample = jitter[temporalFrame & 7];
            projection.m[8] += 2.0f * sample[0] / static_cast<float>(width);
            projection.m[9] += 2.0f * sample[1] / static_cast<float>(height);
            ++temporalFrame;
        }
        const Mat4 currentViewProjection = multiply(projection, view);
        const Mat4 inverseViewProjection = inverseMatrix(currentViewProjection);

        // ========================================================
        if (activeScenePreset == ScenePreset::HeroLab)
        {
            updateHeroModel();
            heroRenderer.accumulate(opticalModel(), heroSettings);
        }
        // PASS 0
        //
        // Render the opaque/background environment into its own
        // HDR texture.
        //
        // The prism will later sample this texture.
        // ========================================================

        glBindFramebuffer(
            GL_FRAMEBUFFER,
            multisampleTarget.fbo);

        glViewport(
            0,
            0,
            width,
            height);

        glDisable(
            GL_DEPTH_TEST);

        glClearColor(
            0.006f,
            0.008f,
            0.014f,
            1.0f);

        glClear(
            GL_COLOR_BUFFER_BIT |
            GL_DEPTH_BUFFER_BIT);

        if (cameraInput) {
            heroRenderer.drawCamera(projection.m);
        }
        else if (activeScenePreset == ScenePreset::HeroLab)
        {
            glUseProgram(
                backgroundProgram);

            glActiveTexture(
                GL_TEXTURE0);

            glBindTexture(
                GL_TEXTURE_2D,
                environmentHDR);

            glUniform1i(
                backgroundUniforms["uEnvironment"],
                0);

            glUniform3f(
                backgroundUniforms["uCameraForward"],
                cameraForward.x,
                cameraForward.y,
                cameraForward.z);

            glUniform3f(
                backgroundUniforms["uCameraRight"],
                cameraRight.x,
                cameraRight.y,
                cameraRight.z);

            glUniform3f(
                backgroundUniforms["uCameraUp"],
                cameraUp.x,
                cameraUp.y,
                cameraUp.z);

            glUniform1f(
                backgroundUniforms["uTanHalfFov"],
                tanHalfFov);

            glUniform1f(
                backgroundUniforms["uAspect"],
                aspect);

            glUniform1f(
                backgroundUniforms["uEnvironmentRotation"],
                0.0f);

            glBindVertexArray(
                quadVAO);

            glDrawArrays(
                GL_TRIANGLES,
                0,
                6);

            glBindVertexArray(
                0);
        }

        // ========================================================
        if (activeScenePreset == ScenePreset::HeroLab && !cameraInput)
            heroRenderer.draw(view.m, projection.m, {camera.position.x, camera.position.y, camera.position.z}, environmentHDR, opticalModel(), heroSettings);
        // Resolve the opaque MSAA scene for screen-space glass refraction.
        glBindFramebuffer(GL_READ_FRAMEBUFFER, multisampleTarget.fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, backgroundTarget.fbo);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                          GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        // PASS 1
        //
        // Continue in the multisample HDR target. The prism samples the resolved
        // opaque background while polygon coverage remains four-sample MSAA.
        // ========================================================

        glBindFramebuffer(
            GL_FRAMEBUFFER,
            multisampleTarget.fbo);

        glViewport(
            0,
            0,
            width,
            height);

        glEnable(
            GL_DEPTH_TEST);

        glDepthFunc(
            GL_LESS);

        // Color already came from backgroundTarget.
        // Only reset depth.
        // Receiver depth was copied with color; retain it for glass occlusion.

        // ========================================================
        // Build visible instance list
        // ========================================================

        auto cullingStart =
            std::chrono::high_resolution_clock::now();
        visibleInstances.clear();
        // ========================================================
        // Build visible instance list
        // ========================================================

        visibleInstances.clear();

        visibleInstanceCount = 0;
        culledInstanceCount = 0;

        fullOpticsCount = 0;
        cheapOpticsCount = 0;

        constexpr float boundingRadius =
            1.3f;

        constexpr float opticalLODStart =
            28.0f;

        for (const PrismInstance &instance :
             instances)
        {
            bool visible =
                cameraInput || !enableCulling ||
                isSphereVisible(
                    instance.position,
                    boundingRadius);

            if (!visible)
            {
                culledInstanceCount++;
                continue;
            }

            Vec3 delta =
                instance.position -
                camera.position;

            float distance =
                std::sqrt(
                    dot(delta, delta));

            float opticalLOD = 0.0f;
            bool allowOpticalLOD =
                enableOpticalLOD &&
                activeScenePreset !=
                    ScenePreset::HeroLab;

            if (allowOpticalLOD &&
                distance >
                    opticalLODStart)
            {
                opticalLOD =
                    1.0f;
            }

            if (opticalLOD < 0.5f)
                fullOpticsCount++;
            else
                cheapOpticsCount++;

            float rotationSpeed =
                0.30f;

            float wobbleStrength =
                0.18f;

            if (activeScenePreset ==
                ScenePreset::HeroLab)
            {
                rotationSpeed =
                    0.16f;

                wobbleStrength =
                    0.10f;
            }
            Mat4 rotation =
                multiply(
                    rotationY(
                        timeSec *
                            rotationSpeed +
                        instance.phase),
                    rotationX(
                        std::sin(
                            timeSec * 0.22f +
                            instance.phase) *
                        wobbleStrength));

            Mat4 model =
                multiply(
                    translation(
                        instance.position),
                    rotation);

            if (activeScenePreset == ScenePreset::HeroLab)
                model = heroModel;
            visibleInstances.push_back(
                {model,
                 opticalLOD});
        }

        visibleInstanceCount =
            static_cast<int>(
                visibleInstances.size());

        auto cullingEnd =
            std::chrono::high_resolution_clock::now();

        cpuCullingMs =
            std::chrono::duration<double, std::milli>(
                cullingEnd -
                cullingStart)
                .count();

        glBindBuffer(
            GL_ARRAY_BUFFER,
            instanceVBO);

        if (!visibleInstances.empty())
        {
            glBufferSubData(
                GL_ARRAY_BUFFER,
                0,
                visibleInstances.size() *
                    sizeof(InstanceData),
                visibleInstances.data());
        }

        glBindBuffer(
            GL_ARRAY_BUFFER,
            0);

        glUseProgram(
            sceneProgram);
        // ----------------------------------------------------
        // Upload matrices.
        // ----------------------------------------------------
        glUniformMatrix4fv(
            sceneUniforms["uView"],
            1,
            GL_FALSE,
            view.m);
        glUniformMatrix4fv(
            sceneUniforms["uProjection"],
            1,
            GL_FALSE,
            projection.m);
        // ----------------------------------------------------
        if (activeScenePreset == ScenePreset::HeroLab)
        {
            const auto &r = heroRenderer.receiver;
            auto v = [&](const char *n, hero::V3 p)
            { glUniform3f(glGetUniformLocation(sceneProgram, n), p.x, p.y, p.z); };
            v("uReceiverOrigin", r.origin);
            v("uReceiverNormal", r.normal);
            v("uReceiverU", r.u);
            v("uReceiverV", r.v);
            glUniform1f(glGetUniformLocation(sceneProgram, "uReceiverExtent"), r.extent);
        }
        // Camera position
        // ----------------------------------------------------
        glUniform3f(
            sceneUniforms["uCameraPosition"],
            camera.position.x,
            camera.position.y,
            camera.position.z);
        // ----------------------------------------------------
        // Existing shader parameters.
        //
        // Some are currently unused by engine.glsl, which is
        // okay. They are already part of the interface we can
        // expand later.
        // ----------------------------------------------------
        glUniform2f(
            sceneUniforms["uResolution"],
            static_cast<float>(width),
            static_cast<float>(height));
        glUniform1i(
            sceneUniforms["uUseSceneColor"],
            activeScenePreset ==
                    ScenePreset::HeroLab
                ? 1
                : 0);

        glActiveTexture(
            GL_TEXTURE0);

        glBindTexture(
            GL_TEXTURE_2D,
            backgroundTarget.texture);

        glUniform1i(
            sceneUniforms["uSceneColor"],
            0);
        glActiveTexture(
            GL_TEXTURE1);

        glBindTexture(
            GL_TEXTURE_2D,
            environmentHDR);

        glUniform1i(
            sceneUniforms["uEnvironment"],
            1);
        glUniform1f(
            sceneUniforms["uTime"],
            timeSec);
        glUniform1f(
            sceneUniforms["uRefractiveIndex"],
            params.refractiveIndex);
        glUniform1f(
            sceneUniforms["uDispersionC"],
            params.dispersionC);
        glUniform1f(
            sceneUniforms["uAbsorptionStrength"],
            params.absorptionStrength);
        glUniform1i(
            sceneUniforms["uDebugMode"],
            params.debugMode);
        // ========================================================
        // Scene GPU timer
        // ========================================================

        glBeginQuery(
            GL_TIME_ELAPSED,
            sceneQueries[queryWriteIndex]);

        glBindVertexArray(
            prismVAO);

        if (useInstancing)
        {
            // ====================================================
            // INSTANCED PATH
            //
            // All visible objects:
            // one geometry draw call.
            // ====================================================

            if (visibleInstanceCount > 0)
            {
                glDrawArraysInstanced(
                    GL_TRIANGLES,
                    0,
                    prismVertexCount,
                    visibleInstanceCount);

                sceneDrawCalls = 1;
            }
            else
            {
                sceneDrawCalls = 0;
            }
        }
        else
        {
            // ====================================================
            // NAIVE PATH
            //
            // One draw call per visible object.
            //
            // Instance attributes become constant generic
            // attributes for each individual draw.
            // ====================================================

            sceneDrawCalls = 0;

            // Disable instance-buffer arrays.
            for (GLuint location = 2;
                 location <= 6;
                 ++location)
            {
                glDisableVertexAttribArray(
                    location);
            }

            for (const InstanceData &instance :
                 visibleInstances)
            {
                // ------------------------------------------------
                // Model matrix -> locations 2,3,4,5
                // ------------------------------------------------

                glVertexAttrib4fv(
                    2,
                    &instance.model.m[0]);

                glVertexAttrib4fv(
                    3,
                    &instance.model.m[4]);

                glVertexAttrib4fv(
                    4,
                    &instance.model.m[8]);

                glVertexAttrib4fv(
                    5,
                    &instance.model.m[12]);

                // Optical LOD.
                glVertexAttrib1f(
                    6,
                    instance.opticalLOD);

                glDrawArrays(
                    GL_TRIANGLES,
                    0,
                    prismVertexCount);

                sceneDrawCalls++;
            }

            // ----------------------------------------------------
            // Restore instance arrays for future instanced frames.
            // ----------------------------------------------------

            for (GLuint location = 2;
                 location <= 6;
                 ++location)
            {
                glEnableVertexAttribArray(
                    location);
            }
        }

        glBindVertexArray(0);

        // Resolve geometry coverage and depth before screen-space volume work.
        glBindFramebuffer(GL_READ_FRAMEBUFFER, multisampleTarget.fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, sceneTarget.fbo);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                          GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_FRAMEBUFFER, sceneTarget.fbo);

        // White single-scattering volume is clipped against the exact prism and scene depth.
        if (activeScenePreset == ScenePreset::HeroLab && params.debugMode == 0)
            heroRenderer.drawIncident(width, height, {camera.position.x, camera.position.y, camera.position.z},
                                      {cameraForward.x, cameraForward.y, cameraForward.z}, {cameraRight.x, cameraRight.y, cameraRight.z},
                                      {cameraUp.x, cameraUp.y, cameraUp.z}, tanHalfFov, camera.nearPlane, camera.farPlane, opticalModel(), heroSettings);
        // Hero optical energy is accumulated on the receiver; no BeamSegment ribbons.

        glEndQuery(
            GL_TIME_ELAPSED);
        // ====================================================
        // PASS 2
        //
        // Ping-pong separable Gaussian blur.
        // ====================================================
        glDisable(
            GL_DEPTH_TEST);
        glBindVertexArray(
            quadVAO);

        GLuint resolvedSceneTexture = sceneTarget.texture;
        if (taaEnabled && params.debugMode == 0)
        {
            const int writeIndex = 1 - historyIndex;
            glBindFramebuffer(GL_FRAMEBUFFER, historyTargets[writeIndex].fbo);
            glViewport(0, 0, width, height);
            glUseProgram(temporalProgram);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, sceneTarget.texture);
            glUniform1i(glGetUniformLocation(temporalProgram, "uCurrent"), 0);
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, historyTargets[historyIndex].texture);
            glUniform1i(glGetUniformLocation(temporalProgram, "uHistory"), 1);
            glActiveTexture(GL_TEXTURE2);
            glBindTexture(GL_TEXTURE_2D, sceneTarget.depthTexture);
            glUniform1i(glGetUniformLocation(temporalProgram, "uDepth"), 2);
            glUniform2f(glGetUniformLocation(temporalProgram, "uResolution"),
                        static_cast<float>(width), static_cast<float>(height));
            glUniform1i(glGetUniformLocation(temporalProgram, "uHistoryValid"),
                        historyValid && previousViewProjectionValid ? 1 : 0);
            glUniform1f(glGetUniformLocation(temporalProgram, "uHistoryWeight"), 0.88f);
            glUniformMatrix4fv(glGetUniformLocation(temporalProgram, "uInverseViewProjection"),
                               1, GL_FALSE, inverseViewProjection.m);
            glUniformMatrix4fv(glGetUniformLocation(temporalProgram, "uPreviousViewProjection"),
                               1, GL_FALSE, previousViewProjection.m);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            resolvedSceneTexture = historyTargets[writeIndex].texture;
            historyIndex = writeIndex;
            historyValid = true;
            previousViewProjection = currentViewProjection;
            previousViewProjectionValid = true;
        }
        else
        {
            historyValid = false;
            previousViewProjectionValid = false;
        }

        auto runBlurPass =
            [&](GLuint sourceTex,
                int srcW,
                int srcH,
                GLuint targetFbo,
                float dirX,
                float dirY)
        {
            glBindFramebuffer(
                GL_FRAMEBUFFER,
                targetFbo);
            glViewport(
                0,
                0,
                blurWidth,
                blurHeight);
            glUseProgram(
                blurProgram);
            glUniform1i(glGetUniformLocation(blurProgram, "uExtractBright"), sourceTex == resolvedSceneTexture);
            // ------------------------------------------------
            // Source texture
            // ------------------------------------------------
            glActiveTexture(
                GL_TEXTURE0);
            glBindTexture(
                GL_TEXTURE_2D,
                sourceTex);
            glUniform1i(
                blurUniforms["uSource"],
                0);
            // ------------------------------------------------
            // Source resolution
            // ------------------------------------------------
            glUniform2f(
                blurUniforms["uSourceResolution"],
                static_cast<float>(srcW),
                static_cast<float>(srcH));
            // ------------------------------------------------
            // Target resolution
            // ------------------------------------------------
            glUniform2f(
                blurUniforms["uTargetResolution"],
                static_cast<float>(blurWidth),
                static_cast<float>(blurHeight));
            // ------------------------------------------------
            // Blur direction
            // ------------------------------------------------
            glUniform2f(
                blurUniforms["uDirection"],
                dirX,
                dirY);
            glDrawArrays(
                GL_TRIANGLES,
                0,
                6);
        };
        glBeginQuery(
            GL_TIME_ELAPSED,
            blurQueries[queryWriteIndex]);
        // Horizontal
        runBlurPass(
            resolvedSceneTexture,
            width,
            height,
            blurTargetA.fbo,
            1.0f,
            0.0f);
        // Vertical
        runBlurPass(
            blurTargetA.texture,
            blurWidth,
            blurHeight,
            blurTargetB.fbo,
            0.0f,
            1.0f);
        glEndQuery(
            GL_TIME_ELAPSED);
        // ====================================================
        // PASS 3
        //
        // Composite HDR scene + bloom onto the window.
        // ====================================================
        glBeginQuery(
            GL_TIME_ELAPSED,
            compositeQueries[queryWriteIndex]);
        glBindFramebuffer(
            GL_FRAMEBUFFER,
            0);
        glViewport(
            0,
            0,
            outputWidth,
            outputHeight);
        glUseProgram(
            compositeProgram);
        glUniform1f(glGetUniformLocation(compositeProgram, "uExposure"), exposure);
        // ----------------------------------------------------
        // Scene texture
        // ----------------------------------------------------
        glActiveTexture(
            GL_TEXTURE0);
        glBindTexture(
            GL_TEXTURE_2D,
            resolvedSceneTexture);
        glUniform1i(
            compositeUniforms["uScene"],
            0);
        // ----------------------------------------------------
        // Bloom texture
        // ----------------------------------------------------
        glActiveTexture(
            GL_TEXTURE1);
        glBindTexture(
            GL_TEXTURE_2D,
            blurTargetB.texture);
        glUniform1i(
            compositeUniforms["uBloom"],
            1);
        // ----------------------------------------------------
        // Composite parameters
        // ----------------------------------------------------
        glUniform2f(
            compositeUniforms["uResolution"],
            static_cast<float>(outputWidth),
            static_cast<float>(outputHeight));
        glUniform2f(glGetUniformLocation(compositeProgram,"uSceneResolution"),
                    static_cast<float>(width),static_cast<float>(height));
        float activeBloomStrength =
            params.debugMode == 0
                ? params.bloomStrength
                : 0.0f;

        glUniform1f(
            compositeUniforms["uBloomStrength"],
            activeBloomStrength);

        glUniform1i(
            compositeUniforms["uDebugMode"],
            params.debugMode);
        // ========================================================
        // Read previous GPU timings without stalling.
        // ========================================================

        int readIndex =
            1 - queryWriteIndex;

        auto readQueryMilliseconds =
            [](GLuint query,
               double &outputMs)
        {
            // The alternate query slot has not been started during
            // the first frame, so it is not a query object yet.
            if (query == 0 || glIsQuery(query) != GL_TRUE)
            {
                return;
            }

            GLint available = GL_FALSE;
            glGetQueryObjectiv(
                query,
                GL_QUERY_RESULT_AVAILABLE,
                &available);

            if (!available)
                return;

            GLuint64 elapsedNanoseconds = 0;

            glGetQueryObjectui64v(
                query,
                GL_QUERY_RESULT,
                &elapsedNanoseconds);

            outputMs =
                static_cast<double>(
                    elapsedNanoseconds) /
                1000000.0;
        };

        readQueryMilliseconds(
            sceneQueries[readIndex],
            gpuSceneMs);

        readQueryMilliseconds(
            blurQueries[readIndex],
            gpuBlurMs);

        readQueryMilliseconds(
            compositeQueries[readIndex],
            gpuCompositeMs);
        // ----------------------------------------------------
        // Fullscreen composite.
        // ----------------------------------------------------
        glDrawArrays(
            GL_TRIANGLES,
            0,
            6);
        // ----------------------------------------------------
        // Clean up obvious bindings.
        // ----------------------------------------------------
        glBindVertexArray(0);
        glActiveTexture(
            GL_TEXTURE1);
        glBindTexture(
            GL_TEXTURE_2D,
            0);
        glActiveTexture(
            GL_TEXTURE0);
        glBindTexture(
            GL_TEXTURE_2D,
            0);
        glEndQuery(
            GL_TIME_ELAPSED);

        // Next frame writes into the other query set.
        queryWriteIndex =
            1 - queryWriteIndex;
    }
};
// ============================================================
// GLFW Framebuffer Resize Callback
// ============================================================
static void framebufferSizeCallback(
    GLFWwindow *window,
    int framebufferWidth,
    int framebufferHeight)
{
    auto *engine =
        static_cast<PrismEngineNative *>(
            glfwGetWindowUserPointer(
                window));
    if (engine)
    {
        engine->resize(
            framebufferWidth,
            framebufferHeight);
    }
}
// ============================================================
// Main
// ============================================================
int main(int argc, char **argv)
{
    // --------------------------------------------------------
    // Initialize GLFW
    // --------------------------------------------------------
    if (!glfwInit())
    {
        std::cerr
            << "Failed to initialize GLFW."
            << std::endl;
        return -1;
    }
    // --------------------------------------------------------
    // Request OpenGL 3.3 Core Profile.
    // --------------------------------------------------------
    glfwWindowHint(
        GLFW_CONTEXT_VERSION_MAJOR,
        3);
    glfwWindowHint(
        GLFW_CONTEXT_VERSION_MINOR,
        3);
    glfwWindowHint(
        GLFW_OPENGL_PROFILE,
        GLFW_OPENGL_CORE_PROFILE);
    // --------------------------------------------------------
    // Create Window
    // --------------------------------------------------------
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    int smokeFrames = 0, requestedDebug = 0;
    float fixedTime = -1;
    std::string capture;
    float renderScale = 1.0f;
    int requestedMSAA = 2;
    bool requestedTAA = true;
    bool cameraDemo = false;
    std::string cameraRGB, cameraDepth, cameraMask, cameraPosePath;
    camera_input::Intrinsics cameraIntrinsics;
    for (int i = 1; i < argc; ++i)
    {
        std::string arg = argv[i];
        if (arg == "--frames" && i + 1 < argc)
            smokeFrames = std::atoi(argv[++i]);
        else if (arg == "--time" && i + 1 < argc)
            fixedTime = std::atof(argv[++i]);
        else if (arg == "--debug" && i + 1 < argc)
            requestedDebug = std::atoi(argv[++i]);
        else if (arg == "--capture" && i + 1 < argc)
            capture = argv[++i];
        else if (arg == "--render-scale" && i + 1 < argc)
            renderScale = std::clamp(static_cast<float>(std::atof(argv[++i])),1.0f,2.0f);
        else if (arg == "--msaa" && i + 1 < argc) {
            requestedMSAA=std::atoi(argv[++i]);
            if(requestedMSAA!=1 && requestedMSAA!=2 && requestedMSAA!=4) {
                std::cerr << "--msaa accepts 1, 2, or 4\n";glfwTerminate();return 1;
            }
        }
        else if (arg == "--no-taa") requestedTAA=false;
        else if (arg == "--camera-demo") cameraDemo = true;
        else if (arg == "--camera-rgb" && i + 1 < argc) cameraRGB=argv[++i];
        else if (arg == "--camera-depth" && i + 1 < argc) cameraDepth=argv[++i];
        else if (arg == "--camera-mask" && i + 1 < argc) cameraMask=argv[++i];
        else if (arg == "--camera-pose" && i + 1 < argc) cameraPosePath=argv[++i];
        else if (arg == "--camera-intrinsics" && i + 6 < argc) {
            cameraIntrinsics.width=std::atoi(argv[++i]);cameraIntrinsics.height=std::atoi(argv[++i]);
            cameraIntrinsics.fx=std::atof(argv[++i]);cameraIntrinsics.fy=std::atof(argv[++i]);
            cameraIntrinsics.cx=std::atof(argv[++i]);cameraIntrinsics.cy=std::atof(argv[++i]);
        }
        else {
            std::cerr << "Unknown option or missing argument: " << arg << '\n';
            glfwTerminate();return 1;
        }
    }
    if (cameraDemo && !cameraRGB.empty()) {
        std::cerr << "Use either --camera-demo or recorded camera input\n";glfwTerminate();return 1;
    }
    if (cameraRGB.empty() && (!cameraDepth.empty() || !cameraMask.empty() || !cameraPosePath.empty())) {
        std::cerr << "Camera depth/mask/pose require --camera-rgb\n";glfwTerminate();return 1;
    }
    GLFWwindow *window =
        glfwCreateWindow(
            1280,
            720,
            "PrismEngine Native C++",
            nullptr,
            nullptr);
    if (!window)
    {
        std::cerr
            << "Failed to create GLFW Window."
            << std::endl;
        glfwTerminate();
        return -1;
    }
    // --------------------------------------------------------
    // Make OpenGL context current.
    // --------------------------------------------------------
    glfwMakeContextCurrent(
        window);
    // Retain short key presses until the next render loop polls them.
    glfwSetInputMode(window, GLFW_STICKY_KEYS, GLFW_TRUE);
    // Benchmark mode: disable vertical sync.
    // Re-enable with glfwSwapInterval(1) for presentation.
    glfwSwapInterval(0);
    // --------------------------------------------------------
    // Load OpenGL functions.
    // --------------------------------------------------------
    if (!gladLoadGLLoader(
            (GLADloadproc)
                glfwGetProcAddress))
    {
        std::cerr
            << "Failed to initialize GLAD."
            << std::endl;
        glfwDestroyWindow(
            window);
        glfwTerminate();
        return -1;
    }
    // --------------------------------------------------------
    // Print useful GPU information.
    // --------------------------------------------------------
    std::cout
        << "OpenGL: "
        << glGetString(GL_VERSION)
        << std::endl;
    std::cout
        << "Renderer: "
        << glGetString(GL_RENDERER)
        << std::endl;
    // --------------------------------------------------------
    // Create engine.
    // --------------------------------------------------------
    {
        PrismEngineNative engine;
        // --------------------------------------------------------
        // IMPORTANT:
        //
        // Use framebuffer dimensions rather than logical window
        // dimensions because macOS Retina displays can have a
        // larger framebuffer.
        // --------------------------------------------------------
        int framebufferWidth = 0;
        int framebufferHeight = 0;
        glfwGetFramebufferSize(
            window,
            &framebufferWidth,
            &framebufferHeight);
        // --------------------------------------------------------
        // Initialize engine.
        // --------------------------------------------------------
        try
        {
            engine.heroRenderScale=renderScale;
            engine.msaaSamples=requestedMSAA;
            engine.taaEnabled=requestedTAA;
            engine.init(
                framebufferWidth,
                framebufferHeight);
            engine.cameraDemo=cameraDemo;
            if (!cameraRGB.empty()) {
                auto input=camera_input::loadRecorded(cameraRGB,cameraDepth,cameraMask,cameraIntrinsics);
                auto pose=inverseRigid(lookAt(engine.camera.position,engine.camera.target,{0,1,0}));
                std::copy(pose.m,pose.m+16,input.cameraToWorld.begin());
                if (!cameraPosePath.empty()) {
                    std::ifstream file(cameraPosePath);
                    for (float& value:input.cameraToWorld)
                        if (!(file>>value)) throw std::runtime_error("Camera pose requires 16 column-major numbers");
                }
                engine.heroRenderer.setCameraFrame(std::move(input));
                glfwSetWindowAspectRatio(window,cameraIntrinsics.width,cameraIntrinsics.height);
                std::cout << "Registered camera input: " << cameraIntrinsics.width << "x" << cameraIntrinsics.height
                          << (cameraDepth.empty()?" (RGB only, no depth occlusion)":" (RGB-D occlusion enabled)") << '\n';
            }
            if(cameraDemo) {
                glfwSetWindowAspectRatio(window,16,9);
                std::cout << "SYNTHETIC RGB-D TEST: moving foreground sphere; no live camera or AI inference\n";
            }
        }
        catch (const std::exception &e)
        {
            std::cerr
                << "Engine Init Exception: "
                << e.what()
                << std::endl;
            return -1;
        }
        // --------------------------------------------------------
        engine.params.debugMode = std::clamp(requestedDebug, 0, 6);
        // Connect resize callback.
        // --------------------------------------------------------
        glfwSetWindowUserPointer(
            window,
            &engine);
        glfwSetFramebufferSizeCallback(
            window,
            framebufferSizeCallback);
        // --------------------------------------------------------
        // Start timer.
        // --------------------------------------------------------
        auto startTime =
            std::chrono::high_resolution_clock::now();
        auto previousTime = startTime;
        double statsTimer = 0.0;
        int statsFrames = 0;
        // ========================================================
        // Main Engine Loop
        // ========================================================
        int frameNumber = 0;
        while (
            !glfwWindowShouldClose(window))
        {
            glfwPollEvents();
            // ----------------------------------------------------
            // Calculate elapsed time.
            // ----------------------------------------------------
            auto currentTime =
                std::chrono::high_resolution_clock::now();
            float deltaTime =
                std::chrono::duration<float>(
                    currentTime -
                    previousTime)
                    .count();

            previousTime =
                currentTime;
            float elapsedSec =
                std::chrono::duration<float>(
                    currentTime -
                    startTime)
                    .count();
            // ----------------------------------------------------
            // Render entire frame.
            // ----------------------------------------------------
            engine.handleInput(
                window,
                deltaTime);
            if (fixedTime >= 0)
                engine.heroTime = fixedTime;
            try {
                engine.render(fixedTime >= 0 ? fixedTime : elapsedSec);
            } catch (const std::exception& e) {
                std::cerr << "Frame error: " << e.what() << '\n';
                return 2;
            }
            GLenum err = glGetError();
            if (err != GL_NO_ERROR)
            {
                std::cerr << "OpenGL error: " << err << std::endl;
                return 2;
            }
            ++frameNumber;
            if ((smokeFrames > 0 && frameNumber >= smokeFrames) ||
                (smokeFrames == 0 && !capture.empty() && frameNumber == 5))
            {
                if (!capture.empty())
                {
                    std::vector<unsigned char> pixels(engine.outputWidth * engine.outputHeight * 3);
                    glPixelStorei(GL_PACK_ALIGNMENT, 1);
                    glReadPixels(0, 0, engine.outputWidth, engine.outputHeight, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());
                    std::ofstream out(capture, std::ios::binary);
                    out << "P6\n"
                        << engine.outputWidth << " " << engine.outputHeight << "\n255\n";
                    for (int y = engine.outputHeight - 1; y >= 0; --y)
                        out.write(reinterpret_cast<const char *>(pixels.data() + y * engine.outputWidth * 3), engine.outputWidth * 3);
                }
                auto st = engine.heroRenderer.lastTransport.stats;
                std::cout << "Transport: " << st.launched << " rays, " << st.entered << " entered, " << st.received << " received, " << st.tir << " TIR, " << st.truncated << " truncated\n";
                if(smokeFrames>0)glfwSetWindowShouldClose(window, GL_TRUE);
            }
            // ----------------------------------------------------
            // Present.
            // ----------------------------------------------------
            glfwSwapBuffers(
                window);
            statsTimer += deltaTime;
            statsFrames++;

            if (statsTimer >= 0.25)
            {
                double fps =
                    static_cast<double>(statsFrames) /
                    statsTimer;

                double frameMs =
                    1000.0 / fps;

                int presentationDrawCalls =
                    5;

                if (engine.activeScenePreset ==
                    ScenePreset::HeroLab)
                {
                    // Background, receiver, and spectral accumulation.
                    presentationDrawCalls +=
                        4;
                }

                int drawCalls =
                    engine.sceneDrawCalls +
                    presentationDrawCalls;

                int prismTrianglesPerInstance =
                    static_cast<int>(
                        engine.prismVertexCount / 3);

                int submittedPrismTriangles =
                    prismTrianglesPerInstance *
                    engine.visibleInstanceCount;

                constexpr int fullscreenTriangles =
                    10;

                int submittedTriangles =
                    submittedPrismTriangles +
                    fullscreenTriangles;

                std::string title =
                    " | Scene=" +
                    std::string(
                        scenePresetName(
                            engine.activeScenePreset)) +
                    "PrismEngine | " +
                    std::to_string(
                        static_cast<int>(fps)) +
                    " FPS | " +
                    std::to_string(frameMs).substr(0, 4) +
                    " ms | " +
                    std::to_string(drawCalls) +
                    " draws | " +
                    std::to_string(submittedTriangles) +
                    " tris | n=" +
                    std::to_string(
                        engine.params.refractiveIndex)
                        .substr(0, 4) +
                    " | C=" +
                    std::to_string(
                        engine.params.dispersionC)
                        .substr(0, 5) +
                    " | Debug " +
                    std::to_string(
                        engine.params.debugMode) +
                    " | Abs=" +
                    std::to_string(
                        engine.params.absorptionStrength)
                        .substr(0, 4) +
                    " | Objects=" +
                    std::to_string(
                        engine.instances.size()) +

                    " | Visible=" +
                    std::to_string(
                        engine.visibleInstanceCount) +

                    " | Culled=" +
                    std::to_string(
                        engine.culledInstanceCount) +

                    " | Cull=" +
                    std::string(
                        engine.enableCulling
                            ? "ON"
                            : "OFF") +

                    " | Full=" +
                    std::to_string(
                        engine.fullOpticsCount) +

                    " | LOD=" +
                    std::to_string(
                        engine.cheapOpticsCount) +
                    " | OptLOD=" +
                    std::string(
                        engine.enableOpticalLOD
                            ? "ON"
                            : "OFF") +
                    " | Mode=" +
                    std::string(
                        engine.useInstancing
                            ? "INST"
                            : "NAIVE") +

                    " | CPUCull=" +
                    std::to_string(
                        engine.cpuCullingMs)
                        .substr(0, 5) +
                    "ms" +

                    " | GPUScene=" +
                    std::to_string(
                        engine.gpuSceneMs)
                        .substr(0, 5) +
                    "ms" +

                    " | GPUBlur=" +
                    std::to_string(
                        engine.gpuBlurMs)
                        .substr(0, 5) +
                    "ms" +

                    " | GPUComp=" +
                    std::to_string(
                        engine.gpuCompositeMs)
                        .substr(0, 5) +
                    "ms";

                title += " | Scale=" + std::to_string(engine.activeScenePreset==ScenePreset::HeroLab?engine.heroRenderScale:1.0f).substr(0,3);
                title += " | MSAA=" + std::to_string(engine.multisampleTarget.samples);
                title += " | TAA=" + std::string(engine.taaEnabled ? "ON" : "OFF");
                if(engine.activeScenePreset==ScenePreset::HeroLab && engine.cameraDemo)title += " | SYNTHETIC RGB-D";
                else if(engine.activeScenePreset==ScenePreset::HeroLab && engine.heroRenderer.hasCameraFrame())title += " | CAMERA INPUT";
                glfwSetWindowTitle(
                    window,
                    title.c_str());

                statsTimer = 0.0;
                statsFrames = 0;
            }
        }
        // --------------------------------------------------------
    } // Destroy engine resources while the GL context is still current.
    // GLFW cleanup.
    //
    // The engine is destroyed before the OpenGL window because
    // engine was created after window.
    // --------------------------------------------------------
    glfwDestroyWindow(
        window);
    glfwTerminate();
    return 0;
}
