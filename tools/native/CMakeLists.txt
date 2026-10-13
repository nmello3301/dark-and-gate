# SPDX-License-Identifier: GPL-3.0-or-later
# Dark and Gate native plugin — camera follow, mouselook, bone reads,
# animation speed/cancel, raycast hit normals.
#
# Loads via Ch4nKyy's Mod Loader as <BG3>/bin/NativeMods/DarkAndGate.dll.
#
# Builds with Visual Studio Community 2022 (Desktop C++ workload) and
# vcpkg. From a Developer PowerShell:
#   cmake --preset vs2022-windows
#   cmake --build out/build --config Release
#
# The resulting DLL is copied by scripts/deploy-native.ps1 into BG3's
# NativeMods folder. See tools/native/README.md.

cmake_minimum_required(VERSION 3.21)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_DEBUG OFF)

project(
    DarkAndGate
    VERSION 0.1.0
    LANGUAGES CXX
    DESCRIPTION "Dark and Gate native plugin — M1a scaffold"
)

if(${PROJECT_SOURCE_DIR} STREQUAL ${PROJECT_BINARY_DIR})
    message(FATAL_ERROR "In-source builds are not allowed.")
endif()

# One translation unit for now. src/main.cpp wires DllMain and writes the
# version file so the Lua side can verify the DLL loaded. Hooks arrive in
# the next pass once the bridge-less architecture is OK'd.
add_library(DarkAndGate SHARED
    src/main.cpp
    src/Config.cpp
    src/GroundTruth.cpp
    src/Log.cpp
    src/PatternScan.cpp
    src/Watchdog.cpp
    src/Hooks/Camera.cpp
    src/Hooks/Mouselook.cpp
    src/Hooks/Pov.cpp
    src/Hooks/VisualLift.cpp
    src/Hooks/AnimRate.cpp
    src/Hooks/MoveSpeed.cpp
    src/Hooks/MoveFeel.cpp
    src/Hooks/RealJump.cpp
    src/Hooks/CombatWasd.cpp
    src/Hooks/GenomeCapture.cpp
    src/Hooks/Stubs.cpp
)

target_include_directories(DarkAndGate PRIVATE src)

# Match NCT / WASD compile flags where it matters for ABI compatibility
# with the game process (MSVC, /MD runtime, no exceptions in hot paths).
if(MSVC)
    target_compile_options(DarkAndGate PRIVATE
        /W4
        /permissive-
        /Zc:preprocessor
        /utf-8
    )
    target_compile_definitions(DarkAndGate PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        UNICODE
        _UNICODE
    )
endif()

set_target_properties(DarkAndGate PROPERTIES
    OUTPUT_NAME "DarkAndGate"
    PREFIX ""
    SUFFIX ".dll"
)
