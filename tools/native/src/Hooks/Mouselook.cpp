// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mouselook: owns yaw/pitch in radians, driven by SDL raw mouse deltas.
//
// Rather than hooking SDL_PollEvent (BG3WASD-style — requires xbyak stub
// to preserve registers), we:
//   1. GetProcAddress the SDL2 entrypoints from the already-loaded SDL2.dll
//      inside bg3.exe's address space.
//   2. Call SDL_SetRelativeMouseMode(TRUE) when gameplay+enabled, FALSE
//      otherwise. SDL buffers raw deltas internally while relative mode
//      is on.
//   3. Call SDL_GetRelativeMouseState(&dx, &dy) once per UpdateCamera
//      invocation. The call returns the cumulative delta SINCE THE LAST
//      CALL — perfect for a per-frame accumulator.
//
// This sidesteps the SDL_PollEvent hook entirely. The downside is that
// `dx`/`dy` here are relative-mouse deltas (ints in SDL counts), which
// won't fire if the user has moved their physical mouse while SDL was
// in absolute mode — fine for our use since we toggle relative on and
// off ourselves.
//
// Pause: the camera hook decides every frame whether to drive the yaw
// write (gameplay cam + ground truth active). We keep accumulating
// deltas even when paused so the first unpaused frame doesn't jerk.

#include "Mouselook.h"

#include <windows.h>

#include <atomic>
#include <cmath>

#include "../Config.h"
#include "../GroundTruth.h"
#include "../Log.h"

namespace dag::hooks::mouselook {

namespace {

using SDL_SetRelativeMouseMode_t    = int  (__cdecl*)(int /*SDL_bool*/);
using SDL_GetRelativeMouseState_t   = unsigned (__cdecl*)(int*, int*);

SDL_SetRelativeMouseMode_t  _SetRelativeMouseMode  = nullptr;
SDL_GetRelativeMouseState_t _GetRelativeMouseState = nullptr;

bool _sdlResolved      = false;
bool _relativeModeOn   = false;
std::atomic<float> _yawRad  { 0.0f };
std::atomic<float> _pitchRad{ 0.0f };
std::atomic<bool>  _paused  { true };
std::atomic<bool>  _initialised{ false };
std::atomic<DWORD> _lastMoveTick{ 0 };   // GetTickCount() of the last non-zero delta

constexpr float kPitchClampRad = 1.396263f;  // 80° in radians — keeps
// lookAt clear of the vertical singularity (±90° makes forward colinear
// with world up, so yaw becomes undefined).

void ResolveSDL() {
    if (_sdlResolved) return;
    _sdlResolved = true;
    HMODULE sdl = GetModuleHandleW(L"SDL2.dll");
    if (!sdl) {
        dag::log::Writef("Mouselook: SDL2.dll not loaded in process -- cannot resolve entrypoints");
        return;
    }
    _SetRelativeMouseMode  = reinterpret_cast<SDL_SetRelativeMouseMode_t>(
        GetProcAddress(sdl, "SDL_SetRelativeMouseMode"));
    _GetRelativeMouseState = reinterpret_cast<SDL_GetRelativeMouseState_t>(
        GetProcAddress(sdl, "SDL_GetRelativeMouseState"));
    dag::log::Writef(
        "Mouselook: SDL2 resolved: SetRel=%p GetRel=%p",
        reinterpret_cast<void*>(_SetRelativeMouseMode),
        reinterpret_cast<void*>(_GetRelativeMouseState));
}

// We no longer call SDL_SetRelativeMouseMode -- BG3WASD manages it via
// its own PollEventHook. We just read whatever deltas SDL has
// accumulated. If WASD has rel mode on (gameplay with cursor hidden),
// we get real deltas; if WASD has it off (menu / cursor visible),
// deltas are zero and pitch doesn't change -- the correct behaviour.

}  // namespace

bool Install()
{
    ResolveSDL();
    dag::log::Writef("Mouselook: install (SDL-polling model, lazy enable per frame)");
    return true;
}

float GetYawRad()   { return _yawRad.load  (std::memory_order_relaxed); }
float GetPitchRad() { return _pitchRad.load(std::memory_order_relaxed); }
void  SetPaused(bool p) { _paused.store(p, std::memory_order_relaxed); }
bool  IsPaused()        { return _paused.load(std::memory_order_relaxed); }
bool  IsInitialised()   { return _initialised.load(std::memory_order_relaxed); }
unsigned long LastMoveTick() { return _lastMoveTick.load(std::memory_order_relaxed); }

void MaybeInitFromForward(float fx, float fy, float fz)
{
    if (_initialised.load(std::memory_order_relaxed)) return;
    // Guard against zero / NaN forward (early frames before camera is
    // oriented). Length should be ~1 for a unit vector.
    const float len2 = fx*fx + fy*fy + fz*fz;
    if (len2 < 0.5f || len2 > 2.0f) return;
    // Y-up world. Our forward reconstruction uses:
    //   fx = sin(yaw) * cos(pitch)
    //   fy = -sin(pitch)
    //   fz = cos(yaw) * cos(pitch)
    // So pitch = asin(-fy); yaw = atan2(fx, fz).
    float py = -fy;
    if (py >  1.0f) py =  1.0f;
    if (py < -1.0f) py = -1.0f;
    const float pitch = std::asin(py);
    const float yaw   = std::atan2(fx, fz);
    _yawRad.store  (yaw,   std::memory_order_relaxed);
    _pitchRad.store(pitch, std::memory_order_relaxed);
    _initialised.store(true, std::memory_order_relaxed);
    dag::log::Writef(
        "Mouselook: initialised yaw=%.3f pitch=%.3f (from forward=%.3f,%.3f,%.3f)",
        yaw, pitch, fx, fy, fz);
}

// Called once per UpdateCamera invocation from Camera.cpp.
void Tick() {
    if (!_sdlResolved) ResolveSDL();
    const auto& cfg = dag::config::Get();
    const auto  gt  = dag::groundtruth::Get();
    const bool wantActive = cfg.mouselook.enabled && gt.active && !gt.stale;
    _paused.store(!wantActive, std::memory_order_relaxed);
    // Disable → reset init flag so the next enable snapshots engine
    // forward fresh (user turned off, engine took over orientation).
    if (!wantActive) {
        _initialised.store(false, std::memory_order_relaxed);
    }
    if (!_GetRelativeMouseState) return;
    int dx = 0, dy = 0;
    _GetRelativeMouseState(&dx, &dy);  // call every frame to drain, even when paused

    // Once-per-second diagnostic: are SDL deltas actually arriving?
    static DWORD _lastDeltaLogMs = 0;
    static int   _dxSum = 0, _dySum = 0;
    static int   _frameCount = 0;
    _dxSum += dx; _dySum += dy; ++_frameCount;
    const DWORD now = GetTickCount();
    if (dx != 0 || dy != 0) _lastMoveTick.store(now, std::memory_order_relaxed);
    if (now - _lastDeltaLogMs > 1000) {
        _lastDeltaLogMs = now;
        dag::log::Writef(
            "Mouselook: tick frames=%d dxSum=%d dySum=%d relMode=%d active=%d",
            _frameCount, _dxSum, _dySum, _relativeModeOn ? 1 : 0, wantActive ? 1 : 0);
        _frameCount = 0; _dxSum = 0; _dySum = 0;
    }

    if (!wantActive) return;
    // Engine owns yaw (vanilla camera rotation reads mouse X via BG3WASD
    // / BG3's own input path). We only accumulate pitch from Y deltas.
    const float sPitch = cfg.mouselook.sensitivity_pitch *
                         (cfg.mouselook.invert_pitch ? -1.0f : 1.0f);
    const float toRad  = 0.01745329252f;
    float pitch = _pitchRad.load(std::memory_order_relaxed);
    pitch += dy * sPitch * toRad;
    if (pitch >  kPitchClampRad) pitch =  kPitchClampRad;
    if (pitch < -kPitchClampRad) pitch = -kPitchClampRad;
    _pitchRad.store(pitch, std::memory_order_relaxed);
}

// For character-facing follow: writes yaw to a file Lua picks up.
void MaybeWriteYawForLua() {
    const auto& cfg = dag::config::Get();
    if (!cfg.mouselook.enabled || !cfg.mouselook.character_facing) return;
    static DWORD lastWriteMs = 0;
    const DWORD now = GetTickCount();
    if (now - lastWriteMs < 100) return;  // 10 Hz is plenty for turn-to-face
    lastWriteMs = now;
    // Write %LOCALAPPDATA%\...\Script Extender\DarkAndGate\native-cam-yaw.txt
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    wchar_t full[MAX_PATH * 2];
    swprintf_s(full, L"%s\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\native-cam-yaw.txt", buf);
    HANDLE h = CreateFileW(full, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    char line[64];
    int len = std::snprintf(line, sizeof(line), "yaw=%.5f t=%u\n",
                            _yawRad.load(std::memory_order_relaxed), now);
    DWORD written = 0;
    WriteFile(h, line, len, &written, nullptr);
    CloseHandle(h);
}

}  // namespace dag::hooks::mouselook
