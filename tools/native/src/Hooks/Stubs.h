// SPDX-License-Identifier: GPL-3.0-or-later
//
// Logged stubs for features where static analysis did not find a clean
// engine hook. Each registers a once-per-5s heartbeat line via the
// camera tick so the user sees which switch is on vs. silent.
//
// Features here (M1a status 2026-10-08):
//   - Anim play speed / cancel / hit-stop (SE exposes no API; Granny
//     internal). To unblock: live RE pass on esv::Character::Animation.
//   - Bone-world-pos reads. Granny bone matrices are internal; SE
//     exposes Skeleton structure only. Head-bone cam remains deferred.

#pragma once

namespace dag::hooks::stubs {

// Called once per UpdateCamera from Camera.cpp; emits a 5-second
// heartbeat per feature indicating what WOULD happen if real.
void Tick();

}  // namespace dag::hooks::stubs
