--[[==========================================================================
  EmpowerRadar.lua — "Empowered [xN]" on the UNIT TOOLTIP ONLY (mouseover/target).

  Per Josh 2026-07-17: tooltip only. No nameplate text, no target/focus-frame text,
  no glow. mod-empower stores each creature's tier server-side; we ask over an addon
  whisper (prefix "EMPWR"): send "Q:<guid>", receive "A|<guid>|<tier>", cache by GUID,
  and add a purple line to the unit tooltip. Keyed by the real UnitGUID, so it's exact.
============================================================================]]--

local PREFIX = "EMPWR"
local TTL    = 45

local byGuid = {}          -- [guid] = { tier, t }
local shownGUID

local function rpc(guid) SendAddonMessage(PREFIX, "Q:" .. guid, "WHISPER", UnitName("player")) end

local function tierByGuid(guid)
  local h = guid and byGuid[guid]
  if h and (GetTime() - h.t) < TTL then return h.tier end
end

local function query(unit)
  if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return end
  local guid = UnitGUID(unit)
  if guid and not tierByGuid(guid) then rpc(guid) end
  return guid
end

-------------------------------------------------------------------- unit tooltip
local function tipLine(tt, tier)
  if not tier or tier < 2 then return end
  local text = "Empowered [x" .. tier .. "]"
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

-------------------------------------------------------------------- RPC replies
local rx = CreateFrame("Frame")
rx:RegisterEvent("CHAT_MSG_ADDON")
rx:RegisterEvent("PLAYER_ENTERING_WORLD")
rx:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 ~= PREFIX or not a2 then return end
    local guid, tierStr = a2:match("^A|([^|]+)|(.*)$")
    if not guid then return end
    byGuid[guid] = { tier = tonumber(tierStr) or 0, t = GetTime() }
    if guid == shownGUID and GameTooltip:IsShown() then tipLine(GameTooltip, byGuid[guid].tier) end
  else
    byGuid = {}                                   -- entered world / changed zone
  end
end)
