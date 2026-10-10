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

// Scaled calls since the target was set (0 = the hook never saw a clip
// of that character, e.g. locomotion not driven by PlayAnimation nodes).
long Hits();

// Animation recorder (2026-10-10): while `instance` is set, every
// PlayAnimation-type node that runs for it logs a line to
// DarkAndGate/native-anim-rec.txt when its animation input (socket 0)
// starts or changes: time, node class, the 16 raw bytes of the input
// (formatted as a GUID too), LoopAnimation, PlayRate. Lua resolves the ids
// to clip names (!dag_anim_record off). 0 = stop.
void Record(uintptr_t instance);

// Per-clip play rate (2026-10-10, spell channel): on `instance`, nodes whose
// animation input (socket 0, a FixedString holding the mapping id) equals
// one of `ids` play at the matching rate, on top of the character rate.
// spec = "id:rate,id:rate" (mapping-id GUID strings), "" = none. Used to
// stretch a spell's prepare to the cast time without touching the legs,
// and to fast-forward the engine's own prepare/loop at release.
void SetClipRates(uintptr_t instance, const char* spec);
// Calls scaled by a clip rate since the spec was set.
long ClipHits();

// FixedString id -> text through ls::gGlobalStringTable (found lazily on
// the first call). SEH-guarded; false and "" on any failure. Used by
// GenomeCapture.cpp.
bool FsText(uint32_t id, char* out, size_t cap);

}  // namespace dag::animrate
