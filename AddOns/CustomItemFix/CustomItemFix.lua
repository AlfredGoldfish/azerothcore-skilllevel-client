--[[============================================================================
  CustomItemFix -- resolve the red "?" icon on custom item entries.

  WHY: the 3.3.5 client draws an item's icon from the client-side Item.dbc, keyed
  by item ENTRY. Custom entries (e.g. the empowered xN gear clones, entries
  120,000-654,806) aren't in Item.dbc, so the client falls back to the red "?"
  -- even though GetItemInfo() CAN resolve the real icon from the item's queried
  displayid. This addon swaps the "?" for the GetItemInfo texture. Generic:
  works for ANY custom item, no per-item config, no DBC / MPQ patch.

  Covers bags (default + addons that call the global, e.g. Bagnon), equipped
  slots (paperdoll / inspect), and the loot window (phase-3 empowered drops).

  Based on AzerothCore's CustomItemFix (Ethos "DIF"), extended past bag slots.
  These info-getters are NOT protected, so replacing them is allowed.
============================================================================]]--

local QMARK = "questionmark"

-- Is this texture the fallback "?" (Interface\Icons\INV_Misc_QuestionMark)?
local function isQ(tex)
  return tex ~= nil and string.find(string.lower(tex), QMARK, 1, true) ~= nil
end

-- The real icon for an item link, resolved from its queried displayid.
-- Returns nil if the item isn't cached client-side yet (rare; resolves on re-hover).
local function realTex(link)
  if not link then return nil end
  return select(10, GetItemInfo(link))   -- 10th return of GetItemInfo == texture
end

-- ---- bags: default containers + any addon calling the global (Bagnon, etc.) ----
if type(GetContainerItemInfo) == "function" then
  local _orig = GetContainerItemInfo
  function GetContainerItemInfo(bag, slot)
    -- return ALL 7 values (Bagnon reads the 7th, link) -- dropping it breaks bag addons
    local texture, itemCount, locked, quality, readable, lootable, itemLink = _orig(bag, slot)
    if isQ(texture) then
      local t = realTex(itemLink or GetContainerItemLink(bag, slot))
      if t then texture = t end
    end
    return texture, itemCount, locked, quality, readable, lootable, itemLink
  end
end

-- ---- equipped items: character paperdoll and inspect frame ----
if type(GetInventoryItemTexture) == "function" then
  local _orig = GetInventoryItemTexture
  function GetInventoryItemTexture(unit, slot)
    local texture = _orig(unit, slot)
    local link = GetInventoryItemLink(unit, slot)
    if link and (isQ(texture) or texture == nil) then
      local t = realTex(link)
      if t then return t end
    end
    return texture
  end
end

-- ---- loot window: important for phase-3 empowered drops ----
if type(GetLootSlotInfo) == "function" then
  local _orig = GetLootSlotInfo
  function GetLootSlotInfo(slot)
    local texture, item, quantity, quality, locked = _orig(slot)
    if isQ(texture) then
      local t = realTex(GetLootSlotLink(slot))
      if t then texture = t end
    end
    return texture, item, quantity, quality, locked
  end
end

if DEFAULT_CHAT_FRAME then
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88CustomItemFix|r loaded -- custom item icons (bags / equipped / loot).")
end
