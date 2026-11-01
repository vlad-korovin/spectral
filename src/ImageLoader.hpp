#pragma once

#include <glad/glad.h>

GLuint loadHDRTexture(
    const char *path);

GLuint loadTexture2D(
    const char *path,
    bool srgb);