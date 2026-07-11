--[[==========================================================================
  SkillLevelUI_Affix.lua — item MECHANIC AFFIX tooltip lines (v3, spec §4).

  Mechanic affixes live in a spare enchantment slot the client can't render
  natively (PROP-slot enchants aren't part of the item link). This file asks
  the server (skillaffix_rpc.lua, prefix SKILLAFX) what an item carries and
  appends the purple "Equip:" line to bag / equipped-item tooltips.

    send:    "Q:B:<bag>:<slot>"  (bag 0 = backpack)  /  "Q:E:<invSlot>"
    receive: "A|B:<bag>:<slot>|<text>"  /  "A|E:<invSlot>|<text>"  ("" = none)

  Answers are cached per position and invalidated on BAG_UPDATE / equip changes
  (cheap: the cache just clears; tooltips re-query on next hover). STANDALONE —
  touches nothing in SkillLevelUI.lua.
============================================================================]]--

local PREFIX = "SKILLAFX"

local cache = {}       -- ["B:0:3" / "E:16"] = text ("" = confirmed none)
local shownKey = nil   -- position key of the tooltip currently on screen

local function rpc(msg) SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player")) end

-- Normalize a tooltip string to bare lowercase letters/digits so we can compare
-- our text against a line the CLIENT already rendered natively (legacy markers
-- 10001-10009 ship in patch-4.MPQ, so the client draws their enchant name in
-- green — we must NOT add a second purple copy). Strips color escapes, an
-- "Equip:" prefix, and all punctuation/spacing.
local function norm(s)
  if not s then return "" end
  s = s:lower():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("^%s*equip:?%s*", "")
  return (s:gsub("[^%a%d]", ""))
end

local function addLine(tt, text)
  if not text or text == "" then return end
  local key = norm(text)
  if key == "" then return end
  local nm = tt:GetName() or "GameTooltip"
  for i = 1, tt:NumLines() do
    local fs = _G[nm .. "TextLeft" .. i]
    local t = fs and fs:GetText()
    if t and norm(t):find(key, 1, true) then return end   -- already shown (native or ours)
  end
  tt:AddLine(text, 0.64, 0.21, 0.93, true)   -- epic purple
  tt:Show()
end

local function request(tt, key, query)
  shownKey = key
  local hit = cache[key]
  if hit ~= nil then
    addLine(tt, hit)
  else
    rpc(query)
  end
end

hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
  request(self, "B:" .. bag .. ":" .. slot, "Q:B:" .. bag .. ":" .. slot)
end)
hooksecurefunc(GameTooltip, "SetInventoryItem", function(self, unit, invSlot)
  if unit ~= "player" then return end
  request(self, "E:" .. invSlot, "Q:E:" .. invSlot .. ":0")
end)
GameTooltip:HookScript("OnHide", function() shownKey = nil end)

local rx = CreateFrame("Frame")
rx:RegisterEvent("CHAT_MSG_ADDON")
rx:RegisterEvent("BAG_UPDATE")
rx:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
rx:RegisterEvent("UNIT_INVENTORY_CHANGED")
rx:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 ~= PREFIX or not a2 then return end
    local key, text = a2:match("^A|([^|]+)|(.*)$")
    if not key then return end
    cache[key] = text or ""
    if key == shownKey and GameTooltip:IsShown() then addLine(GameTooltip, text) end
  else
    -- items moved: positions shifted, answers stale — drop the cache
    cache = {}
  end
end)
