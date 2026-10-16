-- SPDX-License-Identifier: GPL-3.0-or-later
-- "What am I looking at" and the F key (Client/LookAt.lua, Client/Interact.lua,
-- Server/Combat/Interact.lua; DECISIONS 2026-10-12).
--
--   reach_m          F works on things whose surface is this close to the eye
--                    (the character walks the last step itself, like a click)
--   server_reach_m   the server refuses an interaction farther than this
--                    from the character (lag / aim slack)
--   cone_deg         nearby scan (when the physics ray can't name the entity):
--                    an object counts within this angle of the crosshair
--   scan_radius_m    objects within this of the player are scanned
--   update_hz        how often LookAt recomputes (the result is cached)
--   classify_ttl_s   the server's answer "what is this" is kept this long
--   max_m            the crosshair's world point / character ray length
--   marker           draw "[F]" on the object and BG3's highlight circle under it
--   use_actions      BG3 use actions that give an item "[F] Use" (below)
--   use_verbs        the prompt verb for a use action ("Sit on" a chair)
return {
    reach_m        = 4.0,
    server_reach_m = 6.0,
    cone_deg       = 8,
    scan_radius_m  = 8,
    update_hz      = 20,
    classify_ttl_s = 10,
    max_m          = 100,
    marker         = true,
    -- Prompt verbs by kind (the server sends the kind and the name).
    verbs = {
        talk   = "Talk to",
        loot   = "Loot",
        open   = "Open",
        close  = "Close",
        door   = "Open",
        pickup = "Pick up",
        use    = "Use",
        climb  = "Climb",
        locked = "Open (locked)",
        rpgflag = "Toggle",   -- an RPG Mode flag (Server/Combat/RpgMode.lua)
    },
    -- BG3 use actions (ActionDataType) that make an item "[F] Use": what a
    -- click does with it in the world. Inventory-only ones (Equip, Consume,
    -- Throw, LearnSpell, SpellBook, Combine, Recipe, Lockpick, DisarmTrap,
    -- StoryUseInInventory) are left out; Door and Ladder have their own kinds.
    -- An item with none of these, and no door, ladder, container or pickup,
    -- gets no [F] (playtest 2026-10-13: the nautiloid's brain jars and an
    -- invisible helper item showed "[F] Use").
    use_actions = { "StoryUse", "Sit", "Lie", "Stand", "OpenClose", "Teleport", "UseSpell", "PlaySound",
                    "CreateSurface", "CreatePuddle", "SpawnCharacter", "ShowStoryElementUI", "Destroy",
                    "Book", "Insert", "Constrain" },
    -- The prompt verb for a use action (else verbs.use).
    use_verbs = { Sit = "Sit on", Lie = "Lie on", Book = "Read" },
}
