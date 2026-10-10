// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-character animation play rate. See docs/spikes/anim-clock.md.
//
// All animation-playing Genome nodes (GrannyNode_PlayAnimation,
// _FromActiveSet, _FromSpecificSet, and three more classes) share one
// Execute(GenomeNode*, GenomeExecutionContext*). It reads the node's
// PlayRate input variable every frame and feeds it to the clip player.
// We patch the vtable slots that point to it; when the context's
// GenomeBlueprintInstance (ctx+0x18) is a target, the hook multiplies the
// PlayRate variable by our rate for that one call and restores it after.
// Everything the character plays through those nodes (scripted clips,
// attacks, jump clips) runs at x rate; other characters are untouched.

#pragma once

#include <cstdint>

namespace dag::animrate {

// Set the rate for one GenomeBlueprintInstance (address from Lua's
// tostring(ent.AnimationBlueprint.Instance)). rate 1 (or inst 0) clears it.
// Installs the hook on first use. Cheap to call every frame.
void Set(uintptr_t instance, float rate);

// "ok" / "failed: <why>" / "not installed" for the status line.
const char* State();

}  // namespace dag::animrate
