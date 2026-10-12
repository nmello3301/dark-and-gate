# Combat rules — real time (decided 2026-10-12, developer)

Open questions are marked **(?)**. Move rows into DECISIONS.md once they're confirmed.

## Enemy AI
- **Pathfinding:** BG3 / Brawl, as it is.
- **Melee enemies** close the distance and attack up close.
- **Ranged enemies** aim spells and arrows through **our projectile system**, with **human-like imperfect aim**: aim error, misjudged leads on moving targets, reaction delay. It should be no easier for NPCs than for players. Tunable per difficulty and level later.

## Getting hit and dying
- **Players:** no hit-reaction animations.
- **Enemies:** keep BG3's regular hit reactions (already happening) and **die at 0 HP or below**, as in vanilla.
- A hit does not interrupt casting.

## Downed and death (players)
- Downed: the camera goes to **third person, orbiting the downed character**.
  - WASD or LMB / RMB orbit, or **snap to an ally's point of view** (multiplayer spectate).
- **Bleed-out:** after **3 minutes** downed, the character dies. Death is reversed only the regular BG3 ways (Withers, Revivify scrolls…).
  - **The timer pauses while someone is reviving.**
  - Hits on a downed player: no extra effect on the timer (default; revisit if it feels wrong).
- **Revive:** hold **F for 3 s** near a downed ally. A visual cue / prompt shows when in range, plus a progress bar. The ally is revived at **1 HP**.
  - **Cancelled ONLY when the reviver lets go of F or uses another skill or action** (attack, cast, jump, potion…). Moving or getting hit does NOT cancel it, as long as F is held.
  - **Companions revive downed players, and it's their HIGHEST priority** (above attacking).

## Turn-based rules in real time
- Rules stay **exactly as BG3 has them**, converted at **1 turn = 6 s** (10 turns = 60 s): durations, recharges, concentration.
- **Disabled for now, each with a rework note:**
  - **all reactions** (Riposte, opportunity attacks, Shield, Counterspell, Hellish Rebuke…). Shield + Counterspell are the first to come back, much later;
  - **Sneak Attack**.
- **Spell / feature rework list (to fill in over time):** things that lose meaning in real time. Candidates:
  - Haste's extra action, Action Surge;
  - the bonus-action economy;
  - Dash / Disengage, movement-budget boosts;
  - "until the end of your next turn" effects, initiative-based effects;
  - every reaction (above);
  - Sneak Attack.

## Shields
- An **equipped shield blocks about 40% of the damage** of any hit that physically lands on it: melee, arrows and projectile spells. **Passive:** no block key.
- Rough geometry: a disc / box on the shield arm, facing forward. Not precise.
- Shares the "swing obstructed" path with the wall stop (DECISIONS 2026-10-10). The projectile hit check tests the shield shape before the body cylinder.

## Stealth (crouch = sneaking)
- **C toggles crouch, and crouch IS sneaking** (BG3's sneak). Not crouched = not stealthy.
- **BG3's vision cones** are the detection shape. **Hide the cone visuals in first person.**
- **Not crouched:** detected the moment you enter any enemy's vision cone.
- **Crouched inside a cone:** a **stealth check once per enemy per 6 s** while you stay in that enemy's cone.
  - Use the game's own rules: d20 + the player's Stealth vs the enemy's passive Perception (or a simple equivalent).
  - Stealthy characters succeed more often, unstealthy ones fail more often.
  - Fail = that enemy detects you.
- **Aggro spreading: keep BG3's vanilla combat groups.** When one member detects you, the whole group (e.g. the camp) joins. Good enough for now.
  - Later idea (not now): only detectors chase, and others join via an alarm (war drum / gong / horn).
- **No Sneak Attack for now** (above).
