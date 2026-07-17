--[[==========================================================================
  EmpowerRadar.lua — "[Empowered xN]" on empowered overworld creatures, shown on:
    * the UNIT TOOLTIP        (mouseover / target — exact, keyed by GUID)
    * the TARGET/FOCUS FRAME  (exact, keyed by GUID)
    * the NAMEPLATE over the head (BEST-EFFORT, keyed by NAME — see note)

  mod-empower stores each creature's tier (2..10; 1 = normal) in server-side
  CustomData. We ask via the EmpowerRadar RPC (prefix "EMPWR"): send "Q:<guid>",
  receive "A|<guid>|<tier>". Answers cache by GUID (exact) with a short TTL.

  NAMEPLATE NOTE: stock 3.3.5 exposes no nameplate->unit/GUID mapping, only the
  name FontString. So nameplate tags are matched by NAME via a secondary cache
  (populated when you mouseover/target an empowered mob). Two mobs with the same
  name share the last-seen tier there — the tooltip/target frame are exact.
============================================================================]]--

local PREFIX  = "EMPWR"
local TTL     = 45          -- seconds an answer stays fresh
local PURPLE  = "|cffa335ee"

local byGuid  = {}          -- [guid] = { tier, t }   (exact)
local byName  = {}          -- [name] = { tier, t }   (approximate, for nameplates)
local qName   = {}          -- [guid] = name recorded at query time (applied on reply)
local shownGUID

local function rpc(guid) SendAddonMessage(PREFIX, "Q:" .. guid, "WHISPER", UnitName("player")) end

local function tierByGuid(guid)
  local h = guid and byGuid[guid]
  if h and (GetTime() - h.t) < TTL then return h.tier end
end
local function tierByName(name)
  local h = name and byName[name]
  if h and (GetTime() - h.t) < TTL then return h.tier end
end

-- Query a unit's tier if we don't already have a fresh answer.
local function query(unit)
  if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return end
  local guid = UnitGUID(unit)
  if guid and not tierByGuid(guid) then
    qName[guid] = UnitName(unit)
    rpc(guid)
  end
end

-------------------------------------------------------------------- unit tooltip
local function tipLine(tt, tier)
  if not tier or tier < 2 then return end
  local text = "[Empowered x" .. tier .. "]"
  local nm = tt:GetName() or "GameTooltip"
  for i = 1, tt:NumLines() do
    local fs = _G[nm .. "TextLeft" .. i]
    if fs and fs:GetText() == text then return end
  end
  tt:AddLine(text, 0.64, 0.21, 0.93)
  tt:Show()
end

GameTooltip:HookScript("OnTooltipSetUnit", function(self)
  local _, unit = self:GetUnit()
  unit = unit or "mouseover"
  if not UnitExists(unit) then return end
  shownGUID = UnitGUID(unit)
  local t = tierByGuid(shownGUID)
  if t then tipLine(self, t) else query(unit) end
end)
GameTooltip:HookScript("OnHide", function() shownGUID = nil end)

-------------------------------------------------------------------- target / focus frame
-- TargetFrame_Update resets the name to the clean unit name right before this
-- hook runs, so we can just append the tag once (no accumulation across updates).
local function tagUnitFrame(self)
  if not self or not self.unit or not self.name then return end
  local t = tierByGuid(UnitGUID(self.unit))
  if t and t >= 2 then
    self.name:SetText((self.name:GetText() or "") .. " " .. PURPLE .. "[x" .. t .. "]|r")
  elseif UnitExists(self.unit) and not UnitIsPlayer(self.unit) then
    query(self.unit)
  end
end
if type(TargetFrame_Update) == "function" then hooksecurefunc("TargetFrame_Update", tagUnitFrame) end

-------------------------------------------------------------------- nameplates (best effort)
local function nameplateNameFS(f)
  local rs = { f:GetRegions() }
  for _, r in ipairs(rs) do
    if r.GetObjectType and r:GetObjectType() == "FontString" then return r end
  end
end

-- Cache the plate-ness (and name FontString) per frame; WorldFrame children are pooled.
local function isNameplate(f)
  if f.emChecked then return f.emIsPlate end
  f.emChecked = true
  f.emIsPlate = false
  if f:GetName() then return false end
  local hasBar = false
  for _, c in ipairs({ f:GetChildren() }) do
    if c.GetObjectType and c:GetObjectType() == "StatusBar" then hasBar = true break end
  end
  if not hasBar then return false end
  f.emNameFS = nameplateNameFS(f)
  f.emIsPlate = (f.emNameFS ~= nil)
  return f.emIsPlate
end

local function tagPlate(f)
  local nameFS = f.emNameFS
  if not nameFS then return end
  if not f.emTag then
    f.emTag = f:CreateFontString(nil, "OVERLAY")
    f.emTag:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")   -- black outline = readable on any background
    f.emTag:SetTextColor(0.64, 0.21, 0.93)                   -- epic purple
    f.emTag:SetShadowColor(0, 0, 0, 1)
    f.emTag:SetShadowOffset(1, -1)
    f.emTag:SetPoint("BOTTOM", nameFS, "TOP", 0, 2)
  end
  local tier = tierByName(nameFS:GetText())
  f.emTag:SetText((tier and tier >= 2) and ("Empowered [x" .. tier .. "]") or "")
end

local scan, acc = CreateFrame("Frame"), 0
scan:SetScript("OnUpdate", function(_, e)
  acc = acc + e
  if acc < 0.2 then return end
  acc = 0
  for _, f in ipairs({ WorldFrame:GetChildren() }) do
    if f:IsShown() and isNameplate(f) then tagPlate(f) end
  end
end)

-------------------------------------------------------------------- RPC replies / events
local rx = CreateFrame("Frame")
rx:RegisterEvent("CHAT_MSG_ADDON")
rx:RegisterEvent("PLAYER_TARGET_CHANGED")
rx:RegisterEvent("PLAYER_ENTERING_WORLD")
rx:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 ~= PREFIX or not a2 then return end
    local guid, tierStr = a2:match("^A|([^|]+)|(.*)$")
    if not guid then return end
    local tier, now = tonumber(tierStr) or 0, GetTime()
    byGuid[guid] = { tier = tier, t = now }
    local nm = qName[guid]; qName[guid] = nil
    if nm and tier >= 2 then byName[nm] = { tier = tier, t = now } end
    if guid == shownGUID and GameTooltip:IsShown() then tipLine(GameTooltip, tier) end
    if TargetFrame and UnitGUID("target") == guid then tagUnitFrame(TargetFrame) end
  elseif event == "PLAYER_TARGET_CHANGED" then
    query("target")
  else
    byGuid, byName = {}, {}          -- entered world / changed zone
  end
end)
