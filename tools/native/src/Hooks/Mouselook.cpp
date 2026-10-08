// SPDX-License-Identifier: GPL-3.0-or-later

#include "Mouselook.h"

#include <atomic>

#include "../Config.h"
#include "../Log.h"

namespace dag::hooks::mouselook {

namespace {

std::atomic<float> g_yawRad{0.0f};
std::atomic<float> g_pitchRad{0.0f};
std::atomic<bool>  g_paused{true};  // start paused; UI hook unpauses

}  // namespace

bool Install()
{
    const auto& cfg = dag::config::Get();
    if (!cfg.mouselook.enabled) {
        dag::log::Writef("Mouselook: disabled in config, skipping install");
        return true;
    }
    // Scaffold: no real hook yet. We log the intent so the first-run
    // log shows us what Camera.cpp will be reading.
    dag::log::Writef(
        "Mouselook: scaffold loaded (yaw=%.2f, pitch=%.2f, paused=%d). "
        "SDL relative-mode + delta ingest coming in follow-up commit.",
        g_yawRad.load(), g_pitchRad.load(), g_paused.load());
    return true;
}

float GetYawRad()   { return g_yawRad.load(std::memory_order_relaxed); }
float GetPitchRad() { return g_pitchRad.load(std::memory_order_relaxed); }

void SetPaused(bool paused) { g_paused.store(paused, std::memory_order_relaxed); }
bool IsPaused()             { return g_paused.load(std::memory_order_relaxed); }

}  // namespace dag::hooks::mouselook
