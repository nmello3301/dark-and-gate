# Dark and Gate — Design Document

BG3 First-Person Action Combat Mod · Oct 7, 2026 · Nick · synced with DECISIONS on 2026-10-12

Live version with diagrams and charts: https://claude.ai/code/artifact/d9d14ee0-9dac-4e0e-b924-4dc4b54b157a
This file is the copy Claude Code works from. When it changes, update both.

## Overview

This mod turns Baldur's Gate 3 into a first-person, real-time action RPG on mouse and keyboard, while keeping Larian's campaign, companions, spells and items. Melee works like Dark and Darker: weapon-specific swing chains whose blade path decides what it hits. Spells are BG3's own spells, cast where the crosshair points and paid for with a regenerating mana pool. Hits land with the weight of Blade & Sorcery through reactions, ragdolls and effects rather than full physics.

**Design pillars**

1. **Every hit is aimed.** Swings and spells hit what the player aims at; dice only remain where they add flavor (saving throws, damage rolls).
2. **Keep Larian's world.** Dialogue, quests, companions, camp and scripted story stay intact.
3. **BG3's content, new verbs.** Reuse classes, spells, weapons and items; change how they are used, not what they are.
4. **Co-op from day one.** Gameplay state is server-owned from the first prototype, so multiplayer is a feature, not a rewrite.

**Out of scope:** physically simulated bodies, dismemberment, VR, consoles, and copying assets or animations from Dark and Darker or Blade & Sorcery.

## Platform, dependencies and licensing

The mod is a Windows PC-only BG3 mod installed through BG3 Mod Manager; it needs the Script Extender, so it cannot run through the console mod system. Gameplay logic is Script Extender Lua. **Our own native plugin** (a C++ DLL loaded through Ch4nKyy's Mod Loader) covers what the Script Extender can't reach: the first-person camera and mouse-look, the real jump, per-character animation play rate, and engine probes. It stays small and data-driven; Lua decides, the DLL executes.

| Dependency | Role | Bundled? |
| --- | --- | --- |
| [Script Extender](https://github.com/Norbyte/bg3se) | Lua runtime, client/server split, net messages | No, required install |
| Ch4nKyy's Mod Loader + Native Camera Tweaks | Loads our DLL; first-person camera placement | No, required install |
| Dark and Gate native plugin | Camera follow + mouse-look, real jump, direct WASD controller, animation play rate | Yes (ours) |
| WASD Character Movement | Keyboard movement keys, walk / run toggle, camera rotation and its other features; in first person our DLL's direct controller does the moving (DECISIONS 2026-10-13; its own movement stays as the `vanilla` mode) | No, required install |
| AnimationUnlocker | Custom attack animations | No, required install |
| Mod Configuration Menu (MCM) | Settings and keybinds | No, required install |
| [Brawl](https://github.com/tinybike/Brawl) | Real-time combat loop and AI | Forked: imported under GPL-3.0, credited |

**Compatibility.** Spell, class and item mods should work, because spells stay BG3 data. Other combat AI or turn-based overhauls will conflict. UI overhauls such as ImpUI may conflict with the Prepare Hotbar tab.

**Licensing.**

- Brawl is GPL-3.0. Forking its code makes this mod GPL-3.0 too, with credit to its author.
- Required mods are dependencies, never repackaged.
- Mechanics from Dark and Darker and Blade & Sorcery are reimplemented from scratch; none of their assets, animations or sounds are used.
- Follow Larian's modding terms for anything published.

## Controls and keymap

The left mouse button does everything offensive: it swings the held weapon, or casts the readied spell at the crosshair. Number keys 1 to 0 ready what is on the hotbar. All bindings are rebindable in MCM.

| Input | Action |
| --- | --- |
| W A S D | Move |
| Mouse | Look and aim |
| Left click | Weapon: next swing in the chain · Spell channelled and ready: release it at the crosshair · Bow: hold to draw, release to fire |
| Right click | Spell channelling: cancel it · otherwise block with shield or weapon · Offhand attack when dual-wielding |
| 1 2 3 4 5 6 7 8 9 0 | Use hotbar slot (see Hotbar section); the channelled spell's own key again cancels it |
| Mouse wheel (spell readied) | Change the cast level (upcasting) |
| T / Y | Drink the best health potion / mana potion (DECISIONS 2026-10-12) |
| R | Reload the crossbow |
| F | Interact, talk, loot (tap); hold to revive a downed ally (DECISIONS 2026-10-12) |
| Q | Swap melee and ranged weapon sets (DECISIONS 2026-10-12) |
| Space | Jump |
| C | Crouch = sneak (DECISIONS 2026-10-12) |
| V | Companion mode: Follow / Wait / Go to camp |
| M | BG3's map (fast travel works normally) |
| V | Companions: toggle Follow and Wait (out of combat) |
| Esc | Game menu |

**Channelled casting.** Pressing a spell's number starts channelling it: the caster plays the spell's own prepare animation (their class's casting pose, as in vanilla), the spell cast bar fills over the cast time, and area spells show a ground preview. Once the cast time has passed the spell is READY and is held as long as the player wants; left click releases it at the crosshair. Right click, or the same number again, cancels it. Another number switches to that spell.

**Instant slots.** Self-buffs, potions and class actions such as Rage fire on key press, without readying.

**Options.** A *quick cast* setting fires every slot on key press at the crosshair. An optional *tactical pause* (single player only, off by default) is an open question.

**First-person camera and body.** Placing the camera at eye height on its own shows the inside of the character's head, and shrinking the character to hide it is not acceptable. The target is "true first person":

- **Camera on the head bone.** It sits at the eyes, slightly forward, follows the head's position but not its animation wobble, and uses a wider field of view (about 90°, adjustable).
- **Hide the head on your own screen only.** The local player's head, hair, beard and headwear are hidden on their own client. Body, arms, legs and weapon stay visible, so you see your hands and blade when you swing and your feet when you look down. Other players still see the full character. The head is hidden only while the camera is in your eyes: the downed camera, dialogues and cutscenes, and first person off all show it again (DECISIONS 2026-10-13).
- **Near-clip and weapon clipping.** The camera's near plane is tuned so close walls and your own weapon don't cut through the view.
- **Fallback:** a floating arms-and-weapon view model, as in classic shooters. It is the most robust option but needs its own animation set, so it is the last resort.

## Melee combat system

Each weapon family has its own chain of three swings, and the blade's path through space decides who gets hit; there is no attack roll. Grouping BG3's weapons into ten families keeps the animation workload bounded.

| Family | BG3 weapons | Chain (click 1 / 2 / 3) | Feel |
| --- | --- | --- | --- |
| Short blades | Dagger, shortsword, sickle | Stab / slash / stab | Fastest, short reach |
| Finesse | Rapier, scimitar | Thrust / thrust / lunge (rapier); slash / slash / slash (scimitar) | Fast, precise |
| Longswords | Longsword (one or two hands) | Slash right / slash left / thrust | Medium, all-round |
| Great blades | Greatsword | Wide sweep / return sweep / overhead | Slow, hits 2 targets |
| Axes | Handaxe, battleaxe, greataxe | Diagonal chop / chop / overhead | Medium to slow; greataxe hits 2 |
| Light blunt | Club, mace, morningstar, light hammer, flail, war pick | Overhead / side / overhead | Medium, strong stagger |
| Heavy blunt | Warhammer (two hands), maul | Overhead / overhead | Slowest, biggest stagger |
| Polearms | Spear, glaive, halberd, pike, trident | Thrust / thrust / sweep | Longest reach |
| Staves | Quarterstaff | Alternating strikes | Fast, monk-friendly |
| Unarmed | Fists, monk | Jab / jab / kick | Fastest, flurry finisher |

**Swing timing (data, per chain step).** Wind-up, active window, recovery, combo window, movement slow, turn-rate limit, reach, max targets, stagger power and damage scale. Design targets: light swings about 0.4–0.5 s, medium 0.6–0.75 s, heavy 0.9–1.1 s, all tuned in playtests. Clicking inside the combo window continues the chain; otherwise it resets.

**Melee cooldown (decided 2026-10-13).** At most one swing per **1.5 s**, measured from swing start to swing start, so spamming left click can't out-swing a fight. A click in the last 0.3 s of the cooldown is kept and swings the moment it ends; earlier clicks do nothing. The chain still advances: its combo window opens when the cooldown ends. The server enforces the cooldown too: a swing that starts too soon lands nothing. Enemies already act on their own pace (4–10 s, `data/realtime.lua`), so today the cooldown only limits players. 1.5 s is a starting value (`data/combat.lua` `melee.cooldown_s`; live `!dag_melee_cooldown <s>`), and every weapon's data already carries a `cooldown_mult` (1.0 for now).

Possible scaling for balancing and the RPG layer (not built; all multiply the base, clamped to about 0.4–3 s):

- **Weapon family** (`cooldown_mult`): short blades and unarmed about ×0.65, finesse and staves ×0.8, longswords ×1.0, axes and light blunt ×1.1, great blades and polearms ×1.25, heavy blunt ×1.45.
- **Chain step:** a per-swing multiplier, so a finisher (overhead, lunge) costs more than the openers.
- **Weapon properties:** Light ×0.85, Heavy ×1.15; a versatile weapon held in two hands slower than in one.
- **Ability score:** the attack ability (STR, or DEX for finesse) shortens it, for example −3 % per modifier point, capped at −15 %.
- **Level and class:** Extra Attack's "+20 % swing speed per tier" becomes ×0.83 per tier here; monks' Martial Arts gives unarmed and monk weapons its own lower base.
- **Buffs and conditions:** Haste ×0.5, Action Surge ×0.67 for its 10 s, Slow ×2, Exhaustion ×1.1 per level, frightened ×1.2.
- **Gear and feats:** heavy armour without proficiency ×1.2; Great Weapon Master trades a longer cooldown for its damage bonus; Dual Wielder and Polearm Master give the off-hand and butt strikes their own short cooldown.
- **Outcome:** a whiffed swing could recover a little faster; a swing blocked by a shield could add to it (ties into the stagger rules).
- **Difficulty:** NPC cooldowns by BG3 difficulty, like the enemy pace, once enemies swing more often than their pace allows.
- **Feedback:** a ring around the crosshair (like the bow draw ring) once cooldowns vary, so a click that does nothing never feels like a bug.

**Blade-path hit check.**

1. During the active window, sample 5 points from hilt to tip each tick.
2. Test the swept segments between ticks against each character's hit-zone volumes.
3. Each character is hit at most once per swing; the swing stops after its max targets.
4. A sweep that strikes level geometry first is **obstructed** (`wall = off / stop / bounce`, default **stop**): the swing's damage window ends there, so nothing is hit through walls. Overhead swings and thrusts ignore side walls. `bounce` (stagger + recoil) comes later with the defence animations; parry and shield block reuse the same "swing obstructed" path.
5. Allies are valid targets, so friendly fire is on by default.

**Hit zones.** Head ×1.5 damage, torso ×1.0, arms and legs ×0.7; a leg hit also slows the target for 0.5 s. These multipliers are starting values for tuning.

**Blocking (right click).**

- **Shield:** blocks all melee damage in a 120° frontal arc.
- **Weapon:** blocks 50% of melee damage.
- **Cost of blocking:** movement is halved and no attacks are possible while blocking. A heavy-blunt hit on a block staggers the blocker.
- **Parry:** a block started up to 0.2 s before the hit staggers the attacker.

**Extra Attack and dual wielding.** Extra Attack becomes +20% swing speed per tier instead of extra hits. Dual-wielders attack with the offhand on right click and lose blocking.

**Ranged weapons** (on the shared projectile system below).
- **Bows:** hold left click to draw (**3 s base draw for every bow**, a stat will scale it later; DECISIONS 2026-10-12), release to fire along the crosshair; the arrow drops. Damage and arrow speed scale with the draw; there is no shot below about 30 %. Full draw holds forever, with no sway or fatigue. Movement is about 60 % speed while drawing. A bow draw ring around the crosshair shows the draw. BG3's own draw animation is stretched to the draw time. Enemy and companion archers draw the same way and aim for the drop.
- **Crossbows:** click to fire, then a reload time. The bolt is flatter and faster.
- **Thrown weapons:** the same system, with a slower throw and a higher arc. Thrown weapons and grenades go on the hotbar.
- Arrows stick into walls and targets.

## Spellcasting

Every spell is the unchanged BG3 spell, cast through script at the point or target under the crosshair; the mod changes the aiming, the timing and the cost, never the spell's effects. Spells added by other mods follow the same rules, because they use the same spell data.

| BG3 spell type | Examples | Crosshair rule |
| --- | --- | --- |
| Projectile | Fire Bolt, Eldritch Blast, Scorching Ray, Chromatic Orb | Flies along the aim line on our own simulated flight; hits whatever it touches first, anywhere mid-flight (moving targets can be led) |
| Area at a point | Fireball, Cloud of Daggers, Hunger of Hadar | Lands where the aim ray meets the ground or a surface; preview decal while readied |
| Cone and line | Burning Hands, Thunderwave, Lightning Bolt | Fires in the look direction from the caster |
| Single target | Hold Person, Healing Word, Hex, Shocking Grasp | Whoever is under the crosshair, with a small aim-assist radius; self if none and the spell allows it |
| Teleport | Misty Step, Dimension Door | Moves to the crosshair point, capped at the spell's range |
| Wall | Wall of Fire, Blade Barrier | Centred on the crosshair point, turned to face the caster |
| Summon | Find Familiar, Spiritual Weapon, Conjure Elemental | Appears at the crosshair point; controlled by the real-time AI |
| Self | Shield of Faith, Mirror Image, Blur | Instant on key press |
| Reaction | Shield, Counterspell, Hellish Rebuke | Used proactively (see below) |

**Cast time (channelled).** Every spell has a cast time: 2.0 s base for now (`data/spells.lua`), later scaled by character traits. The prepare animation is stretched over it, then loops at READY. The server rejects a release before the cast time. While the cast time runs on the ground, movement is slowed to ×0.7; once READY, and in the air, it is full speed. Casting never roots the caster. **A hit while channelling does not interrupt the cast**: no cancel and no timer reset.

**Range** (DECISIONS 2026-10-12). Two first-person ranges replace BG3's (mostly 18 m):
- **70 m:** spells that fly at or hit one target (Fire Bolt, Ray of Frost, Guiding Bolt, Magic Missile, Sacred Flame, Hold Person, Healing Word) and arrows / bolts. A shot that hits nothing ends at 70 m.
- **30 m:** spells with an area or several picked targets (Fireball, Grease, Fog Cloud, Sleep, Bless, walls). An area spell aimed farther lands where its ring shows: 30 m out, on the ground. Fireball aimed at the sky bursts at the end of its flight.
- Touch spells (BG3 range 3 m or less), teleports (Misty Step), cones and lines from the caster, and shouts keep BG3's data.

Each spell's `TargetRadius` is raised to its range at stats load (never lowered), so BG3 never refuses or walks the caster into range; the server pulls a cast point beyond the range back to it. NPC and companion AI still walk to BG3's own range before they cast. The reticle turns red when the point is out of range, and casting is blocked.

**Projectile system** (shared by spells, arrows and thrown weapons; [design/projectiles.md](design/projectiles.md)).
- **Flight:** ours and server-authoritative, with speed, gravity, drag and a sphere radius per projectile.
- **Hits:** each tick, the sphere is swept against the world and against every character's *current* cylinder. The first contact wins, anywhere mid-flight.
- **Look:** BG3's own projectile, kept on our path and removed at our hit.
- **Effect:** an instant, projectile-free *impact* version of the spell, applied on the hit character or at the point. BG3 still applies the damage dice, saves, statuses and hit effects, and the original projectile never deals damage.
- **Other shapes:**
  - instant rays use the crosshair line;
  - Magic Missile stays homing;
  - cones and caster-centred areas use a shape test at cast time.

**Saving throws stay dice.** Hold Person, Fireball's half damage and similar spells still roll the target's save against the caster's spell DC, with advantage and disadvantage as in BG3.

**Spell attacks are aimed.** Projectile and touch spells that used an attack roll now hit on collision and use the melee hit-zone multipliers.

**Concentration.** One concentration spell at a time, as in BG3. Damage still forces a Constitution save to keep it.

**Durations.** One BG3 turn becomes 6 seconds, so a 10-turn spell lasts 60 s.

**Reactions without turns.**

- **Shield:** an instant slot that grants its AC bonus for 6 s.
- **Counterspell:** cast at an enemy showing a cast bar to cancel the spell.
- **Hellish Rebuke and similar triggers:** fire automatically on the trigger if a setting allows it, with their normal mana cost.

## Mana system

Spell slots are replaced by one mana pool that regenerates at a steady rate, in and out of combat. Stronger spells cost more mana, and stronger casters have bigger pools and faster regeneration. Design target: an empty pool refills in about 60–90 seconds at every level, so the pool is one fight's worth of burst and regeneration sets the sustained pace.

**Caster level (CL).** It follows the 5e multiclass rules BG3 already uses.

- **Full casters** (Bard, Cleric, Druid, Sorcerer, Wizard): CL = class level.
- **Half casters** (Paladin, Ranger): CL = class level ÷ 2, rounded up, from level 2.
- **Third casters** (Eldritch Knight, Arcane Trickster): CL = class level ÷ 3, rounded up, from level 3.
- **Multiclass:** the class contributions are added together.
- **Non-casters:** CL 0 means no mana bar.

**Pool and regeneration.** M is the spellcasting ability modifier, minimum 0.

```
Max mana         = 30 + 10 × CL + 5 × M
Regen per second = 0.5 + 0.1 × CL + 0.1 × M
```

Max mana at level 12 (modifier +3 at level 1, +4 at 4, +5 at 8): full casters 175, half casters 115, third casters 95. Half and third casters start later and grow more slowly, so a level-12 Paladin has about two-thirds of a Wizard's pool.

**Cost by spell level.** Cantrips are free and limited only by their cast time. Upcasting pays the cost of the level cast at.

| Spell level | Mana cost | Example |
| --- | --- | --- |
| Cantrip | 0 | Fire Bolt |
| 1 | 10 | Magic Missile |
| 2 | 20 | Misty Step |
| 3 | 32 | Fireball |
| 4 | 45 | Polymorph |
| 5 | 60 | Cone of Cold |
| 6 | 80 | Chain Lightning |

**Worked examples** (modifier rises +3, +4, +5 at levels 1, 4, 8).

| Build | Pool | Regen | Empty to full | A full pool buys |
| --- | --- | --- | --- | --- |
| Wizard 1 | 55 | 0.9 /s | 61 s | 5 Magic Missiles |
| Wizard 5 | 100 | 1.4 /s | 71 s | 3 Fireballs |
| Wizard 12 | 175 | 2.2 /s | 80 s | 2 Chain Lightnings |
| Paladin 5 | 80 | 1.2 /s | 67 s | 4 level-2 Divine Smites |
| Warlock 5 | 60 | 2.1 /s | 29 s | 1 level-3 spell, back in half a minute |

**Unchanged rules.** The highest spell level a character can cast still follows BG3's progression; only slots are replaced. Spell preparation is unchanged.

**Class and item mappings.**

| Feature | New rule |
| --- | --- |
| Warlock Pact Magic | Pool ×0.6, regeneration ×1.5: small and fast. Mystic Arcanum stays a once-per-long-rest charge |
| Wizard Arcane Recovery, Druid Natural Recovery | Hotbar action: restore 50% of max mana, once per long rest |
| Sorcerer Font of Magic | Convert sorcery points to mana, 1 point = 8 mana. Metamagic still costs sorcery points |
| Paladin Divine Smite | Costs mana at the smite level's price (see Class features) |
| Ritual spells | Free outside combat |
| Scrolls | Cost no mana |
| Effects that restore a spell slot | Restore mana equal to that slot level's cost |
| Long rest | Refills mana instantly |
| Enemy casters | Same rules, with CL taken from their level, so enemies cannot spam their best spells |

**Tunables (MCM).** Every number in the formulas and the cost table, plus the Warlock multipliers and an out-of-combat regeneration multiplier (default 1.0, matching the steady-rate rule). Mana is owned by the server.

## Hotbar and the Prepare Hotbar tab

Each character has a 10-slot hotbar on keys 1 to 0, arranged in a new **Hotbar** tab inside BG3's own character menu. Hotbars are saved per character in the save file and synced to all players in multiplayer.

**What a slot can hold.**

| Entry | On key press | Shown on the slot |
| --- | --- | --- |
| Spell (prepared or known), with a chosen cast level | Readies it; left click casts | Mana cost; greyed out when unaffordable |
| Cantrip | Readies it | Free |
| Self spell or buff | Casts instantly | Mana cost |
| Class action (Rage, Action Surge, Wild Shape, Bardic Inspiration, Channel Divinity, Lay on Hands) | Uses it, or readies it if it needs a target | Charges or cooldown sweep |
| Consumable (potion, scroll, grenade, throwing weapon) | Drinks it, or readies it if thrown | Count in inventory; refills from any matching stack |

**The Prepare Hotbar tab.** The tab sits beside Character, Spells and Inventory, with a character switcher at the top right. Selecting a slot shows its cast level and AI toggle; the switcher changes which party member is being set up.

- **Left panel:** a searchable list filtered by Spells (grouped by level), Cantrips, Class actions and Items. Each row shows its icon, mana cost and targeting type.
- **Right panel:** the 10 slots labelled 1 to 0. Entries are dragged in, swapped or cleared.
- **Per slot:** a cast-level picker for spells, limited to levels the character can cast, and an *AI may use* toggle used by companions.
- **Character switcher:** the same tab works for every party member, so the player sets each companion's kit.
- **Spell preparation stays native.** Wizards, Clerics, Druids and Paladins still prepare spells as usual; the list only offers what is prepared or known.

**In play.** The hotbar strip of the first-person HUD shows the 10 slots with key numbers, spell icons, mana-too-low tint, cooldowns and counts; the channelled slot glows. A second page on Alt+1 to 0 is a later stretch goal.

**Implementation path.** The target is a real tab in BG3's native menu, made by extending its UI layouts. Milestone 1 uses a Script Extender ImGui window (the approach Mod Configuration Menu uses) so gameplay is not blocked on UI work; the native tab arrives in Milestone 4. Compatibility with UI overhauls such as ImpUI is an open question.

## Damage and rules rebalance

Aim replaces the attack roll, so Armor Class becomes damage reduction; damage dice, saving throws, resistances and conditions stay as BG3 has them.

**Melee and aimed-attack damage.**

```
Damage = (weapon or spell dice + modifiers) × zone × swing scale × (1 − DR)
```

**Armor Class as damage reduction.** DR = 3% per point of AC above 10, capped at 45%. AC 16 gives 18%; AC 20 gives 30%. Magical AC bonuses keep working through the same formula.

**Kept and replaced.**

| BG3 rule | In this mod |
| --- | --- |
| Attack roll vs AC | Replaced by the blade-path or projectile hit |
| Damage dice and modifiers | Kept, rolled per hit |
| Saving throws vs spell DC | Kept |
| Critical hits | 5% chance per hit; 10% on 19–20 features, 15% on 18–20; dice double as in BG3 |
| Advantage on attacks | Doubles crit chance |
| Disadvantage on attacks | No crits and −10% damage |
| Resistances, vulnerabilities, conditions, surfaces | Kept |
| Action, bonus action, movement per turn | Replaced by animation timing and short cooldowns |
| Opportunity attacks | Removed; real-time positioning covers it |
| Hit points | Kept, with a global multiplier in MCM (default 1.0) |

**Class features.** One BG3 turn is 6 seconds everywhere.

| Feature | Real-time rule |
| --- | --- |
| Sneak Attack | Bonus dice on a hit from behind, on an unaware target, or with an ally within 2 m of the target; once per 6 s |
| Divine Smite | Press its slot to prime it; the next melee hit consumes the mana and adds the smite |
| Rage | Hotbar action, 60 s, keeps its resistances and damage bonus |
| Reckless Attack | Toggle: crit chance doubled, incoming damage +15% |
| Great Weapon Master, Sharpshooter | Hold left click for a slower power attack that adds +10 damage |
| Action Surge | 10 s of +50% swing and cast speed |
| Battle Master maneuvers | Hotbar entries applied to the next hit |
| Flurry of Blows | Chain finisher for unarmed and staves |
| Bardic Inspiration | Readied and cast on an ally; boosts their next hit or save |
| Wild Shape | Stretch goal: first-person beast with its own chain; until then, third-person camera while transformed |

All numbers here are starting values for playtest tuning, exposed in MCM where practical.

## Real-time combat rules (decided 2026-10-12)

Full rules: [design/combat-rules.md](design/combat-rules.md) and [design/interaction-and-world.md](design/interaction-and-world.md); one row per decision in DECISIONS.md. Built 2026-10-12, playtest [playtest/realtime-combat.md](playtest/realtime-combat.md).

- **Fights are real time on Brawl's loop.** No turns; vanilla combat groups join together. Rules stay BG3's at **1 turn = 6 s**. All reactions and Sneak Attack are off for now, each with a rework note ([rework-list.md](rework-list.md)). `!dag_rt off` is for debugging only.
- **Enemy AI uses our rules.** Pathfinding and choices are Brawl's / BG3's. Melee goes through our swing (same weapon data, committed direction, arc, wall stop, shield). Archers and casters go through our projectiles, with human-like aim: reaction delay, error cone, misjudged lead (`data/ai.lua`). Other spells take our cast time; area spells commit their point when the cast starts.
- **Getting hit.** The player has no hit reaction; enemies keep BG3's and die at 0 HP. A hit doesn't interrupt a cast.
- **Shields are passive.** About 40 % comes off any hit that lands on the shield disc.
- **Downed.** At 0 HP the camera orbits the body (spectate with Space) for a **3 min bleed-out**, paused while someone revives. Revive = **hold F 3 s within 1.5 m**: up at 1 HP; only letting go of F or another action cancels it. Companions revive first (except in camp). Death is undone only the vanilla ways. Nobody attacks a downed character (hits can't kill one), you stay in control of your own body (BG3 would hand control to a companion, who would then stop fighting), and BG3's game over waits until the last downed party member has bled out instead of coming the moment everyone is down. When nobody in the party is left standing, the downed screen offers **Give up** (a button, or G; twice to confirm): BG3's game-over screen comes up at once, and with other players once every player has given up (DECISIONS 2026-10-13).
- **C = crouch = BG3's sneak.** Crouched speed is 60 %, and the vision cones are hidden in first person. Standing in an enemy's cone = detected. Crouched in a cone = d20 + Stealth vs passive Perception once per enemy per 6 s; failing pulls its group into the fight.
- **F interacts** with what the crosshair is on (talk, loot, doors, levers, pick up, climb), exactly like a click; only interactive things are highlighted. A downed ally in range wins: hold F to revive. BG3's panels (dialogue, loot, trade, inventory, map) free the mouse and pause our input.
- **V** cycles companions between Follow, Wait and Go to camp. **M** opens BG3's map; fast travel works, and first person comes back after it.
- **Targeted spells:** LMB picks characters under the crosshair (line of sight, within the spell's range: 30 m for several targets like Sleep or Bless, 70 m for one). The spell fires at the max count once READY; the key again fires early; RMB cancels. **Area spells** show BG3's own ring at the crosshair point, clamped to range, from arming to cast or cancel.

## Impact feedback and HUD

Hits should feel as heavy as Blade & Sorcery through layered animation, effects and camera work, without simulating bodies physically.

| Feedback | Approach | Status |
| --- | --- | --- |
| Blood, sparks on armor, impact flashes | BG3 effects spawned at the hit point, chosen by damage type and armor | Planned |
| Hit reactions | Flinch, stagger and knockdown animations picked by hit zone, direction and stagger power | Planned |
| Hit stop | 2–4 frame freeze on heavy hits, or camera shake if per-character time scaling is not exposed | Spike in M0 |
| Death | Ragdoll pushed in the direction of the killing blow | Spike in M0 |
| Weapon obstructed | A swing that hits a wall stops dealing damage (`wall = stop`); recoil animation and spark with the defence animations (`bounce`) | Planned |
| Bodies swaying from each blow | Out of scope; approximated with additive hit animations | Not planned |
| Dismemberment, embedded blades | Out of scope | Not planned |

**First-person HUD.** The developer's art ([design/hud.md](design/hud.md)) replaces BG3's HUD while first person is on. BG3's hotbar, portraits and combat log are hidden, and come back when first person is off and in dialogue, menus and cutscenes.

- **Crosshair:** changes with the readied spell; area spells draw a ground preview, and the reticle turns red out of range.
- **Health and mana:** a red health orb on the left and a blue mana orb on the right. Each one's liquid level is the current %, and the numbers ("105/110 HP") sit under the orb.
- **Hotbar strip:** sits between the orbs, with 10 slots on keys 1–0. Each slot shows the spell's own icon, a glow on the channelled slot, and a tint when mana is too low.
- **Potions:** health potion [R] and mana potion [T] slots, with counts.
- **XP:** a bar under the hotbar.
- **Charge bars:** a blue spell cast bar above the hotbar fills over the cast time, shows READY, and drains on cancel. A separate amber bow draw ring sits around the crosshair, with a 30 % mark and a full-draw tick.
- **Party frames:** companions' health and state in the top left, with a callout and sound when one goes down.
- **Enemy cast bars:** shown above enemy casters, which makes Counterspell and interrupting by hitting them readable.
- **Hit markers and directional damage:** a hit marker on confirmed hits, a headshot variant, and an edge flash pointing to incoming damage.
- **Damage numbers:** optional, off by default.

**Traversal highlights (later, with the M4 HUD).** First person hides the ways up, so climbable and jumpable spots get a faint glow: vines, ladders, climbable walls, stairs and jump-up ledges. It is a small glare that brightens when the player is close and looking at it, and fades with distance. On by default, with a toggle and intensity setting in MCM.

## Companions and AI

Outside combat, the player chooses whether each companion follows or stays at camp. In a fight, companions run the same real-time AI as enemies, on the player's side. One AI drives both sides, so it is built once.

**Pace** (DECISIONS 2026-10-12, 2026-10-13). Companions and NPC allies start an action every **4 s**. Enemies' pace follows BG3's difficulty: **Explorer 10 s, Balanced 6 s, Tactician 5 s, Honour 4 s** (a custom difficulty counts as its Enemy AI setting); enemy and ally stats scale with difficulty later. A high initiative roll makes a fighter's pace a little faster, a low one a little slower (about ±10 %). An action that runs longer, such as a bow draw or a cast, is followed by the next as soon as it ends. NPC allies fight on the player's side like companions. A companion or ally the AI finds nothing for attacks the nearest enemy with its weapon instead of standing idle.

**States.** Camp ↔ Follow (party menu); Follow ↔ Wait (V key); Follow or Wait → In combat when a fight starts, and back to the previous mode when it ends; In combat → Downed at 0 HP → back to In combat when revived. Camp companions skip fights.

**Modes (out of combat).**

| Mode | Behavior | How to set |
| --- | --- | --- |
| Follow (default) | Trails the player with BG3's follow behavior | V toggles Follow and Wait; party menu |
| Wait | Holds position; useful for stealth and scouting | V |
| Camp | Sent to camp through BG3's camp system; approval, banter and quests keep working | Native party and camp UI |

**Combat behavior.** When a fight starts, every companion in Follow or Wait joins it. When it ends, they return to their previous mode.

1. **Pick a target** using the companion's archetype (melee, ranged, caster, healer), set in the Prepare Hotbar tab.
2. **Act only with its kit:** hotbar slots marked *AI may use*, plus its weapons.
3. **Hold a mana reserve:** it does not spend below 30% of max mana unless an ally is downed. The reserve is adjustable.
4. **Respect friendly fire:**
    - no swing while the player or an ally is inside the swing arc;
    - no area spell that would catch the party, unless the spell can exclude allies (such as Sculpt Spells).
5. **Support:** heal or revive downed allies; retreat when below 25% health if it has range.

**Enemy AI.** Enemies use the same system, with archetypes mapped from their BG3 AI type. Enemy casters show cast bars and can be interrupted by a melee hit. Mana rules apply to them too.

**Later.** A command wheel on R (Attack my target, Fall back, Hold) and per-companion aggression settings. Brawl's companion commands are a reference.

## Multiplayer architecture

The mod is built as client and server from the first prototype, because BG3 already runs that way even in single player. Clients own feel: input, camera, their own swing animation and the first hit check. The server owns truth: damage, mana, spell casts, AI and saved state. Multiplayer ships late, but nothing has to be rewritten for it.

| Concern | Owner | Why |
| --- | --- | --- |
| Input, camera, aim ray | Client | Must be instant |
| Own swing animation and blade-path check | Client | Hits must feel instant to the attacker |
| Hit validation and damage | Server | One source of truth; loose range and timing check (co-op, so lenient) |
| Mana, cooldowns, charges | Server | Shared state that must not drift |
| Spell casting | Server (BG3 casts the spell; effects sync natively) | Reuses BG3's own spell netcode |
| Companion and enemy AI | Server (the host) | One brain per character |
| Hotbars and modes | Server, mirrored to clients | Saved with the game |
| Effects, hit reactions, HUD | Client, triggered by server events | Cosmetic |

**Network messages** (Script Extender net channels).

| Message | Direction | Contents |
| --- | --- | --- |
| SwingStart | Client → server → others | Character, weapon family, chain step, start time |
| HitClaim | Client → server | Swing id, target, zone, hit time |
| HitResult | Server → all | Target, damage, zone, stagger, killed |
| CastRequest | Client → server | Hotbar slot, cast level, aim origin and direction or point |
| CastResult | Server → all | Accepted or refused (mana, range, interrupted) |
| ManaSync | Server → owner | Current and max mana, sent on change and every 0.5 s |
| HotbarSync | Both ways | Slot contents and AI toggles |
| ModeChange | Client → server | Companion Follow, Wait or Camp |

**Requirements.** Every player runs Windows, the same mod version and the Script Extender. Each player's own AI companions follow that player. Testing needs two game instances, on two PCs or two accounts on a local network.

## Campaign compatibility

Most campaign fights should work in real time. Scripted set pieces will break, so every fight has a per-encounter fallback to turn-based combat. Brawl reports the same pattern: most campaign fights work in real time, but encounters with elaborate scripted mechanics, such as the second Auntie Ethel fight, lose them.

- **Dialogue and cutscenes:** combat logic pauses, then resumes when they end.
- **Encounter overrides:** a data file lists encounters that start turn-based automatically, or that need custom handling. It grows with each act's playtest pass.
- **Manual toggle:** one key switches the current fight to native turn-based combat and back, for anything the overrides miss.
- **Stealth, surfaces and environment:** sneaking, fire, grease, water and pushing off ledges keep working, because they are native systems.
- **Terrain (known limitation):** you walk at the height of BG3's walkable map, not on the visible rocks and debris. Where a rock sits on walkable ground you can walk partly into it, and a jump that lands on a rock top doesn't keep you up there (you drop back to the map's height, waist-deep in the rock). Standing on what a jump reaches was tried and dropped on 2026-10-13: it made jumping worse ([spikes/ground-support.md](spikes/ground-support.md), DECISIONS 2026-10-13).
- **Camp and resting:** unchanged, except that mana refills on long rest.
- **Saving:** saving mid-fight is allowed. Combat state that cannot be restored ends the fight cleanly on load. Brawl advises against saving mid-fight in real time, so this needs testing.
- **Uninstalling:** a menu command restores native combat state before the final save.

## Technical architecture and reverse-engineering spikes

The mod is mostly Script Extender Lua, split into client and server modules, with data files for all tuning. The native plugin (C++ DLL, our own) fills the gaps the spikes found:
- the camera commit, mouse-look and head-bone anchor;
- the real jump (steering BG3's falling state);
- the per-character animation play rate;
- WASD movement: the speed lever, and the direct controller (in first person: full speed within about 0.06 s, a stop within 0.04 s with no slide, reversals and strafe changes at once, no turn-in-place pause; the body turns with BG3's own steering; on BG3's own controller-mode path, so walls, the nav grid and the server sync stay the engine's; [spikes/move-feel.md](spikes/move-feel.md));
- static-analysis-guided probes, such as the genome event capture and the animation recorder.

It is built from `tools/native` with `scripts/pov-build-deploy.ps1`.

**Modules.**

- **Client (each player):** input and crosshair aim; first-person camera; swings and blade-path check; hotbar and Prepare tab; HUD and impact effects.
- **Server (host):** combat director (real time); hit validation and damage; mana, cooldowns, charges; spell casting (BG3 spells); AI for companions and enemies; encounter overrides and saves.
- **Between them:** Script Extender net channels (SwingStart, HitClaim, CastRequest, HotbarSync, ModeChange up; HitResult, CastResult, ManaSync, HotbarSync down).
- **Underneath:** the BG3 engine through the Script Extender (spells, animations, effects, saves), plus an optional native plugin only if spikes need it.

In single player, the client and server run in the same game, so the same code paths are exercised from day one.

**Data files.** Weapon families and swing timings, spell mana-cost overrides, AI archetypes, encounter overrides, and MCM settings. Designers tune these files without touching code.

**Fork Brawl or start fresh.** Forking Brawl's real-time loop and AI saves months but makes the mod GPL-3.0. Starting fresh keeps the license open but repeats solved problems. Recommendation: fork, and decide in M0.

**Reverse-engineering spikes (M0).** The Script Extender is open source, so each question starts in its code and docs. Ghidra over MCP on the BG3 Windows executable is the fallback.

| # | Question | If the answer is no |
| --- | --- | --- |
| 1 | Can scripts capture left and right click and keys 1 to 0, and suppress BG3's default bindings in first person? | Native input hook |
| 2 | Can we cast a ray from the camera through the screen centre and get the world point and the character hit? | Find BG3's picking function with Ghidra; expose it from a native plugin |
| 3 | Can scripts read a weapon's bone positions every frame? | Native plugin reads the skeleton |
| 4 | Can scripts play custom animations at a chosen speed and cancel them at combo points? | Extend AnimationUnlocker's approach |
| 5 | Can a spell be cast at a world point from script, with a shortened animation? | Spawn the spell's projectile or area directly |
| 6 | Can a killing blow push the ragdoll in a direction? | Death animations by direction |
| 7 | Can one character's animation be frozen for a few frames (hit stop)? | Camera shake and flash instead |
| 8 | Can a tab be added to the native character menu UI? | Keep the ImGui window |
| 9 | Are net messages fast enough for HitClaim at 2 to 4 players? | Batch claims per tick |
| 10 | Is a geometry raycast fast enough for wall-bounce checks every tick? | Check only at the blade tip, at a lower rate |
| 11 | Can the camera follow the head bone, and can the local player's head, hair and headwear be hidden on their own client only? | Native plugin hides those meshes; last resort, an arms-only view model. Never shrink the character |

## Milestones, risks and open questions

The project ships in eight milestones. The first real gate is M1: one weapon and three spells against goblins must feel tight before content is scaled up.

| Milestone | Scope |
| --- | --- |
| M0 Spikes | The 11 engine questions; fork Brawl or not |
| M1 Vertical slice | Longsword, 3 spells (Fire Bolt, Fireball, Misty Step), mana, hotbar, goblins |
| — Gate | **Combat feels tight** |
| M2 Combat breadth | All weapon families, all spell types |
| M3 Companion AI | Shared real-time AI; Follow, Wait, Camp |
| M4 Native UI | Prepare Hotbar tab, first-person HUD, traversal highlights |
| M5 Act 1 pass | Encounter overrides, balance and saves |
| M6 Multiplayer | 2–4 player co-op, sync and validation |
| — Gate | **Act 1 in 2-player co-op** |
| M7 Acts 2–3 | Campaign pass, public release |

If M1 fails its gate, the fallback is the native-plugin hit check before any content work starts.

**Risks.**

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Hit timing feels laggy through Lua | Core feel fails | Spike 3 and 9 in M0; native plugin for the hit check |
| Animation workload (10 families × 3 swings, casts, reactions) | Schedule | Ship 3 families in M1–M2; reuse BG3 animations retimed where possible |
| Scripted fights break | Story blockers | Per-encounter overrides and manual turn-based toggle |
| BG3 or Script Extender patch breaks hooks | Mod stops working | Keep native code minimal; pin versions; fix-forward process |
| Balance with aimed hits and mana | Fights too easy or too hard | All numbers in data and MCM; playtest each act |
| Native UI tab conflicts with UI mods | Install friction | ImGui fallback stays available |
| Multiplayer desync | Co-op unplayable | Server authority from M1; two-instance tests from M2 |

**Open questions.**

- [x] Fork Brawl (GPL-3.0) or start fresh? **Forked** (DECISIONS 2026-10-08).
- [x] Use an existing WASD movement mod or write our own? **WASD Character Movement**, with our DLL driving its speed (DECISIONS 2026-10-09); since 2026-10-13 **our own direct controller** moves the character in first person, and BG3WASD stays for everything else it does (`vanilla` mode keeps its movement as a fallback).
- [ ] Offer a single-player tactical pause?
- [ ] Keep spell preparation, or let casters put any known spell on the hotbar?
- [ ] Final mana numbers after the M1 playtest
- [ ] Should healing be aimed at allies, or snap to the nearest injured ally?
- [ ] Support controllers, or mouse and keyboard only?

**Sources.**

- [Brawl — real-time combat mod for BG3 (GitHub)](https://github.com/tinybike/Brawl)
- [BG3 Script Extender (GitHub)](https://github.com/Norbyte/bg3se)
- [First-person BG3 mod setup (ITC.ua)](https://itc.ua/en/news/a-modder-turned-baldur-s-gate-3-into-a-first-person-game-now-sven-winke-wants-to-play-it-that-way-too)
- [Ghidra MCP server (GitHub)](https://github.com/bethington/ghidra-mcp)
- [universal-modder (GitHub)](https://github.com/rehan-remade/universal-modder)
