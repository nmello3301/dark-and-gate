# Draft message to tinybike

Short, friendly ping to send once the repo is public (or sooner, if you want
to give them a heads-up). Pick whichever channel they prefer — their Nexus
page lists contact details.

---

Subject: Brawl in a new BG3 mod (first-person action combat, GPL-3)

Hi tinybike,

Quick note: I'm building a BG3 mod called **Dark and Gate** that turns
combat into first-person, real-time action (Dark-and-Darker-style weapon
swings, BG3 spells cast at the crosshair, a mana pool, co-op). The
hardest part — the turn-based escape and the real-time AI loop — is
Brawl's work, not mine, and I'm importing it directly instead of
re-discovering what you already solved.

The mod is GPL-3 (same as Brawl), free, and the repo will go public on
the first shared build. Credit is in the `NOTICE` file at the repo
root, with the exact commit I imported from
(`1ac3c7c1a6bc01cdc21cb9ec8a0f857210f0ef31`). The imported files sit
under `mod/.../Server/Brawl/` verbatim so the diff against upstream
stays obvious; any changes I make on top (Swarm Mode / Leaderboard
strip, mana-check hook) are also GPL-3.

Thank you — Brawl's RealTime + Pause code is a real body of work, and
it's genuinely unlocking the project. If you ever want to look at
what someone built on top, the design doc is in `docs/DESIGN.md`.
If you'd prefer different credit wording, a link to a specific repo,
or anything else, say the word.

Nick

---

**Notes:**

- Keep it short — they're not expected to review the mod, just to know
  their work is being used and credited.
- Only send once the repo is public, or if you want to give them a
  heads-up before that. If you send before public, include a GitHub
  invite so they can see the credit if they want.
- If they ask for different attribution, update `NOTICE` and
  `README.md` to match.
