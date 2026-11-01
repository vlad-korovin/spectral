#include "ImageLoader.hpp"

#include <iostream>
#include <stdexcept>
#include <algorithm>
#include <cstring>

#define STB_IMAGE_IMPLEMENTATION
#include "../third_party/stb_image.h"

namespace {
bool supportsExtension(const char* wanted)
{
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint i = 0; i < count; ++i)
    {
        const char* name = reinterpret_cast<const char*>(glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(i)));
        if (name && std::strcmp(name, wanted) == 0)
            return true;
    }
    return false;
}

void enableAnisotropicFiltering()
{
    if (!supportsExtension("GL_EXT_texture_filter_anisotropic") &&
        !supportsExtension("GL_ARB_texture_filter_anisotropic"))
        return;
    GLfloat maximum = 1.0f;
    glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY, &maximum);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, std::min(maximum, 8.0f));
}
}

GLuint loadHDRTexture(
    const char *path)
{
    stbi_set_flip_vertically_on_load(
        false);

    int width = 0;
    int height = 0;
    int channels = 0;

    float *pixels =
        stbi_loadf(
            path,
            &width,
            &height,
            &channels,
            3);

    if (!pixels)
    {
        throw std::runtime_error(
            std::string(
                "Failed to load HDR image: ") +
            path);
    }

    GLuint texture = 0;

    glGenTextures(
        1,
        &texture);

    glBindTexture(
        GL_TEXTURE_2D,
        texture);

    GLint previousAlignment=4;
    glGetIntegerv(GL_UNPACK_ALIGNMENT,&previousAlignment);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGB16F,
        width,
        height,
        0,
        GL_RGB,
        GL_FLOAT,
        pixels);

    glGenerateMipmap(GL_TEXTURE_2D);

    glPixelStorei(GL_UNPACK_ALIGNMENT,previousAlignment);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MIN_FILTER,
        GL_LINEAR_MIPMAP_LINEAR);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MAG_FILTER,
        GL_LINEAR);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_WRAP_S,
        GL_REPEAT);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_WRAP_T,
        GL_CLAMP_TO_EDGE);

    enableAnisotropicFiltering();

    glBindTexture(
        GL_TEXTURE_2D,
        0);

    stbi_image_free(
        pixels);

    std::cout
        << "Loaded HDR: "
        << path
        << " ("
        << width
        << "x"
        << height
        << ")"
        << std::endl;

    return texture;
}

GLuint loadTexture2D(
    const char *path,
    bool srgb)
{
    stbi_set_flip_vertically_on_load(
        true);

    int width = 0;
    int height = 0;
    int channels = 0;

    unsigned char *pixels =
        stbi_load(
            path,
            &width,
            &height,
            &channels,
            3);

    if (!pixels)
    {
        throw std::runtime_error(
            std::string(
                "Failed to load texture: ") +
            path);
    }

    GLuint texture = 0;

    glGenTextures(
        1,
        &texture);

    glBindTexture(
        GL_TEXTURE_2D,
        texture);

    GLenum internalFormat =
        srgb
            ? GL_SRGB8
            : GL_RGB8;

    GLint previousAlignment=4;
    glGetIntegerv(GL_UNPACK_ALIGNMENT,&previousAlignment);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        internalFormat,
        width,
        height,
        0,
        GL_RGB,
        GL_UNSIGNED_BYTE,
        pixels);

    glGenerateMipmap(
        GL_TEXTURE_2D);

    glPixelStorei(GL_UNPACK_ALIGNMENT,previousAlignment);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MIN_FILTER,
        GL_LINEAR_MIPMAP_LINEAR);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MAG_FILTER,
        GL_LINEAR);

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_WRAP_S,
        GL_REPEAT);

    enableAnisotropicFiltering();

    glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_WRAP_T,
        GL_REPEAT);

    glBindTexture(
        GL_TEXTURE_2D,
        0);

    stbi_image_free(
        pixels);

    return texture;
}
