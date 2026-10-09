# Playtest: animation browser + gallery (one pass)

DEV-SAVE. In the SE console type `client` first; every command below runs at the `C >>` prompt. Lines in quotes are what `client.log` / `server.log` should show. I read the logs afterwards; tell me what you **saw**.

## 0. Speed lever probe (30 s)

1. In first person, stand still:
   ```
   !dag_anim_vars playrate
   ```
   - Expected: `AnimVars: N variable names (Resource.Blueprints[1]) …`, followed by a `[i] PlayRate type=… value=1` line **or** no PlayRate line.
   - This decides whether the speed slider and the jump slow-down work on gameplay characters. See docs/spikes/anim-speed.md.

## 1. Browser on Gale

2. Open the browser:
   ```
   !dag_animlib
   ```
   - "AnimLib: browser open (first person off while open)" — the camera goes third person.
   - "AnimLib: N targets (you, party, within 10 m)".
   - "AnimLib: Gale rig=HUM_M source=AnimationSet component sets=N -> building list" the first time (then "… clips in X s (cached …)"), or "-> N clips from cache …".
   - "AnimLib: play-rate lever on Gale: PlayRate variable found" or "not available".
3. In the window, set Category = Melee, Phase = Attack, Family = 1HS. Click a row, then **Play**. Do this for 3 clips.
   - "AnimLib: play HUM_M_Rig_1HS_CMBT_Melee_… on Gale (you) via mapping 1/N (…)".
   - Server: "Net: PlayAnim uuid=… anim=…".
4. Optional: if a clip doesn't move Gale, press **Try next id**, then **It played** once one works.
   - "AnimLib: … plays via mapping|resource".
5. Only if step 0 found PlayRate: set the slider to 0.3 and press **Apply to target**, then Play.
   - "AnimLib: speed: x0.30 on 1/1 target". The swing should look slow.
   - Press **1x** afterwards.

## 2. Gallery

6. Spawn the gallery:
   ```
   !dag_animlib gallery 12
   ```
   - Server: "AnimLib: template scan for rig HUM_M took N ms …; top: …".
   - "AnimLib: gallery 12 copies of rig HUM_M using template …".
   - "AnimLib: copy setup SetCanJoinCombat=ok …" and "AnimLib: face player via Osi.SteerTo …".
   - Client: "AnimLib: gallery ready, 12 slots in N ms".
   - **Expect:** 12 copies 4 m ahead, each looping a different clip, each with a "#n clip (1.2s)" label over its head.
7. Click **Next >** (or press PageDown) and **< Prev** (PageUp). The copies change clips, and no new ones spawn.
8. Click row #3, then **Solo selected**.
   - "AnimLib: solo …". Gallery loops pause and Gale plays #3.
   - Tick **loop** to resume.
9. Tag swings: pick a row, choose `swing1` under "Use as", press **Tag selected**. Repeat for `swing2` and `swing3`.
   - "AnimLib: tagged swing1 -> … (mapping …)".
10. Close the window (X).
    - "AnimLib: gallery cleared (browser closed)".
    - Server: "AnimLib: removed 12 gallery copies (browser closed)".
    - "AnimLib: browser closed (window closed), first person back on".
    - **Expect:** the copies are gone.

## 3. Tags in play

11. In first person, click LMB 3 times (slowly).
    - "Swing: #1 uses tagged clip … (mapping)", then the same for #2 and #3.
    - **Expect:** the clips you picked.
12. Export the tags:
    ```
    !dag_animlib_export
    ```
    A Lua table prints in the console and log. Paste it to me, or into `data/anim_tags.lua`.

## 4. Other rigs

13. Open `!dag_animlib`, then switch **Target** to Shadowheart.
    - "AnimLib: Shadowheart rig=HUM_F …". Her list differs.
14. Select the swing1 clip's row (search its name), then click **Coverage**.
    - The first time: "AnimLib: building the global animation index (one time, several minutes)…", with progress in the window.
    - When done: "coverage of <id>: HUM_M: … HUM_F: … GAPS (no clip): …".
15. If you have time, repeat 13 for Karlach and Lae'zel (and a dwarf/halfling save). Note the rig and whether swing1 plays on them with **Play**.

## 5. Load

16. Run `!dag_animlib gallery 20`, then `!dag_animlib gallery 25`. **How do the spawn and fps feel? Any hitches?**
    - "AnimLib: tick took N ms …" lines show up only when a tick took over 2 ms.
17. Close and reopen `!dag_animlib`. The list should load instantly ("… from cache").
18. With the gallery open, save, then load that save.
    - "AnimLib: removed N leftover gallery copies …" may appear. **Expect:** no copies left in the world.

## What I need from you

- Step 0: did a PlayRate line appear?
- Did the copies appear in a grid, facing you, with readable labels?
- Did the tagged swings play in first person?
- How did gallery 20/25 feel, and did any copy stay after load?
