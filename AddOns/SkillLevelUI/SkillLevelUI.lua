--[[ SkillLevelUI — client addon for the skill-leveling realm (WotLK 3.3.5a).
     The server (Eluna, addon prefix "SKILLUI") pushes each tracked skill's level
     and scaled bonus damage; this shows them in spell tooltips ("Skill Level N
     (+X dmg)") and a movable /skillui panel, so you can SEE skills leveling
     instead of the static "Rank 1". Server messages:
        SYNC|<id>:<lvl>:<bonus>,<id>:<lvl>:<bonus>,...     (login / .skillsync)
        LU|<id>:<lvl>:<bonus>                              (on level-up / trainer)
]]--

local PREFIX = "SKILLUI"

-- id -> display name (MUST match server skilllevel_core.lua SKILLS).
local SKILL_NAME = {
  -- damage skills (level on kills)
  [56641] = "Steady Shot",    [3044]  = "Arcane Shot",     [2643]  = "Multi-Shot",
  [1978]  = "Serpent Sting",  [19434] = "Aimed Shot",      [53209] = "Chimera Shot",
  [53301] = "Explosive Shot", [53351] = "Kill Shot",       [1510]  = "Volley",
  [34026] = "Kill Command",   [3674]  = "Black Arrow",     [13813] = "Explosive Trap",
  [2973]  = "Raptor Strike",
  -- practice skills (level on use-count)
  [3045]  = "Rapid Fire",     [19263] = "Deterrence",      [5384]  = "Feign Death",
  [781]   = "Disengage",      [136]   = "Mend Pet",        [53271] = "Master's Call",
  [1499]  = "Freezing Trap",  [1130]  = "Hunter's Mark",   [883]   = "Call Pet",
  [982]   = "Revive Pet",
}
local ORDER = {
  56641, 3044, 2643, 1978, 19434, 53209, 53301, 53351, 1510, 34026, 3674, 13813, 2973,
  3045, 19263, 5384, 781, 136, 53271, 1499, 1130, 883, 982,
}

-- name -> id, for matching a spell tooltip back to a tracked skill.
local NAME_ID = {}
for id, name in pairs(SKILL_NAME) do NAME_ID[name] = id end

-- Skills whose REAL damage the core (mod-skilllevel/DamageScaling.cpp) scales, so
-- it's honest to rewrite their tooltip damage number. Explosive Trap (13813) is
-- intentionally absent: its damage comes from a triggered spell the core doesn't
-- scale yet, so we leave its tooltip untouched rather than show a false number.
local TOOLTIP_SCALED = {
  [56641]=true, [3044]=true, [2643]=true, [1978]=true, [19434]=true, [53209]=true,
  [53301]=true, [53351]=true, [1510]=true, [34026]=true, [3674]=true, [2973]=true,
}
-- How many damage instances the printed spellbook TOTAL represents. The server
-- sends the per-hit/per-tick bonus; a DoT's tooltip total = base + bonus*ticks,
-- a direct shot's = base + bonus*1. DoT tick counts (default 1 = direct):
local DMG_INSTANCES = { [1978] = 5, [3674] = 5, [53301] = 3 }  -- Serpent, Black Arrow, Explosive Shot

-- SMOKE-TEST AID: each seeded skill's milestones as {level, code, value} + its
-- Ascension-loop cycle, mirroring custom-sql/world/010_skilllevel_milestones.sql.
-- The addon RESOLVES accumulated magnitude per effect (signature + loop) at the
-- current level, so the tooltip shows totals ("Targets +2", "Crit damage +50%")
-- that grow as the loop cycles. (Later replaced by a server-pushed sync, spec §5.)
-- All skill ladders come from the generated SkillLevelUI_Data.lua (merged just below),
-- which is regenerated from the DB seed — so the display always matches the live engine
-- (levels, values, cadence). No hand-authored entries here anymore.
local SKILL_UPG = {}
-- Merge the generated all-skills data (SkillLevelUI_Data.lua, 306 skills) so every
-- class's abilities show upgrade tooltips — not just the 5 hand-tuned Hunter test
-- skills. Hand-tuned entries stay authoritative; the generated data fills the rest.
if SkillLevelUI_GenSkills then
  for id, def in pairs(SkillLevelUI_GenSkills) do
    if SKILL_UPG[id] == nil then SKILL_UPG[id] = def end
  end
end
if SkillLevelUI_GenNames then
  for name, id in pairs(SkillLevelUI_GenNames) do
    if NAME_ID[name] == nil then NAME_ID[name] = id end
  end
end
-- v3 curve — MUST match SkillCurve in mod-skilllevel/SkillMilestones.h:
--   final = (D + 1*(L-1)) * (1 + 0.10*floor(L/10))
-- The tooltip rewrites the description's own damage number in place using this,
-- so the number the player reads IS the scaled hit.
local SL_FLAT_PER_LEVEL = 1      -- flat per level (direct hits + heals; not DoT ticks)
local SL_SPIKE_PER_10   = 0.10   -- +10% spike at level 10, 20, 30…
-- Only damage-category skills get their description number rewritten (a practice skill's
-- level lives in a different table; scaling its chip damage would lie).
local DMG = {}
if SkillLevelUI_GenDamage then for id in pairs(SkillLevelUI_GenDamage) do DMG[id] = true end end
for id in pairs(TOOLTIP_SCALED) do DMG[id] = true end

-- Mirrors DefaultStep() in SkillMilestones.cpp — keep in sync or loop tooltips lie.
local LOOP_STEP = { CRIT_MULT=0.25, PEN=0.05, EXECUTE=1.0, VULN=0.03, RAMP=0.03,
  CDR=200, CAST=200, FASTER=200, AREA=1, TARGET=1, SHOT=1, RICOCHET=1, TICK=1, STACK=1,
  COND=0.05, SHRED=0.03, GENRES=2, ENRAGE=0.03, LEECH=0.05, CLEAVE=0.10, IMPACT=0.10,
  SCHOOL2=0.10, COST=0.05, FREE=0.05, RESET=0.05, DETONATE=0.10, CRITBURN=0.10,
  DURATION=0.05, POTENCY=0.05, SPEED=0.05, HEALCRIT=0.05, ABSORB=0.05, REGEN=0.05,
  HEAL=0.05, MITIGATION=0.02, PRIMARY=0.05, CC=0.10 }
-- code -> { order, label, unit, live }   live = true / "cdr" / false(not built yet)
local EFFECT = {
  EXECUTE   = {1,  "Execute",            "pct",   true},
  CRIT_MULT = {2,  "Crit damage",        "pct",   true},
  TARGET    = {3,  "Targets",            "count", true},
  SHOT      = {4,  "Extra shots",        "count", true},
  PEN       = {5,  "Armor pen",          "pct",   true},
  VULN      = {6,  "Vulnerability",      "pct",   true},
  FREE      = {7,  "Free-cast chance",   "pct",   true},
  TICK      = {8,  "DoT ticks",          "count", true},
  STACK     = {9,  "Max stacks",         "count", true},
  CDR       = {10, "Cooldown",           "cdr",   "cdr"},
  SCHOOL2   = {20, "Secondary damage",   "pct",   true},
  IMPACT    = {21, "Impact splash",      "pct",   true},
  RICOCHET  = {22, "Ricochet bounces",   "count", true},
  FASTER    = {23, "Faster ticks",       "cdr",   true},
  RAMP      = {24, "Ramp per cast",      "pct",   true},
  GENRES    = {25, "Resource on hit",    "count", true},
  CAST      = {26, "Cast time",          "cdr",   true},
  PIERCE    = {27, "Pierces enemies",    "flag",  false},
  DOTCRIT   = {28, "Ticks can crit",     "flag",  true},
  SPREAD    = {29, "Spreads on death",   "flag",  true},
  REFRESH   = {30, "Refreshes your DoT", "flag",  true},
  REFUND    = {31, "Refund on kill",     "flag",  false},
  MISC      = {32, "Higher HP threshold","flag",  false},
  TRANSFORM = {33, "Signature transform","flag",  true},
  AREA      = {34, "Bigger area",        "count", true},
  -- full vocabulary — every seeded upgrade code must be here or it renders as nothing
  -- (this was the "upgrades don't start until L5-6" bug: e.g. Raptor Strike's L4 Cleave).
  CLEAVE      = {35, "Cleave splash",       "pct",   true},
  LEECH       = {36, "Life leech",          "pct",   true},
  COND        = {37, "Condition bonus",     "pct",   true},
  RESET       = {38, "Reset chance",        "pct",   true},
  COST        = {39, "Cost reduction",      "pct",   true},
  SHRED       = {40, "Armor shred",         "pct",   true},
  CC          = {41, "CC strength",         "pct",   true},
  MINICC      = {42, "Mini-CC chance",      "pct",   false},
  CRIT_CHANCE = {43, "Crit chance",         "pct",   false},
  CHARGES     = {44, "Charges",             "count", true},
  CHANNEL     = {45, "Channel ticks",       "count", true},
  DETONATE    = {46, "Detonate burst",      "pct",   true},
  HAZARD      = {47, "Ground hazard",       "flag",  false},
  CONTAGION   = {48, "Contagion",           "flag",  true},
  CRITBURN    = {49, "Crit burn",           "pct",   true},
  STINGREFRESH= {50, "Sting refresh",       "pct",   false},
  AUTOSTING   = {51, "Auto-applies Sting",  "flag",  false},
  RANGE       = {52, "Range",               "count", false},
  SNAREBREAK  = {53, "Snare break",         "flag",  true},
  THREATWIPE  = {54, "Threat wipe",         "flag",  true},
  CLEANSE     = {55, "Cleanse breadth",     "count", false},
  REFLECT     = {56, "Reflect",             "pct",   true},
  REDIRECT    = {57, "Damage redirect",     "pct",   false},
  EMPOWER     = {58, "Empower proc",        "pct",   false},
  IMBUE       = {59, "Imbue proc",          "pct",   false},
  PETCLEAVE   = {60, "Pet cleave",          "pct",   false},
  PETBLEED    = {61, "Pet bleed",           "flag",  false},
  PETFRENZY   = {62, "Pet frenzy",          "pct",   false},
  ENRAGE      = {63, "Enrage",              "pct",   true},
  HEALRED     = {64, "Healing reduction",   "pct",   false},
  COMBO       = {65, "Combo scaling",       "count", false},
  REACTIVE    = {66, "Reactive enabler",    "flag",  false},
  THRESHOLD   = {67, "Execute threshold",   "pct",   false},
  DURATION    = {68, "Duration",            "pct",   true},
  POTENCY     = {69, "Potency",             "pct",   true},
  ABSORB      = {70, "Absorb",              "pct",   true},
  REGEN       = {71, "Regen",               "pct",   true},
  MITIGATION  = {72, "Mitigation",          "pct",   true},
  HEAL        = {73, "Heal amount",         "pct",   true},
  HOT         = {74, "Heal-over-time",      "flag",  false},
  SMARTHEAL   = {75, "Smart heal",          "flag",  false},
  OVERHEAL    = {76, "Overheal shield",     "flag",  false},
  HEALCRIT    = {77, "Heal crit",           "pct",   true},
  SPEED       = {78, "Haste",               "pct",   true},
  IMMUNITY    = {79, "Immunity",            "flag",  false},
  REQFREE     = {80, "No requirement",      "flag",  false},
  PUSHBACK    = {81, "Pushback immunity",   "flag",  false},
  TOTEM       = {82, "Totem",               "flag",  false},
  SHRAPNEL    = {83, "Shrapnel",            "flag",  false},
}
-- accumulate per-effect magnitude at level `lvl` (signature milestones + loop)
local function slResolve(id, lvl)
  local s = SKILL_UPG[id]; if not s then return nil end
  local acc, last = {}, 0
  for _, e in ipairs(s.ms) do
    if e[1] <= lvl then acc[e[2]] = (acc[e[2]] or 0) + e[3]; if e[1] > last then last = e[1] end end
  end
  if s.loop and last > 0 and lvl > last then
    for i = 0, math.floor((lvl - last) / 3) - 1 do
      local c = s.loop[(i % #s.loop) + 1]
      acc[c] = (acc[c] or 0) + (LOOP_STEP[c] or 1)
    end
  end
  return acc
end
local function slAmount(code, v)
  local u = EFFECT[code] and EFFECT[code][3]
  if u == "count" then return "+" .. math.floor(v + 0.001) end
  if u == "pct"   then return "+" .. math.floor(v * 100 + 0.5) .. "%" end
  if u == "cdr"   then return "-" .. string.format("%.1f", v / 1000) .. "s" end
  if u == "ms"    then return "-" .. math.floor(v) .. "ms" end
  return ""   -- flag: no amount
end

-- Talent DBC id -> percent added to its tooltip description per overload rank (mirrors
-- the server effect). Add a talent here when you map it to a flat-% effect in TalentUncap.cpp.
-- talent DBC id -> % added to its tooltip "…by N%" line per overload rank (matches server perRank).
local DESC_PCT = {
  [1344] = 1,   -- Lethal Shots (crit)
  [1321] = 1,   -- Killer Instinct (crit)
  [1807] = 1,   -- Master Marksman (crit)
  [2197] = 1,   -- Focused Aim (hit)
  [1802] = 4,   -- Serpent's Swiftness (haste)
  [1381] = 2,   -- Improved Aspect of the Monkey (dodge)
  [1801] = 2,   -- Catlike Reflexes (dodge)
  [1311] = 1,   -- Deflection (parry)
  [1624] = 1,   -- Focused Fire (% dmg)
  [1348] = 2,   -- Improved Stings (% dmg)
  [1362] = 1,   -- Ranged Weapon Specialization (% dmg)
  [2134] = 1,   -- Marked for Death (% dmg)
  [1347] = 4,   -- Barrage (% dmg)
  [1800] = 1,   -- Ferocious Inspiration (% dmg)
  [1396] = 3,   -- Unleashed Fury (% pet dmg)
  [2227] = 3,   -- Kindred Spirits (% pet dmg)
  [1945] = 1,   -- Subversion
  [2217] = 2,   -- Two-Handed Weapon Specialization
  [1943] = 1,   -- Dark Conviction
  [1942] = 2,   -- Improved Rune Tap
  [2015] = 2,   -- Bloody Strikes
  [2259] = 2,   -- Improved Death Strike
  [1973] = 2,   -- Black Ice
  [2022] = 1,   -- Nerves of Cold Steel
  [2048] = 1,   -- Annihilation
  [2223] = 1,   -- Improved Icy Talons
  [1992] = 1,   -- Rime
  [2210] = 2,   -- Blood of the North
  [2082] = 1,   -- Vicious Strikes
  [1933] = 2,   -- Morbidity
  [2008] = 2,   -- Outbreak
  [2043] = 1,   -- Ebon Plaguebringer
  [2238] = 2,   -- Genesis
  [1822] = 1,   -- Nature's Majesty
  [763] = 1,   -- Improved Moonfire
  [790] = 2,   -- Moonfury
  [1925] = 2,   -- Gale Winds
  [795] = 2,   -- Feral Aggression
  [799] = 2,   -- Feral Instinct
  [805] = 2,   -- Savage Fury
  [798] = 1,   -- Sharpened Claws
  [821] = 2,   -- Improved Mark of the Wild
  [828] = 2,   -- Gift of Nature
  [825] = 1,   -- Nature's Bounty
  [1382] = 2,   -- Improved Aspect of the Hawk
  [1389] = 2,   -- Endurance Training
  [1395] = 2,   -- Thick Hide
  [1393] = 2,   -- Ferocity
  [1390] = 2,   -- Bestial Discipline
  [1803] = 2,   -- The Beast Within
  [1346] = 2,   -- Improved Arcane Shot
  [1821] = 1,   -- Improved Barrage
  [1621] = 1,   -- Savage Strikes
  [1305] = 2,   -- Trap Mastery
  [1810] = 1,   -- Survival Instincts
  [2229] = 2,   -- T.N.T.
  [2143] = 1,   -- Sniper Training
  [82] = 2,   -- Magic Attunement
  [81] = 2,   -- Spell Impact
  [421] = 2,   -- Arcane Instability
  [1727] = 2,   -- Arcane Empowerment
  [1141] = 1,   -- Incineration
  [31] = 1,   -- World in Flames
  [1730] = 2,   -- Playing with Fire
  [33] = 1,   -- Critical Mass
  [35] = 2,   -- Fire Power
  [1733] = 1,   -- Pyromaniac
  [70] = 2,   -- Frost Warding
  [61] = 2,   -- Piercing Ice
  [64] = 2,   -- Improved Cone of Cold
  [1738] = 2,   -- Arctic Winds
  [1856] = 2,   -- Chilled to the Bone
  [1463] = 2,   -- Seals of the Pure
  [1444] = 2,   -- Healing Light
  [1446] = 2,   -- Improved Blessing of Wisdom
  [1465] = 1,   -- Sanctified Light
  [1627] = 1,   -- Holy Power
  [2191] = 1,   -- Enlightened Judgements
  [1429] = 2,   -- One-Handed Weapon Specialization
  [1401] = 2,   -- Improved Blessing of Might
  [1411] = 1,   -- Conviction
  [1761] = 1,   -- Sanctity of Battle
  [1755] = 2,   -- Crusade
  [1410] = 2,   -- Two-Handed Weapon Specialization
  [2176] = 2,   -- The Art of War
  [1759] = 1,   -- Fanaticism
  [2127] = 2,   -- Spiked Collar
  [2177] = 2,   -- Cornered
  [2125] = 2,   -- Spiked Collar
  [2129] = 1,   -- Spider's Bite
  [2254] = 2,   -- Shark Attack
  [2126] = 2,   -- Spiked Collar
  [1898] = 2,   -- Twin Disciplines
  [346] = 2,   -- Improved Inner Fire
  [344] = 2,   -- Improved Power Word: Fortitude
  [343] = 2,   -- Improved Power Word: Shield
  [401] = 1,   -- Holy Specialization
  [403] = 2,   -- Searing Light
  [404] = 2,   -- Spiritual Healing
  [1905] = 2,   -- Divine Providence
  [462] = 2,   -- Darkness
  [1638] = 2,   -- Improved Vampiric Embrace
  [1781] = 1,   -- Mind Melt
  [276] = 2,   -- Improved Eviscerate
  [270] = 1,   -- Malice
  [277] = 1,   -- Puncturing Wounds
  [682] = 2,   -- Vile Poisons
  [279] = 2,   -- Improved Kidney Shot
  [274] = 2,   -- Murder
  [1718] = 2,   -- Find Weakness
  [181] = 1,   -- Precision
  [182] = 1,   -- Close Quarters Combat
  [186] = 1,   -- Lightning Reflexes
  [1122] = 2,   -- Aggression
  [1709] = 2,   -- Surprise Attacks
  [261] = 2,   -- Opportunity
  [1700] = 2,   -- Sleight of Hand
  [263] = 1,   -- Improved Ambush
  [563] = 2,   -- Concussion
  [561] = 2,   -- Call of Flame
  [567] = 2,   -- Improved Fire Nova
  [562] = 1,   -- Call of Thunder
  [2049] = 1,   -- Elemental Oath
  [610] = 2,   -- Enhancing Totems
  [2101] = 2,   -- Earth's Grasp
  [609] = 2,   -- Guardian Totems
  [613] = 1,   -- Thundering Strikes
  [607] = 2,   -- Improved Shields
  [611] = 2,   -- Elemental Weapons
  [1643] = 2,   -- Weapon Mastery
  [1692] = 1,   -- Dual Wield Specialization
  [588] = 2,   -- Restorative Totems
  [594] = 1,   -- Tidal Mastery
  [1648] = 2,   -- Healing Way
  [2060] = 1,   -- Blessing of the Eternals
  [1697] = 2,   -- Improved Chain Heal
  [1003] = 1,   -- Improved Corruption
  [1042] = 2,   -- Shadow Mastery
  [1669] = 2,   -- Contagion
  [1667] = 1,   -- Malediction
  [1222] = 2,   -- Improved Imp
  [1224] = 2,   -- Improved Health Funnel
  [1225] = 2,   -- Demonic Brutality
  [1242] = 2,   -- Fel Vitality
  [1671] = 2,   -- Demonic Aegis
  [1262] = 2,   -- Unholy Power
  [1680] = 2,   -- Demonic Resilience
  [1673] = 2,   -- Demonic Tactics
  [1885] = 2,   -- Demonic Pact
  [965] = 1,   -- Improved Searing Pain
  [961] = 2,   -- Improved Immolate
  [981] = 1,   -- Devastation
  [966] = 2,   -- Emberstorm
  [2045] = 2,   -- Empowered Imp
  [1890] = 1,   -- Fire and Brimstone
  [126] = 2,   -- Improved Charge
  [131] = 1,   -- Improved Overpower
  [136] = 2,   -- Two-Handed Weapon Specialization
  [132] = 1,   -- Poleaxe Specialization
  [1824] = 2,   -- Improved Mortal Strike
  [1664] = 1,   -- Blood Frenzy
  [157] = 1,   -- Cruelty
  [161] = 2,   -- Improved Demoralizing Shout
  [166] = 2,   -- Improved Cleave
  [154] = 2,   -- Commanding Presence
  [1657] = 1,   -- Precision
  [1655] = 2,   -- Improved Whirlwind
  [1659] = 1,   -- Rampage
  [2234] = 2,   -- Unending Fury
  [144] = 1,   -- Incite
  [147] = 2,   -- Improved Revenge
  [702] = 2,   -- One-Handed Weapon Specialization
  [1893] = 1,   -- Critical Block
}

-- Talent DBC ids that are OVERLOADABLE (must match the server registry in TalentUncap.cpp).
-- Only these get the overload click, the "Rank X" display, and the green-at-cap border.
-- Everything else — ability grants (Chimera Shot etc.) and undesigned talents — stays vanilla.
local OVERLOADABLE = {   -- ALL passive talents (generated); active/ability talents excluded
  [23]=true,[24]=true,[25]=true,[26]=true,[27]=true,[28]=true,[30]=true,[31]=true,[33]=true,[34]=true,
  [35]=true,[37]=true,[38]=true,[61]=true,[62]=true,[63]=true,[64]=true,[65]=true,[66]=true,[67]=true,
  [68]=true,[70]=true,[73]=true,[74]=true,[75]=true,[76]=true,[77]=true,[80]=true,[81]=true,[82]=true,
  [83]=true,[85]=true,[88]=true,[121]=true,[123]=true,[124]=true,[125]=true,[126]=true,[127]=true,[128]=true,
  [129]=true,[130]=true,[131]=true,[132]=true,[134]=true,[136]=true,[137]=true,[138]=true,[140]=true,[141]=true,
  [142]=true,[144]=true,[146]=true,[147]=true,[149]=true,[150]=true,[151]=true,[154]=true,[155]=true,[156]=true,
  [157]=true,[158]=true,[159]=true,[161]=true,[166]=true,[181]=true,[182]=true,[184]=true,[186]=true,[187]=true,
  [201]=true,[203]=true,[204]=true,[206]=true,[221]=true,[222]=true,[241]=true,[242]=true,[244]=true,[245]=true,
  [246]=true,[247]=true,[261]=true,[262]=true,[263]=true,[265]=true,[268]=true,[269]=true,[270]=true,[272]=true,
  [273]=true,[274]=true,[276]=true,[277]=true,[278]=true,[279]=true,[281]=true,[283]=true,[321]=true,[341]=true,
  [342]=true,[343]=true,[344]=true,[346]=true,[347]=true,[350]=true,[351]=true,[352]=true,[361]=true,[382]=true,
  [401]=true,[402]=true,[403]=true,[404]=true,[406]=true,[408]=true,[410]=true,[411]=true,[413]=true,[421]=true,
  [461]=true,[462]=true,[463]=true,[465]=true,[466]=true,[481]=true,[482]=true,[483]=true,[542]=true,[561]=true,
  [562]=true,[563]=true,[564]=true,[565]=true,[567]=true,[574]=true,[575]=true,[581]=true,[583]=true,[586]=true,
  [587]=true,[588]=true,[589]=true,[592]=true,[593]=true,[594]=true,[595]=true,[601]=true,[602]=true,[605]=true,
  [607]=true,[609]=true,[610]=true,[611]=true,[613]=true,[614]=true,[615]=true,[617]=true,[641]=true,[661]=true,
  [662]=true,[682]=true,[702]=true,[721]=true,[741]=true,[762]=true,[763]=true,[764]=true,[782]=true,[783]=true,
  [784]=true,[789]=true,[790]=true,[792]=true,[794]=true,[795]=true,[796]=true,[797]=true,[798]=true,[799]=true,
  [802]=true,[803]=true,[805]=true,[807]=true,[808]=true,[809]=true,[821]=true,[822]=true,[823]=true,[824]=true,
  [825]=true,[826]=true,[827]=true,[828]=true,[829]=true,[830]=true,[841]=true,[842]=true,[843]=true,[881]=true,
  [941]=true,[943]=true,[944]=true,[961]=true,[964]=true,[965]=true,[966]=true,[967]=true,[981]=true,[982]=true,
  [983]=true,[985]=true,[986]=true,[1001]=true,[1002]=true,[1003]=true,[1004]=true,[1005]=true,[1006]=true,[1007]=true,
  [1021]=true,[1041]=true,[1042]=true,[1061]=true,[1101]=true,[1122]=true,[1123]=true,[1141]=true,[1142]=true,[1181]=true,
  [1201]=true,[1202]=true,[1221]=true,[1222]=true,[1223]=true,[1224]=true,[1225]=true,[1227]=true,[1242]=true,[1243]=true,
  [1244]=true,[1261]=true,[1262]=true,[1263]=true,[1281]=true,[1283]=true,[1284]=true,[1303]=true,[1304]=true,[1305]=true,
  [1306]=true,[1309]=true,[1310]=true,[1311]=true,[1321]=true,[1341]=true,[1342]=true,[1343]=true,[1344]=true,[1346]=true,
  [1347]=true,[1348]=true,[1349]=true,[1351]=true,[1362]=true,[1381]=true,[1382]=true,[1384]=true,[1385]=true,[1388]=true,
  [1389]=true,[1390]=true,[1393]=true,[1395]=true,[1396]=true,[1397]=true,[1401]=true,[1402]=true,[1403]=true,[1407]=true,
  [1410]=true,[1411]=true,[1421]=true,[1422]=true,[1423]=true,[1425]=true,[1426]=true,[1429]=true,[1432]=true,[1442]=true,
  [1443]=true,[1444]=true,[1446]=true,[1449]=true,[1450]=true,[1461]=true,[1463]=true,[1464]=true,[1465]=true,[1501]=true,
  [1521]=true,[1541]=true,[1542]=true,[1543]=true,[1561]=true,[1581]=true,[1601]=true,[1621]=true,[1622]=true,[1623]=true,
  [1624]=true,[1625]=true,[1627]=true,[1628]=true,[1629]=true,[1631]=true,[1632]=true,[1633]=true,[1634]=true,[1635]=true,
  [1636]=true,[1638]=true,[1639]=true,[1640]=true,[1641]=true,[1642]=true,[1643]=true,[1645]=true,[1646]=true,[1647]=true,
  [1648]=true,[1649]=true,[1650]=true,[1652]=true,[1653]=true,[1654]=true,[1655]=true,[1657]=true,[1658]=true,[1659]=true,
  [1660]=true,[1661]=true,[1662]=true,[1663]=true,[1664]=true,[1667]=true,[1668]=true,[1669]=true,[1671]=true,[1673]=true,
  [1677]=true,[1678]=true,[1679]=true,[1680]=true,[1682]=true,[1685]=true,[1686]=true,[1689]=true,[1691]=true,[1692]=true,
  [1695]=true,[1696]=true,[1697]=true,[1699]=true,[1700]=true,[1701]=true,[1702]=true,[1703]=true,[1705]=true,[1706]=true,
  [1707]=true,[1709]=true,[1711]=true,[1712]=true,[1713]=true,[1715]=true,[1718]=true,[1721]=true,[1722]=true,[1723]=true,
  [1724]=true,[1725]=true,[1726]=true,[1727]=true,[1728]=true,[1730]=true,[1731]=true,[1732]=true,[1733]=true,[1734]=true,
  [1736]=true,[1737]=true,[1738]=true,[1740]=true,[1742]=true,[1743]=true,[1744]=true,[1745]=true,[1746]=true,[1748]=true,
  [1750]=true,[1751]=true,[1753]=true,[1755]=true,[1756]=true,[1757]=true,[1758]=true,[1759]=true,[1761]=true,[1762]=true,
  [1763]=true,[1764]=true,[1765]=true,[1766]=true,[1767]=true,[1768]=true,[1769]=true,[1771]=true,[1772]=true,[1773]=true,
  [1777]=true,[1778]=true,[1781]=true,[1782]=true,[1783]=true,[1784]=true,[1785]=true,[1786]=true,[1788]=true,[1789]=true,
  [1790]=true,[1792]=true,[1793]=true,[1794]=true,[1795]=true,[1797]=true,[1798]=true,[1799]=true,[1800]=true,[1801]=true,
  [1802]=true,[1803]=true,[1804]=true,[1806]=true,[1807]=true,[1809]=true,[1810]=true,[1811]=true,[1812]=true,[1813]=true,
  [1816]=true,[1817]=true,[1818]=true,[1819]=true,[1820]=true,[1821]=true,[1822]=true,[1824]=true,[1825]=true,[1826]=true,
  [1827]=true,[1843]=true,[1844]=true,[1845]=true,[1846]=true,[1849]=true,[1850]=true,[1851]=true,[1853]=true,[1854]=true,
  [1855]=true,[1856]=true,[1858]=true,[1859]=true,[1860]=true,[1862]=true,[1864]=true,[1865]=true,[1866]=true,[1867]=true,
  [1870]=true,[1871]=true,[1873]=true,[1875]=true,[1876]=true,[1878]=true,[1882]=true,[1883]=true,[1884]=true,[1885]=true,
  [1887]=true,[1888]=true,[1889]=true,[1890]=true,[1893]=true,[1894]=true,[1895]=true,[1896]=true,[1898]=true,[1901]=true,
  [1902]=true,[1903]=true,[1904]=true,[1905]=true,[1906]=true,[1907]=true,[1909]=true,[1912]=true,[1913]=true,[1914]=true,
  [1915]=true,[1916]=true,[1918]=true,[1919]=true,[1920]=true,[1921]=true,[1922]=true,[1924]=true,[1925]=true,[1928]=true,
  [1929]=true,[1930]=true,[1932]=true,[1933]=true,[1934]=true,[1936]=true,[1938]=true,[1939]=true,[1942]=true,[1943]=true,
  [1944]=true,[1945]=true,[1948]=true,[1950]=true,[1953]=true,[1955]=true,[1958]=true,[1960]=true,[1962]=true,[1963]=true,
  [1968]=true,[1971]=true,[1973]=true,[1981]=true,[1984]=true,[1990]=true,[1992]=true,[1993]=true,[1996]=true,[1997]=true,
  [1998]=true,[2001]=true,[2003]=true,[2004]=true,[2005]=true,[2008]=true,[2009]=true,[2011]=true,[2013]=true,[2015]=true,
  [2017]=true,[2018]=true,[2020]=true,[2022]=true,[2025]=true,[2027]=true,[2029]=true,[2030]=true,[2031]=true,[2035]=true,
  [2036]=true,[2040]=true,[2042]=true,[2043]=true,[2044]=true,[2045]=true,[2047]=true,[2048]=true,[2049]=true,[2050]=true,
  [2051]=true,[2052]=true,[2054]=true,[2055]=true,[2056]=true,[2057]=true,[2059]=true,[2060]=true,[2061]=true,[2063]=true,
  [2065]=true,[2066]=true,[2068]=true,[2069]=true,[2070]=true,[2072]=true,[2073]=true,[2074]=true,[2075]=true,[2077]=true,
  [2078]=true,[2079]=true,[2080]=true,[2082]=true,[2083]=true,[2086]=true,[2101]=true,[2105]=true,[2106]=true,[2107]=true,
  [2110]=true,[2112]=true,[2113]=true,[2114]=true,[2116]=true,[2117]=true,[2118]=true,[2120]=true,[2121]=true,[2122]=true,
  [2123]=true,[2124]=true,[2125]=true,[2126]=true,[2127]=true,[2128]=true,[2129]=true,[2130]=true,[2131]=true,[2132]=true,
  [2133]=true,[2134]=true,[2136]=true,[2137]=true,[2138]=true,[2139]=true,[2140]=true,[2141]=true,[2142]=true,[2143]=true,
  [2144]=true,[2147]=true,[2148]=true,[2149]=true,[2151]=true,[2152]=true,[2154]=true,[2160]=true,[2161]=true,[2162]=true,
  [2163]=true,[2165]=true,[2166]=true,[2167]=true,[2168]=true,[2173]=true,[2176]=true,[2177]=true,[2179]=true,[2182]=true,
  [2183]=true,[2185]=true,[2190]=true,[2191]=true,[2193]=true,[2194]=true,[2195]=true,[2197]=true,[2198]=true,[2199]=true,
  [2200]=true,[2204]=true,[2205]=true,[2207]=true,[2208]=true,[2209]=true,[2210]=true,[2212]=true,[2214]=true,[2217]=true,
  [2218]=true,[2222]=true,[2223]=true,[2225]=true,[2226]=true,[2227]=true,[2228]=true,[2229]=true,[2231]=true,[2232]=true,
  [2233]=true,[2234]=true,[2235]=true,[2236]=true,[2238]=true,[2239]=true,[2240]=true,[2241]=true,[2242]=true,[2244]=true,
  [2245]=true,[2246]=true,[2247]=true,[2250]=true,[2252]=true,[2253]=true,[2254]=true,[2255]=true,[2256]=true,[2257]=true,
  [2258]=true,[2259]=true,[2260]=true,[2261]=true,[2262]=true,[2263]=true,[2264]=true,[2266]=true,[2267]=true,[2268]=true,
  [2279]=true,[2281]=true,[2282]=true,[2283]=true,[2284]=true,[2285]=true,
}

-- cached state: id -> { level, bonus }. Repointed at the saved var on load.
local S = {}
local panelRefresh          -- forward declaration
local OL = {}               -- talentId -> overload count (from server "OL|" messages)
local refreshTalentOverlays -- forward declaration (assigned in the overload section)

--=============================== data ingest ===============================--
local function applyPair(str)
  local id, lvl, bonus, xp, xpnext = strsplit(":", str)   -- id:lvl:pct:xp:xpnext  (`bonus` now holds the % the server scales by)
  id = tonumber(id)
  local nlvl = tonumber(lvl)
  -- only overwrite on a well-formed pair, so a garbled message never resets a skill to L1
  if id and nlvl then
    S[id] = { level = nlvl, bonus = tonumber(bonus) or 0, xp = tonumber(xp) or 0, xpnext = tonumber(xpnext) or 0 }
  end
end

local function onAddonMessage(message)
  if not message then return end
  local kind, payload = strsplit("|", message)
  if kind == "SYNC" and payload then
    for _, pair in ipairs({ strsplit(",", payload) }) do
      if pair ~= "" then applyPair(pair) end
    end
  elseif kind == "LU" and payload then
    applyPair(payload)
  elseif kind == "OL" and payload then
    for _, p in ipairs({ strsplit(",", payload) }) do
      if p ~= "" then
        local id, n = strsplit(":", p)
        id = tonumber(id)
        if id then OL[id] = tonumber(n) or 0 end
      end
    end
    if refreshTalentOverlays then refreshTalentOverlays() end
  elseif kind == "OLSYNC" then
    -- AUTHORITATIVE full replace from the server (login): wipe cached counts first so
    -- talents that were reset actually clear, then apply whatever the server still has.
    for k in pairs(OL) do OL[k] = nil end
    if payload and payload ~= "" then
      for _, p in ipairs({ strsplit(",", payload) }) do
        if p ~= "" then
          local id, n = strsplit(":", p)
          id = tonumber(id)
          if id then OL[id] = tonumber(n) or 0 end
        end
      end
    end
    if refreshTalentOverlays then refreshTalentOverlays() end
  end
  if panelRefresh then panelRefresh() end
end

--================================ tooltip ==================================--
-- A real graphical XP bar, re-anchored per-show over a reserved tooltip line
-- (anchoring to a fixed tooltip corner mis-places it, since GameTooltip:Show()
-- does not synchronously resize). Frame level is re-asserted each show.
local xpbar = CreateFrame("StatusBar", "SkillLevelUIXPBar", GameTooltip)
xpbar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
xpbar:SetStatusBarColor(0.25, 0.75, 0.30)
xpbar:SetHeight(10)
xpbar:SetMinMaxValues(0, 1)
local xpbg = xpbar:CreateTexture(nil, "BACKGROUND")
xpbg:SetAllPoints(xpbar)
xpbg:SetTexture(0, 0, 0, 0.6)
local xptext = xpbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
xptext:SetPoint("CENTER", xpbar, "CENTER", 0, 0)
xpbar:Hide()
GameTooltip:HookScript("OnHide", function() xpbar:Hide() end)

local function augmentSpellTooltip(tt)
  xpbar:Hide()
  local ttName = tt:GetName() or "GameTooltip"
  -- 3.3.5a: GetSpell() returns the name only for spellbook tooltips; for action
  -- buttons it's nil, so fall back to the tooltip's own first left line.
  local name = tt:GetSpell()
  if not name then
    local fs = _G[ttName .. "TextLeft1"]
    if fs then name = fs:GetText() end
  end
  if not name then return end
  local id = NAME_ID[name]
  if not id then return end           -- not a tracked skill: leave tooltip alone
  local st = S[id]
  local lvl    = st and st.level  or 1
  local bonus  = st and st.bonus  or 0
  local xp     = st and st.xp     or 0
  local xpnext = st and st.xpnext or 0

  -- Replace the ACTUAL "Rank N" line (scan the right column) with the skill level.
  -- Action-bar / passive tooltips often have no rank line -> add our own instead.
  local replaced = false
  for i = 1, tt:NumLines() do
    local r = _G[ttName .. "TextRight" .. i]
    local txt = r and r:GetText()
    if txt and txt:find("Rank") then
      r:SetText("|cff40d000Level " .. lvl .. "|r"); r:Show()
      replaced = true; break
    end
  end
  if not replaced then
    tt:AddLine("|cff40d000Skill Level " .. lvl .. "|r", 0.25, 0.82, 0.0)
  end

  -- Skill-level scaling: bake the increase INTO the spell's own description number(s) in
  -- place — no separate "from skill level" line. v3 curve (SkillCurve, C++):
  --   scaled = round((shown + flat) * mult)   direct hits; DoT totals get mult only.
  if lvl > 1 and DMG[id] then
    local pctMult = 1 + SL_SPIKE_PER_10 * math.floor(lvl / 10)
    local flat = SL_FLAT_PER_LEVEL * (lvl - 1)
    for i = 1, tt:NumLines() do
      local fs = _G[ttName .. "TextLeft" .. i]
      local txt = fs and fs:GetText()
      if txt and txt:find("damage") and txt:find("%d") then
        local isDoT = txt:find("over %d") ~= nil          -- "N damage over Y sec" -> % only, no flat
        local function full(n) local v = tonumber(n); if not v then return n end
          return tostring(math.floor((v + (isDoT and 0 or flat)) * pctMult + 0.5)) end
        local newtxt, c = txt, 0
        -- range "A to B [school] damage"
        newtxt, c = newtxt:gsub("(%d+)(%s+to%s+)(%d+)([%a%s]-damage)",
          function(a, m, b, t) return full(a) .. m .. full(b) .. t end)
        -- single "N [school] damage" hit total (only if no range matched)
        if c == 0 then
          newtxt = newtxt:gsub("(%d+)([%a%s]-damage)", function(n, t) return full(n) .. t end)
        end
        -- weapon modifier "damage by N" (Heroic Strike, Raptor Strike): % + flat.
        -- The flat floor lands on the WHOLE hit, and this modifier is the only number
        -- shown — so "weapon + shown" only matches the real hit if the flat is folded
        -- in here (leaving it out made low-level scaling invisible: 11*1.02 -> 11).
        newtxt = newtxt:gsub("(damage by )(%d+)", function(p, n) return p .. full(n) end)
        if newtxt ~= txt then fs:SetText(newtxt) end
      end
    end
  end

  -- v3: the milestone "Skill Upgrades" block is RETIRED — mechanics come from gear
  -- affixes now (shown on item tooltips via SkillLevelUI_Affix.lua). The spell
  -- tooltip shows only the level, the baked-in scaled numbers, and the XP bar.
  if lvl >= 10 then
    tt:AddLine("|cff40d000+" .. (10 * math.floor(lvl / 10)) .. "% from level spikes|r", 0.25, 0.82, 0.0)
  end

  if xpnext > 0 then
    tt:AddLine(" ")   -- reserve a row for the bar
    local lineFS = _G[ttName .. "TextLeft" .. tt:NumLines()]
    xpbar:ClearAllPoints()
    if lineFS then
      xpbar:SetPoint("LEFT",  lineFS, "LEFT",  0, 0)
      xpbar:SetPoint("RIGHT", tt,     "RIGHT", -10, 0)
    else
      xpbar:SetPoint("BOTTOMLEFT",  tt, "BOTTOMLEFT",  10, 10)
      xpbar:SetPoint("BOTTOMRIGHT", tt, "BOTTOMRIGHT", -10, 10)
    end
    xpbar:SetFrameLevel(tt:GetFrameLevel() + 1)
    xpbar:SetValue(math.max(0, math.min(1, xp / xpnext)))
    xptext:SetText(xp .. " / " .. xpnext .. " xp")
    xpbar:Show()
  else
    tt:AddLine("Use it on kills to level it up.", 0.6, 0.6, 0.6)
  end
  tt:Show()   -- grow the tooltip to include the reserved row (harmless if async)
end
-- REVERTED TO VANILLA (2026-07-17): spell tooltips render natively. The
-- augmentSpellTooltip rewrite above (Rank -> "Skill Level N", baked-in damage
-- scaling, "% from level spikes", and the XP bar) is left defined but NO LONGER
-- hooked, so it never fires. The talent-overload tooltip (GameTooltip.SetTalent)
-- and the item-affix tooltips (SkillLevelUI_Affix.lua) are separate hooks, kept.
-- GameTooltip:HookScript("OnTooltipSetSpell", augmentSpellTooltip)

--================================= panel ===================================--
local panel
local function buildPanel()
  panel = CreateFrame("Frame", "SkillLevelUIPanel", UIParent)
  panel:SetWidth(250)
  panel:SetHeight(320)
  panel:SetPoint("CENTER")
  panel:SetBackdrop({
    bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  panel:SetBackdropColor(0, 0, 0, 0.85)
  panel:EnableMouse(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving)
  panel:SetScript("OnDragStop", panel.StopMovingOrSizing)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -10)
  title:SetText("Skill Levels")

  local txt = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  txt:SetPoint("TOPLEFT", 16, -38)
  txt:SetJustifyH("LEFT")
  txt:SetJustifyV("TOP")
  panel.txt = txt

  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  panel:Hide()
end

panelRefresh = function()
  if not panel then return end
  local lines = {}
  for _, id in ipairs(ORDER) do
    local st = S[id]
    local lvl = st and st.level or 1
    local bonus = st and st.bonus or 0
    local xp = st and st.xp or 0
    local xpnext = st and st.xpnext or 0
    lines[#lines + 1] = string.format("%s:  |cff33ff99L%d|r (+%d%%)  |cff888888%d/%d|r",
      SKILL_NAME[id], lvl, bonus, xp, xpnext)
  end
  panel.txt:SetText(table.concat(lines, "\n"))
end

--============================ events / slash ===============================--
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, message = ...
    if prefix == PREFIX then onAddonMessage(message) end
  elseif event == "ADDON_LOADED" then
    local name = ...
    if name == "SkillLevelUI" then
      SkillLevelUIDB = SkillLevelUIDB or {}
      S = SkillLevelUIDB                 -- persist skill cache across /reload + sessions
      SkillLevelUIOL = SkillLevelUIOL or {}
      OL = SkillLevelUIOL                -- persist talent-overload counts (survives /reload;
                                         -- the server also re-pushes the authoritative counts on login)
      buildPanel()
      panelRefresh()
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SkillLevelUI|r loaded. |cffffff00/skillui|r to toggle the panel. If it looks empty, type |cffffff00.skillsync|r in chat.")
    end
  end
end)

SLASH_SKILLUI1 = "/skillui"
SlashCmdList["SKILLUI"] = function(msg)
  if not panel then return end
  if panel:IsShown() then
    panel:Hide()
  else
    panelRefresh()
    panel:Show()
  end
end

--===================== talent overload (invest past max rank) ==============--
-- Invest talent points PAST a talent's max rank in the normal tree. The server
-- (mod-skilllevel) does the work + validation via the ".stalent <talentId>"
-- command; it pushes back each talent's overload count as "OL|id:n,id:n,...",
-- which we overlay on the tree. Left-click a MAXED talent to overload it, or use
-- /ol <name>. (The server checks free points and replies, so the addon stays thin.)
-- (OL and refreshTalentOverlays are forward-declared near the top.)

local function talentIdFromLink(tab, index)
  local ok, link = pcall(GetTalentLink, tab, index)
  if not ok or not link then return nil end
  return tonumber(link:match("talent:(%d+)"))
end

local function investOverload(tab, index)
  local ok, name, _, _, _, rank, maxRank = pcall(GetTalentInfo, tab, index)
  if not ok or not name or not maxRank or maxRank == 0 then return end
  if rank < maxRank then return end   -- not maxed: let Blizzard handle the normal learn
  local id = talentIdFromLink(tab, index)
  if not id or not OVERLOADABLE[id] then return end   -- opt-in: only designated talents overload
  local avail = 0
  pcall(function() avail = GetUnspentTalentPoints() or 0 end)
  if avail <= 0 then return end       -- out of points: the server rejects it, so don't run the display ahead
  if id then
    SendChatMessage(".stalent " .. id, "SAY")     -- server spends 1 point + applies the real effect
    OL[id] = (OL[id] or 0) + 1                     -- optimistic bump so the number climbs instantly (server persists it)
    if refreshTalentOverlays then refreshTalentOverlays() end
    -- live-refresh the tooltip if it's currently showing this talent (no need to re-hover)
    if GameTooltip:IsShown() then pcall(GameTooltip.SetTalent, GameTooltip, tab, index) end
  end
end

local function currentTalentTab()
  local ok, t = pcall(function() return PanelTemplates_GetSelectedTab(PlayerTalentFrame) end)
  return (ok and t) or 1
end

-- Find the "<Tree> Talents: N" spent-points fontstring by scanning the frame's
-- regions (robust — no hard-coded Blizzard name). Excludes the "Unspent Talents: N" one.
local function findSpentFS()
  if not PlayerTalentFrame then return nil end
  local scan = { PlayerTalentFrame }
  for _, c in ipairs({ PlayerTalentFrame:GetChildren() }) do scan[#scan + 1] = c end
  for _, f in ipairs(scan) do
    if f.GetRegions then
      for _, r in ipairs({ f:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString" then
          local t = r:GetText()
          if t and t:find("Talents:") and not t:find("Unspent") then return r end
        end
      end
    end
  end
  return nil
end

-- overlay the overload count on each talent button + hook clicks
local olHooked = {}
refreshTalentOverlays = function()
  if not PlayerTalentFrame or not PlayerTalentFrame:IsShown() then return end
  local tab = currentTalentTab()
  for i = 1, 40 do
    local btn = _G["PlayerTalentFrameTalent" .. i]
    if btn then
      -- retire the old "+N" badge if a previous version created one
      if btn.slOL then btn.slOL:SetText("") end
      if btn:IsShown() then
        -- FIX: the talent index is the BUTTON NUMBER (i), not btn:GetID() (which is
        -- often 0 on these buttons — that was why the number never updated and clicks did nothing).
        local ok, _, _, _, _, rank, maxRank = pcall(GetTalentInfo, tab, i)
        local id = talentIdFromLink(tab, i)
        local ov = (id and OL[id]) or 0
        if ov > 0 then
          -- rewrite the talent's native rank number to native + overload (the climbing total)
          local total = ((ok and rank) or 0) + ov
          local rankFS = _G["PlayerTalentFrameTalent" .. i .. "Rank"]
          if rankFS then rankFS:SetText(total); rankFS:Show() end
          local rborder = _G["PlayerTalentFrameTalent" .. i .. "RankBorder"]
          if rborder then rborder:Show() end
        end
        if btn.slNum then btn.slNum:Hide() end   -- retire the old redundant green overlay number
        -- #3: for OVERLOADABLE talents at/over native cap, keep the "spendable" GREEN look —
        -- Blizzard turns BOTH the border AND the rank number gold at max; force both back to
        -- green since these ranks are infinite. Ability/normal talents keep the vanilla gold.
        if OVERLOADABLE[id] and ok and rank and maxRank and maxRank > 0 and rank >= maxRank then
          local slot = _G["PlayerTalentFrameTalent" .. i .. "Slot"]
          if slot and slot.SetVertexColor then slot:SetVertexColor(0.1, 1.0, 0.1) end
          local rankFS = _G["PlayerTalentFrameTalent" .. i .. "Rank"]
          if rankFS and rankFS.SetTextColor then rankFS:SetTextColor(0.1, 1.0, 0.1) end
        end
      end
      if not olHooked[btn] then
        -- capture the loop index i (reliable) instead of self:GetID()
        btn:HookScript("OnClick", function() investOverload(currentTalentTab(), i) end)
        olHooked[btn] = true
      end
    end
  end
  -- fold the overload into the visible "<Tree> Talents: N" spent counter for this tab
  local tabOv = 0
  for ti = 1, (GetNumTalents and GetNumTalents(tab) or 31) do
    local tid = talentIdFromLink(tab, ti)
    if tid and OL[tid] then tabOv = tabOv + OL[tid] end
  end
  if tabOv > 0 then
    -- set the counter to the ABSOLUTE total (native spent + overload); never add to the
    -- current text, or repeated refreshes compound it into a runaway number.
    local _, _, nativeSpent = GetTalentTabInfo(tab)
    local total = (nativeSpent or 0) + tabOv
    local fs = findSpentFS()
    if fs then
      local t = fs:GetText()
      if t then fs:SetText((t:gsub("%d+", tostring(total), 1))) end
    end
  end
end

-- hook Blizzard's talent refresh once the talent UI is loaded. The update function's
-- name varies (TalentFrame_Update / PlayerTalentFrame_Update on 3.3.5), so hook whichever
-- exists AND the frame's OnShow — otherwise refreshTalentOverlays (which also ATTACHES the
-- click hooks) never runs until /olx forces it, so clicking does nothing until then.
local function tryHookTalentUI()
  if not _G.SkillLevelUI_TalentHooked then
    local hooked = false
    for _, fn in ipairs({ "TalentFrame_Update", "PlayerTalentFrame_Update", "TalentFrame_UpdateTalents" }) do
      if type(_G[fn]) == "function" then
        hooksecurefunc(fn, function() if refreshTalentOverlays then refreshTalentOverlays() end end)
        hooked = true
      end
    end
    if hooked then _G.SkillLevelUI_TalentHooked = true end
  end
  if PlayerTalentFrame and not PlayerTalentFrame.slShowHooked then
    PlayerTalentFrame:HookScript("OnShow", function() if refreshTalentOverlays then refreshTalentOverlays() end end)
    PlayerTalentFrame.slShowHooked = true
  end
end

-- Rewrite the talent TOOLTIP's "Rank X/Y" line to the overloaded total, so hovering
-- an overloaded talent shows e.g. "Rank 50" instead of the native "Rank 5/5".
if type(GameTooltip.SetTalent) == "function" and not _G.SkillLevelUI_TalentTipHooked then
  _G.SkillLevelUI_TalentTipHooked = true
  hooksecurefunc(GameTooltip, "SetTalent", function(self, tab, index)
    if not tab or not index then return end
    local ok, _, _, _, _, rank = pcall(GetTalentInfo, tab, index)
    local native = (ok and rank) or 0
    local id = talentIdFromLink(tab, index)
    local ov = (id and OL[id]) or 0
    local total = native + ov
    local didRank, didDesc, didChance = false, false, false
    for i = 1, self:NumLines() do
      local fs = _G["GameTooltipTextLeft" .. i]
      local txt = fs and fs:GetText()
      if txt then
        -- Grow effect values to match EXACTLY what the server applies (universal mechanism):
        --   grown = base * (1 + overload * OVERLOAD_GROWTH)   -- GROWTH must match TalentUncap.cpp (0.01)
        local GROWTH = 0.01
        local function grow(num) return tostring(math.floor(tonumber(num) * (1 + ov * GROWTH) + 0.5)) end
        if not didRank and OVERLOADABLE[id] and txt:find("Rank%s") then
          -- "Rank X/Y" -> "Rank <total>" (drop the /max) for OVERLOADABLE talents only;
          -- green when overloaded. Non-overloadable talents keep the vanilla "X/Y".
          if ov > 0 then fs:SetText("|cff40d000Rank " .. total .. "|r")
          else fs:SetText("Rank " .. total) end
          didRank = true
        elseif ov > 0 and txt:find("%d") then
          -- A PROC-CHANCE line ("...X% chance to...") grows too — the server scales proc chance in
          -- Aura::CalcProcChance, and it may climb PAST 100% (always procs). Handle it on its OWN
          -- line, independent of the magnitude line below, so order doesn't matter.
          if not didChance and txt:lower():find("chance") then
            local newtxt, n = txt:gsub("(%d+)%%", function(num) return grow(num) .. "%" end, 1)
            if n > 0 then fs:SetText(newtxt); didChance = true end
          elseif not didDesc then
            -- Magnitude: first "N%" (crit/damage) OR flat "by N" (energy cost, etc).
            local newtxt, n = txt:gsub("(%d+)%%", function(num) return grow(num) .. "%" end, 1)
            if n == 0 then newtxt, n = txt:gsub("by (%d+)", function(num) return "by " .. grow(num) end, 1) end
            if n > 0 then fs:SetText(newtxt); didDesc = true end
          end
        end
      end
    end
    self:Show()
  end)
end

SLASH_OVERLOAD1 = "/ol"
SlashCmdList["OVERLOAD"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff40d000[Overload]|r Usage: /ol <talent name> — invests 1 point past max rank into a maxed talent.")
    return
  end
  for tab = 1, (GetNumTalentTabs and GetNumTalentTabs() or 3) do
    for i = 1, (GetNumTalents and GetNumTalents(tab) or 31) do
      local ok, name = pcall(GetTalentInfo, tab, i)
      if ok and name and name:lower():find(msg, 1, true) then
        investOverload(tab, i); return
      end
    end
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Overload]|r No talent matching '" .. msg .. "'.")
end

-- Concept-test trigger: bulk-overload Lethal Shots (talent 1344) past its cap and
-- show the climbing rank number. Reliable (a slash command, not the flaky button
-- click). Usage: /olx  (adds 1) or /olx 50  (adds 50). /olx reset clears it.
SLASH_OLX1 = "/olx"
SlashCmdList["OLX"] = function(msg)
  local id = 1344   -- Lethal Shots
  msg = (msg or ""):lower():gsub("%s+", "")
  if msg == "reset" then
    for k in pairs(OL) do OL[k] = nil end   -- .stalent 0 clears ALL overloads server-side
    SendChatMessage(".stalent 0", "SAY")
    if refreshTalentOverlays then refreshTalentOverlays() end
    DEFAULT_CHAT_FRAME:AddMessage("|cff40d000[Overload]|r All overloads reset.")
    return
  end
  local n = tonumber(msg:match("%d+")) or 1
  -- overload costs 1 talent point per rank — don't ask for more than you have banked
  local avail = 0
  pcall(function() avail = GetUnspentTalentPoints() or 0 end)
  if avail <= 0 then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Overload]|r No unspent talent points. (Level up / Paragon to earn more.)")
    return
  end
  if n > avail then n = avail end
  OL[id] = (OL[id] or 0) + n
  SendChatMessage(".stalent " .. id .. " " .. n, "SAY")   -- server spends the points + applies the real crit
  if refreshTalentOverlays then refreshTalentOverlays() end
end

-- install the tree hooks once Blizzard_TalentUI is loaded / on world enter
local olEv = CreateFrame("Frame")
olEv:RegisterEvent("ADDON_LOADED")
olEv:RegisterEvent("PLAYER_ENTERING_WORLD")
olEv:SetScript("OnEvent", function(self, event, name)
  tryHookTalentUI()
  if refreshTalentOverlays then refreshTalentOverlays() end
end)

--===================== unlock the talent window (N) at level 1 ==============--
-- Blizzard gates the talent window to level 10 in TWO places: the disabled
-- micro-button AND a hard `if UnitLevel < 10 then return end` at the top of
-- ToggleTalentFrame() (which both the N key binding TOGGLETALENTS and the button
-- route through). So we must (a) keep the button enabled AND (b) wrap
-- ToggleTalentFrame to bypass the gate below 10, driving the load-on-demand
-- PlayerTalentFrame directly. At 10+ we defer to Blizzard's original behaviour.
-- (The trees render even with 0 points; our custom talents use .talent in chat.)
-- REVERTED TO VANILLA (2026-07-17): the ToggleTalentFrame override that opened
-- the talent window below level 10 was removed. Native gating is restored (the
-- frame is locked until level 10). The talent-OVERLOAD click handler + rank
-- display are installed elsewhere (refreshTalentOverlays / tryHookTalentUI /
-- olEv) and are unaffected by this removal.

-- REVERTED TO VANILLA (2026-07-17): the UpdateMicroButtons hook that force-enabled
-- the Talent micro-button below level 10 was removed, so the button is natively
-- disabled until level 10.
