--[[==========================================================================
  SkillLevelUI_Auras.lua — AURA tooltip rewriting (enemy DoT debuffs + own buffs).

  The client draws aura (buff/debuff) tooltips from its static Spell.dbc, so a
  leveled DoT still reads its rank-1 "X damage every Y sec" and a leveled practice
  buff still reads its rank-1 magnitude. SkillLevelUI.lua already rewrites the
  ABILITY (spellbook / action-bar) tooltip via OnTooltipSetSpell; this file adds
  the missing surface: the aura tooltips shown when you hover a buff/debuff icon.

  STANDALONE BY DESIGN. Reads only the GLOBAL generated tables
  (SkillLevelUI_GenNames / GenSkills / GenDamage from SkillLevelUI_Data.lua) and
  keeps its OWN copy of skill levels parsed off the SKILLUI addon channel — so it
  never touches SkillLevelUI.lua (which is under concurrent edit). Load order in
  the .toc: Data -> main -> Auras.

  Scope of the rewrite:
    * Enemy DoT debuff (a damage-category tracked skill, cast by you/your pet):
      scale the per-tick damage number in place (% curve, no flat floor — matches
      DamageScaling.cpp's DoT path), then append the DoT upgrades that changed the
      debuff (faster ticks / +ticks / +max stacks) + a "Skill Level N" marker.
    * Own buff (a practice/heal tracked skill you cast on yourself): append the
      M-BUFF magnitude (potency / duration) — the DBC sentence structure varies too
      much to rewrite in place reliably, so we annotate instead.

  Pure server-side amplifiers with no client aura (VULN, RAMP, ENRAGE, …) have
  nothing to hover — they show on the caster's ability tooltip (SkillLevelUI.lua).
============================================================================]]--

local GenNames  = SkillLevelUI_GenNames  or {}
local GenSkills = SkillLevelUI_GenSkills or {}
local GenDamage = SkillLevelUI_GenDamage or {}

-- v3 curve — MUST match SkillCurve in mod-skilllevel (DoT ticks: multiplier only).
local SL_SPIKE_PER_10 = 0.10

-- v3: the milestone ladder is retired — no per-skill upgrade magnitudes to
-- resolve client-side (mechanics live on gear affixes now).
local function resolve(id, lvl)
  return {}
end

-- Own skill levels, parsed off the SKILLUI addon channel. The main file keeps its
-- own copy (local); we keep ours so this file stands alone. Format (core/practice/heal):
--   "SYNC|id:level:bonus:xp:xpnext,id:level:...,..."  and  "LU|id:level:bonus:xp:xpnext"
local LEVELS = {}
local rx = CreateFrame("Frame")
rx:RegisterEvent("CHAT_MSG_ADDON")
rx:SetScript("OnEvent", function(_, _, prefix, msg)
  if prefix ~= "SKILLUI" or not msg then return end
  local body = msg:match("^SYNC|(.+)$") or msg:match("^LU|(.+)$")
  if not body then return end
  for pair in body:gmatch("[^,]+") do
    local id, lvl = pair:match("^(%d+):(%d+):")
    if id then LEVELS[tonumber(id)] = tonumber(lvl) end
  end
end)

-- Scale every "N [school] damage" (and "A to B damage") occurrence by the DoT curve
-- (v3: spike multiplier only — no flat on ticks).
local function scaleDamageText(txt, lvl)
  if lvl <= 1 then return txt end
  local mult = 1 + SL_SPIKE_PER_10 * math.floor(lvl / 10)
  local function s(n) local v = tonumber(n); if not v then return n end return tostring(math.floor(v * mult + 0.5)) end
  local out, c = txt, 0
  out, c = out:gsub("(%d+)(%s+to%s+)(%d+)([%a%s]-damage)", function(a, m, b, t) return s(a) .. m .. s(b) .. t end)
  if c == 0 then
    out = out:gsub("(%d+)([%a%s]-damage)", function(n, t) return s(n) .. t end)
  end
  return out
end

-- Guard against double-annotation: SetUnitBuff/Debuff may route through SetUnitAura
-- (both our hooks would fire). If we already stamped this draw, skip.
local function alreadyDone(tt, ttName)
  for i = 1, tt:NumLines() do
    local fs = _G[ttName .. "TextLeft" .. i]
    local t = fs and fs:GetText()
    if t and t:find("Skill Level") then return true end
  end
  return false
end

local function augment(tt, name, unitCaster)
  if not name then return end
  local id = GenNames[name]
  if not id then return end                         -- not a tracked skill
  local lvl = LEVELS[id] or 1
  if lvl <= 1 then return end                       -- nothing to show at rank-1
  -- Only annotate auras WE (or our pet) applied — we only know our own levels.
  if unitCaster and unitCaster ~= "player" and unitCaster ~= "pet" then return end

  local ttName = tt:GetName() or "GameTooltip"
  if alreadyDone(tt, ttName) then return end
  local acc = resolve(id, lvl) or {}

  if GenDamage[id] then
    -- Enemy DoT debuff: scale the per-tick damage number(s) in place.
    for i = 1, tt:NumLines() do
      local fs = _G[ttName .. "TextLeft" .. i]
      local txt = fs and fs:GetText()
      if txt and txt:find("damage") and txt:find("%d") then
        local nt = scaleDamageText(txt, lvl)
        if nt ~= txt then fs:SetText(nt) end
      end
    end
    tt:AddLine("|cff40d000Skill Level " .. lvl .. "|r", 0.25, 0.82, 0.0)
    if acc.FASTER and acc.FASTER > 0 then
      tt:AddLine("|cff40d000Faster ticks  -" .. string.format("%.1f", acc.FASTER / 1000) .. "s|r", 0.25, 0.82, 0.0, true)
    end
    if acc.TICK and acc.TICK > 0 then
      tt:AddLine("|cff40d000Longer  +" .. math.floor(acc.TICK) .. " tick(s)|r", 0.25, 0.82, 0.0, true)
    end
    if acc.STACK and acc.STACK > 0 then
      tt:AddLine("|cff40d000Max stacks  +" .. math.floor(acc.STACK) .. "|r", 0.25, 0.82, 0.0, true)
    end
    tt:Show()
  else
    -- Own buff: annotate the M-BUFF magnitude (potency / duration). Can't reliably
    -- rewrite the varied DBC sentence, so we append instead.
    local amt = (acc.POTENCY or 0) + (acc.ABSORB or 0) + (acc.REGEN or 0)
              + (acc.MITIGATION or 0) + (acc.SPEED or 0) + (acc.PRIMARY or 0)
    local dur = acc.DURATION or 0
    if amt > 0 or dur > 0 then
      tt:AddLine("|cff40d000Skill Level " .. lvl .. "|r", 0.25, 0.82, 0.0)
      if amt > 0 then tt:AddLine("|cff40d000Potency  +" .. math.floor(amt * 100 + 0.5) .. "%|r", 0.25, 0.82, 0.0, true) end
      if dur > 0 then tt:AddLine("|cff40d000Duration  +" .. math.floor(dur * 100 + 0.5) .. "%|r", 0.25, 0.82, 0.0, true) end
      tt:Show()
    end
  end
end

-- The client fills the aura tooltip in the original Set*; our post-hook reads the
-- aura back and annotates. (3.3.5a UnitAura/UnitBuff/UnitDebuff return
--   name, rank, icon, count, debuffType, duration, expirationTime, unitCaster, ...)
hooksecurefunc(GameTooltip, "SetUnitAura", function(self, unit, index, filter)
  local name, _, _, _, _, _, _, unitCaster = UnitAura(unit, index, filter)
  augment(self, name, unitCaster)
end)
hooksecurefunc(GameTooltip, "SetUnitBuff", function(self, unit, index)
  local name, _, _, _, _, _, _, unitCaster = UnitBuff(unit, index)
  augment(self, name, unitCaster)
end)
hooksecurefunc(GameTooltip, "SetUnitDebuff", function(self, unit, index)
  local name, _, _, _, _, _, _, unitCaster = UnitDebuff(unit, index)
  augment(self, name, unitCaster)
end)
