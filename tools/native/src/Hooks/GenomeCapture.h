// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capture of the spell animation gameplay event (Genome) the client
// spell-cast code queues for the animation blueprint. Read-only: logs the
// event name, entity and the 22 GenomeVariant args, then lets the engine
// queue it unchanged. See docs/spikes/genome-capture.md (static RE,
// bg3_dx11.exe Patch 8).

#pragma once

namespace dag::genomecapture {

// Pattern-scans and patches the builder's tail jump into the blueprint
// queue. Always installed; logs nothing until SetCapture(true). Call once
// at DLL load.
void Install();

// Called every frame from the POV tick (native-pov.txt genome_capture).
// ON opens DarkAndGate\native-genome-capture.txt, OFF closes it. Also
// drains the per-event summaries into native.log on this thread.
void SetCapture(bool on);

}  // namespace dag::genomecapture
