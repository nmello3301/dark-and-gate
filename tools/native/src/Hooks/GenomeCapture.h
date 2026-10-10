// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capture of every gameplay event (Genome) the client queues for the
// animation blueprint, spell events tagged. Read-only: logs the event
// name, caller, entity and the 22 GenomeVariant args (ShortNameSets
// decoded), then lets the engine queue it unchanged. See docs/spikes/genome-capture.md (static RE,
// bg3_dx11.exe Patch 8).

#pragma once

namespace dag::genomecapture {

// Detours the blueprint queue entry (rva 0x3bd4b90); falls back to the
// spell builder's tail jump if the entry bytes differ. Always installed; logs nothing until SetCapture(true). Call once
// at DLL load.
void Install();

// Called every frame from the POV tick (native-pov.txt genome_capture).
// ON opens DarkAndGate\native-genome-capture.txt, OFF closes it. Also
// drains the per-event summaries into native.log on this thread.
void SetCapture(bool on);

}  // namespace dag::genomecapture
