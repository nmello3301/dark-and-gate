// SPDX-License-Identifier: GPL-3.0-or-later

#include "Stubs.h"

#include <windows.h>

#include "../Config.h"
#include "../Log.h"

namespace dag::hooks::stubs {

namespace {
DWORD _lastLog = 0;
}

void Tick() {
    const DWORD now = GetTickCount();
    if (now - _lastLog < 5000) return;
    _lastLog = now;
    const auto& cfg = dag::config::Get();
    if (cfg.anim.enabled) {
        dag::log::Writef(
            "Anim[stub]: enabled=1 hit_stop=%d hit_stop_ms=%d "
            "(no engine hook — SE exposes no animation-speed API; "
            "needs esv::Character::Animation RE pass)",
            cfg.anim.hit_stop ? 1 : 0, cfg.anim.hit_stop_ms);
    }
    if (cfg.bone.enabled) {
        dag::log::Writef(
            "Bone[stub]: enabled=1 (Granny internal matrices; SE exposes "
            "Skeleton structure only — head-bone cam deferred until RE)");
    }
    if (cfg.raycast.enabled) {
        dag::log::Writef(
            "Raycast[note]: enabled=1 but native not needed; "
            "Ext.Level.RaycastClosest provides Normal. Use !dag_raynormal.");
    }
}

}  // namespace dag::hooks::stubs
