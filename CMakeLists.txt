cmake_minimum_required(VERSION 3.16)

project(PrismEngine LANGUAGES C CXX)

# ------------------------------------------------------------
# C / C++ settings
# ------------------------------------------------------------

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Generate compile_commands.json for VS Code IntelliSense
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)


# ------------------------------------------------------------
# Find GLFW
# ------------------------------------------------------------

# Homebrew locations:
#   Apple Silicon: /opt/homebrew
#   Intel Mac:     /usr/local

list(APPEND CMAKE_PREFIX_PATH
    "/opt/homebrew"
    "/usr/local"
)

# First try to find a system/Homebrew installation.
find_package(glfw3 CONFIG QUIET)

# If GLFW was not found, download and build it automatically.
if(NOT glfw3_FOUND)

    message(STATUS "GLFW not found locally.")
    message(STATUS "Downloading GLFW automatically...")

    include(FetchContent)

    FetchContent_Declare(
        glfw
        GIT_REPOSITORY https://github.com/glfw/glfw.git
        GIT_TAG 3.4
    )

    # We don't need GLFW's examples, tests, or documentation.
    set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
    set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

    FetchContent_MakeAvailable(glfw)

endif()


# ------------------------------------------------------------
# PrismEngine executable
# ------------------------------------------------------------

add_executable(
    PrismEngine

    src/main.cpp
    src/Scene.cpp
    src/Beam.cpp
    src/HeroRenderer.cpp
    src/CameraFrame.cpp
    src/CameraIO.cpp
    src/SpectralTransport.cpp
    src/ImageLoader.cpp
    src/glad.c
)


# ------------------------------------------------------------
# Include directories
# ------------------------------------------------------------

target_include_directories(PrismEngine PRIVATE

    ${CMAKE_CURRENT_SOURCE_DIR}/include

)


# ------------------------------------------------------------
# Link GLFW
# ------------------------------------------------------------

target_link_libraries(PrismEngine PRIVATE

    glfw

)


# ------------------------------------------------------------
# Tell C++ exactly where engine.glsl is located
# ------------------------------------------------------------

target_compile_definitions(
    PrismEngine PRIVATE
    ENGINE_SHADER_PATH="${CMAKE_CURRENT_SOURCE_DIR}/engine.glsl"
    ENGINE_HERO_SHADER_PATH="${CMAKE_CURRENT_SOURCE_DIR}/shaders"
    ENGINE_ASSET_PATH="${CMAKE_CURRENT_SOURCE_DIR}/assets"
)

include(CTest)
if(BUILD_TESTING)
    add_executable(transport_tests tests/transport_tests.cpp src/SpectralTransport.cpp src/Scene.cpp)
    target_include_directories(transport_tests PRIVATE src)
    add_test(NAME spectral_transport COMMAND transport_tests)
    add_executable(camera_tests tests/camera_tests.cpp src/CameraFrame.cpp src/SpectralTransport.cpp)
    target_include_directories(camera_tests PRIVATE src)
    add_test(NAME camera_geometry COMMAND camera_tests)
endif()

find_package(Python3 COMPONENTS Interpreter QUIET)
find_program(GLSLANG_VALIDATOR glslangValidator)
if(BUILD_TESTING AND Python3_Interpreter_FOUND AND GLSLANG_VALIDATOR)
    add_test(NAME shader_validation COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/validate_shaders.py
        ${CMAKE_CURRENT_SOURCE_DIR} ${GLSLANG_VALIDATOR})
endif()
