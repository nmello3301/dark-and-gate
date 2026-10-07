---
name: bg3-spike
description: Run a time-boxed engine spike to answer one "can BG3 / the Script Extender do X?" question (the M0 list in docs/DESIGN.md, or any new one), with in-game proof and a written result. Use before building any feature that depends on an unverified engine capability.
---

# Engine spike

A spike answers **one** question with evidence, then stops. It produces a short note and, at most, throwaway probe code.

## 1. Frame it

- Take the question from the M0 table in `docs/DESIGN.md` (or write the new one in the same form).
- Write `docs/spikes/NN-short-name.md` from the template below, filling in the question, why it matters, and the fallback from the design doc's "If the answer is no" column.
- Agree on a time box with the developer: usually one or two play-test rounds.

## 2. Search before probing

In this order, and stop as soon as the question is answered:

1. `reference/bg3se`: docs, IDE helpers and source. The Script Extender is open source, so the answer is often in its code.
2. `reference/Brawl`: it already solved real-time combat problems.
3. The universal-modder knowledge base (`um kb search "baldur's gate 3"`) and its `mod-any-game` BG3 playbook.
4. Public mods that do something similar: camera mods, input mods, AnimationUnlocker. Read their docs; don't copy their code.
5. **The engine binary, last.** Use Ghidra over MCP (ghidra-mcp) only when steps 1–4 come up empty and the question can't be answered without it.
   - Analyse the BG3 executable read-only, from the developer's own install.
   - Record function names, signatures and addresses in the spike note. Never commit decompiled code or game binaries.
   - A finding from the binary only becomes a plan once it is confirmed in-game.

## 3. Probe in-game

- Write the smallest possible probe: a few lines of Lua in `mod/DarkAndGate/ScriptExtender/Lua/Spikes/`, behind an MCM debug toggle, that logs what the API returns or does.
- Run it with the `bg3-deploy-test` skill and read the log.
- Measure timing questions with real numbers: frame times and message round-trips, logged with timestamps.

## 4. Write the result

Fill in the note's result and recommendation, then:

- Add verified APIs to `docs/se-api-notes.md`.
- Add a line to `docs/DECISIONS.md` (for example, "Hit check stays in Lua: blade bones readable at 60 Hz, 0.4 ms per check").
- If the answer changes the design, propose the edit to `docs/DESIGN.md` and wait for the developer's OK.
- Delete or disable the probe code before the next milestone.

## Template

```markdown
# Spike NN: <question>

**Status:** open | answered yes | answered no | partial
**Date:** <date> · **BG3 version:** <x> · **Script Extender version:** <x>

## Question
<one sentence>

## Why it matters
<the feature it unblocks>

## Fallback if no
<from the design doc>

## What we checked
- Script Extender docs/source: <files, findings>
- Brawl: <files, findings>
- Other: <links>
- Binary (only if needed): <function, address, what it does>

## In-game proof
<probe, test steps, the log lines that prove it>

## Result and recommendation
<yes / no / partial, numbers, what to build next>
```
