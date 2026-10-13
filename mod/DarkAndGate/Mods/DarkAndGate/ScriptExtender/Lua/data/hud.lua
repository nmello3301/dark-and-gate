-- SPDX-License-Identifier: GPL-3.0-or-later
-- First-person HUD tuning (Client/HUD/Hud.lua, docs/design/hud.md).
-- The art and its layout come from tools/hud/slice.py (data/hud_layout.lua,
-- the DAG_HUD_Atlas texture); everything a player might tune is here.

return {
    -- HUD width as a fraction of the screen width (the art's 2172 px canvas
    -- is scaled to it), and its gap to the bottom edge in screen pixels.
    width_frac   = 0.58,
    bottom_px    = 34,
    -- Update rates. Orb fills and bars: fill_hz; numbers / icons: text_hz.
    fill_hz      = 30,
    text_hz      = 8,

    -- ImGui fonts SE preloads with BG3's own serif (QuadraatOffcPro):
    -- "Tiny", "Small", "Medium", "Default", "Large", "Big".
    font_numbers = "Small",   -- "105/110 HP" under the orbs
    font_keys    = "Tiny",    -- key labels on the hotbar and potion plates
    -- Rough glyph width / font size, to centre text (ImGui can't measure from Lua).
    glyph_w      = 0.5,
    font_px      = { Tiny = 24, Small = 28, Medium = 32, Default = 36, Large = 40, Big = 44 },
    -- Where the 1..0 key labels go: "art" = the art's number row under the
    -- slots (on the hotbar), "above" = above the slots.
    key_labels   = "art",
    keys         = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    text_color   = { 0.93, 0.86, 0.70, 1.0 },
    numbers_color = { 0.95, 0.92, 0.85, 1.0 },

    -- Hotbar slots: spell icons inset into the slot art (canvas px), and
    -- the tint when the spell costs more mana than the pool holds.
    icon_inset   = 9,
    no_mana_tint = { 0.40, 0.40, 0.55, 1.0 },

    -- Potion keys (developer, 2026-10-12): R = health, T = mana.
    potion_keys  = { health = "T", mana = "Y" },   -- R reloads crossbows (2026-10-12)
    no_potion_tint = { 0.35, 0.35, 0.35, 0.8 },

    -- Orbs: the meniscus line drawn at the liquid's edge.
    meniscus     = true,
    low_pulse_below = 0.25,   -- the orb pulses below this fraction

    -- Spell cast bar (blue, above the hotbar centre): its width as a
    -- fraction of the HUD width, and its gap above the bar art (canvas px).
    castbar_width_frac = 0.42,
    castbar_gap        = 18,
    castbar_drain_s    = 0.35,   -- cancel: the fill drains over this long
    castbar_flash_s    = 0.20,   -- release: the full bar flashes, then hides
    ready_pulse_hz     = 1.6,

    -- Bow draw ring around the crosshair (amber), diameter in screen px.
    bow_ring_px  = 120,

    -- Vanilla HUD widgets hidden while the first-person HUD is up (Noesis
    -- names under ContentRoot, docs/spikes/hud-tech.md), re-applied every
    -- reapply_s in case the game recreates them.
    hide_vanilla = { "HotBar", "PlayerPortraits", "CombatLog", "Minimap", "TargetInfo",
                     "TurnModeInfo", "CombatantsOverlay", "HudIndicator" },
    reapply_s    = 1.0,
    -- Widgets that mean "a menu is open" when visible: our HUD hides, BG3's
    -- comes back and mouse-look lets go of the cursor (FullPov.SetMenuOpen)
    -- until it closes. Names = the widgets BG3's keyboard UI state machine
    -- loads in its panel / pause / popup layers (Mods/MainUI/GUI/
    -- StateMachines/Keyboard.xaml); !dag_hud widgets lists what is there.
    --   I = ToggleInventory -> CharacterPanel (also K spells, H alchemy)
    --   Tab = TogglePartyCharacterView -> PartyPanel (a button on PlayerPortraits)
    menu_widgets = {
        "CharacterPanel", "PartyPanel", "CompanionsPanel", "Container", "Trade", "Examine", "Combine", "Insert",
        "SplitItem", "LearnSpells", "Pickpocket", "RewardPanel", "Donate", "MakeCamp", "LongRest",
        "TadpolePowersTree", "Book", "MessageBox", "JournalQuests", "JournalMap", "JournalInfo", "JournalDialogues",
        "JournalInspiration", "JournalTutorials", "OverviewMap", "DialogueHistory", "CharacterLevelUp",
        "CharacterRespec", "CharacterFullRespec", "CharacterChangeAppearance", "Henchmen",
        "GameMenu", "GameOptions", "AudioOptions", "VideoOptions", "InterfaceOptions", "KeybindingOptions",
        "ControllerOptions", "AccessibilityOptions", "SaveGame", "LoadGame",
    },
    -- Our "Prepare Hotbar" menu opens beside these BG3 panels (I, K, H, Tab).
    hotbar_menu_with = { "CharacterPanel", "PartyPanel" },
    -- In that menu the slot a spell just went into flashes green this long.
    menu_flash_ms = 700,
    -- After the last menu closes, mouse-look waits this long (our menu window
    -- is gone by then, so the DLL's synthetic MMB press reaches BG3, not ImGui).
    menu_release_ms = 200,
    -- BG3's cursor state is logged this long after a menu opens / closes.
    cursor_probe_ms = 400,
}
