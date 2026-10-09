// SPDX-License-Identifier: GPL-3.0-or-later
//
// Full first-person POV ("dag_full_pov").
//
// Lua (FullPov.lua) writes DarkAndGate/native-pov.txt every ~200 ms:
//   on / active flags, eye offsets, the controlled character's root
//   position, the head socket's bone index, and the addresses of the
//   character's MeshBinding objects (from tostring() of SE userdata).
//
// The DLL, every frame:
//   1. Reads the head bone (Head_M) from the skeleton's live Granny world
//      pose, reached through the MeshBinding (read-only, SEH-guarded; see
//      docs/spikes/m1b-head-bone.md). The eye height above the bone is
//      calibrated once from the pivot eye at rest, so the default view
//      height is unchanged. !dag_pov_anchor pivot switches back to the
//      engine pivot. Jump lift (VisualLift.h) is added on the pivot path,
//      and on the bone path only when the body lift isn't live.
//   2. In the vt[0x58] commit hook (the one call proven to reach the
//      screen), sets BOTH the eye (newPos) and every candidate look-at
//      field on the camera to a consistent pair:
//        eye = head + offsets
//        P   = eye - rot * look        (rot = engine cameraRotation,
//                                       which points pivot -> eye)
//      so whichever field the engine builds its view from, the camera
//      sits at the head and looks where the engine's own yaw/pitch
//      (NCT + mouse) points. Fields are restored right after the
//      commit, so nothing persists into the next frame.
//   3. MMB toggles mouse rotation (SDL event filter): first press
//      starts the engine's own Camera Rotate, the release is swallowed,
//      the next press ends it.
//
// Fallbacks, in order: head bone (once calibrated) -> mesh world transform + eye height
// -> engine desired pivot (cam+0x24) + offset. Each frame picks the
// first that validates, so a bad pose read can never move the camera
// somewhere absurd.

#pragma once

namespace dag::pov {

// Called at the start of every Hook_UpdateCamera with the gameplay
// camera object (cameraSlot[6]). Polls the Lua file, drives the MMB
// toggle state machine, installs the SDL filter lazily.
void OnFrame(void* gameplayCam);

// Called at the top of the vt[0x58] commit hook. Returns true if it
// handled the commit (and already called `original`); false means the
// caller should continue with its normal path.
using CommitFn = void(__fastcall*)(void*, void*, float*, float*);
bool HandleCommit(void* self, void* slotToken, float* newPos, float* outPos,
                  CommitFn original);

}  // namespace dag::pov
