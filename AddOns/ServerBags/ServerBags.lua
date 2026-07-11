-- ServerBags: Bagnon companion for the v2 server
--   * Sell-all by quality: one-click vendor buttons (Gray/White/Green/Blue/Purple)
--   * Item lock: Alt+click an item to protect it from Sell-all (padlock overlay + tooltip)
-- Bagnon stays stock; this hooks it non-destructively. Sell logic ported from QuickBags.

local BAGS          = {0, 1, 2, 3, 4}
local QUALITY_NAMES = {[0]="Gray", [1]="White", [2]="Green", [3]="Blue", [4]="Purple"}
local SELL_TIERS    = {0, 1, 2, 3, 4}
local CONFIRM_ABOVE = 2          -- confirm before selling quality > 2 (Blue, Purple)

----------------------------------------------------------------- lock storage
local function EnsureDB()
    if type(ServerBagsDB) ~= "table" then ServerBagsDB = {} end
    if type(ServerBagsDB.locked) ~= "table" then ServerBagsDB.locked = {} end
    if ServerBagsDB.quiet == nil then ServerBagsDB.quiet = true end   -- ambient chat off by default
end

-- ambient/automatic chat output (the padlock "L" is the real feedback); off by default.
-- Explicit /sbags command replies bypass this. Toggle with /sbags quiet.
local function Notify(msg)
    if ServerBagsDB and ServerBagsDB.quiet == false then   -- only when explicitly enabled
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

local function ItemIDFromLink(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function IsLockedID(id)
    if not id then return false end
    return (ServerBagsDB and ServerBagsDB.locked and ServerBagsDB.locked[id]) and true or false
end

local function IsLockedLink(link)
    return IsLockedID(ItemIDFromLink(link))
end

-- migrate locks from the old QuickBags addon (once), so existing locks survive the switch
local function MigrateFromQuickBags()
    EnsureDB()
    if ServerBagsDB.migratedQB then return end
    ServerBagsDB.migratedQB = true
    if type(QuickBagsDB) == "table" and type(QuickBagsDB.locked) == "table" then
        local n = 0
        for id in pairs(QuickBagsDB.locked) do
            if not ServerBagsDB.locked[id] then ServerBagsDB.locked[id] = true; n = n + 1 end
        end
        if n > 0 then
            Notify("|cff33ff99ServerBags|r migrated " .. n .. " item lock(s) from QuickBags.")
        end
    end
end

----------------------------------------------------------------- lock overlay on Bagnon item buttons
local sbButtons = {}   -- set of Bagnon item buttons we've decorated

local function UpdateOverlay(b)
    local link = (b.GetItem and b:GetItem())
              or (b.GetBag and b.GetID and GetContainerItemLink(b:GetBag(), b:GetID()))
    local locked = link and IsLockedLink(link)
    if locked then
        if not b.__sbLock then
            local t = b:CreateFontString(nil, "OVERLAY")
            t:SetDrawLayer("OVERLAY", 7)                    -- above icon, border and count
            t:SetFont("Fonts\\FRIZQT__.TTF", 13, "THICKOUTLINE")
            t:SetText("L")
            t:SetTextColor(1, 0.82, 0)                      -- gold
            t:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
            b.__sbLock = t
        end
        b.__sbLock:Show()
    elseif b.__sbLock then
        b.__sbLock:Hide()
    end
end

local function RefreshAllOverlays()
    for b in pairs(sbButtons) do UpdateOverlay(b) end
end

----------------------------------------------------------------- toggle a lock
local function ToggleLockByLink(link)
    local id = ItemIDFromLink(link)
    if not id then return end
    EnsureDB()
    if ServerBagsDB.locked[id] then
        ServerBagsDB.locked[id] = nil
        Notify("|cff33ff99ServerBags|r unlocked " .. link .. ".")
    else
        ServerBagsDB.locked[id] = true
        Notify("|cff33ff99ServerBags|r locked " .. link .. " |cff888888(protected from Sell All)|r.")
    end
    RefreshAllOverlays()
end

----------------------------------------------------------------- Bagnon integration (skipped cleanly if Bagnon absent)
-- TAINT RULE (learned the hard way): never REPLACE a container button's OnClick or the
-- global ContainerFrameItemButton_OnClick. A replaced handler is addon-tainted, and
-- UseContainerItem() is protected on 3.3.5 when the use would consume/cast — every
-- right-click use then dies with "ServerBags has been blocked from an action only
-- available to the Blizzard UI". (Selling at a merchant is NOT protected, which is why
-- the Sell-all bar never tripped it.) Post-hooks keep the Blizzard handler secure.
--
-- Alt+LeftClick needs no swallowing: the template's OnClick script routes modified
-- clicks to ContainerFrameItemButton_OnModifiedClick, which does nothing for plain Alt,
-- so toggling the lock from a post-hook doesn't fight any default action.
local function HookButtonClick(b)
    if b.__sbClick then return end
    b.__sbClick = true
    b:HookScript("OnClick", function(s, button)
        if button == "LeftButton" and IsAltKeyDown()
           and not IsShiftKeyDown() and not IsControlKeyDown() then
            local link = (s.GetItem and s:GetItem())
                      or (s.GetBag and s.GetID and GetContainerItemLink(s:GetBag(), s:GetID()))
            if link then ToggleLockByLink(link) end
        end
    end)
end

local function HookBagnon()
    if not (Bagnon and Bagnon.ItemSlot) then return false end
    -- Update() is dispatched through the class metatable, so hooking it reaches every
    -- button, existing and future. Use it to (a) wrap each button's OnClick for the
    -- Alt+click lock and (b) draw/refresh the padlock overlay.
    hooksecurefunc(Bagnon.ItemSlot, "Update", function(self)
        sbButtons[self] = true
        HookButtonClick(self)
        UpdateOverlay(self)
    end)
    return true
end

-- "Locked" tooltip line: hook the tooltip itself (addon-agnostic; fires for any item)
local function InstallTooltipHook()
    GameTooltip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        if link and IsLockedLink(link) then
            self:AddLine("|cff33ff99ServerBags: Locked|r |cff888888(protected from Sell All)|r")
        end
    end)
end

-- Fallback for the no-Bagnon case: Alt+LeftClick lock on the DEFAULT bag buttons.
-- Alt+clicks route to ContainerFrameItemButton_OnModifiedClick (see taint rule above),
-- so post-hook that — never override the global. Installed ONLY when Bagnon isn't
-- hooked: Bagnon's buttons reach this same global through their template script, and
-- hooking both would toggle the lock twice per click (a net no-op).
local function InstallClickHook()
    if type(ContainerFrameItemButton_OnModifiedClick) ~= "function" then return end
    hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
        if button == "LeftButton" and IsAltKeyDown()
           and not IsShiftKeyDown() and not IsControlKeyDown() then
            local p = self.GetParent and self:GetParent()
            local bag = p and p.GetID and p:GetID()
            local link = bag and self.GetID and GetContainerItemLink(bag, self:GetID())
            if link then ToggleLockByLink(link) end
        end
    end)
end

----------------------------------------------------------------- sell by quality (ported from QuickBags)
local function IterSellable(q, fn)
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, quality, _, _, _, _, _, equipSlot, _, sellPrice = GetItemInfo(link)
                local isBag  = (equipSlot == "INVTYPE_BAG")
                local isGear = equipSlot and equipSlot ~= "" and not isBag
                -- Gray (0): sell ALL trash (junk + gear), never a bag. White+ (1-4): equipment only.
                local sellable
                if q == 0 then sellable = not isBag else sellable = isGear end
                if quality == q and sellable and sellPrice and sellPrice > 0 then
                    if not IsLockedLink(link) then
                        local _, cnt = GetContainerItemInfo(bag, slot)
                        fn(bag, slot, (cnt or 1) * sellPrice)
                    end
                end
            end
        end
    end
end

local function CountSellable(q)
    local count, value = 0, 0
    IterSellable(q, function(_, _, v) count = count + 1; value = value + v end)
    return count, value
end

local function DoSell(q)
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        Notify("|cffff5555ServerBags:|r open a vendor first.")
        return
    end
    local count, value = 0, 0
    IterSellable(q, function(bag, slot, v)
        UseContainerItem(bag, slot)      -- sells the stack at the open merchant
        count = count + 1; value = value + v
    end)
    if count > 0 then
        Notify("|cff33ff99ServerBags|r sold |cffffffff" .. count .. "|r " .. (QUALITY_NAMES[q] or "") .. " item(s) for " .. GetCoinTextureString(value) .. ".")
    else
        Notify("|cff33ff99ServerBags|r no unlocked " .. (QUALITY_NAMES[q] or "") .. " items to sell.")
    end
    if ServerBags_UpdateBar then ServerBags_UpdateBar() end
end

StaticPopupDialogs["SERVERBAGS_SELL_CONFIRM"] = {
    text = "Sell all %s items?\n%s",
    button1 = YES, button2 = NO,
    OnAccept = function() DoSell(ServerBags_pendingQ) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function SellQuality(q)
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        Notify("|cffff5555ServerBags:|r open a vendor first.")
        return
    end
    if q > CONFIRM_ABOVE then                          -- Blue / Purple: confirm first
        local count, value = CountSellable(q)
        if count == 0 then
            Notify("|cff33ff99ServerBags|r no unlocked " .. (QUALITY_NAMES[q] or "") .. " items to sell.")
            return
        end
        ServerBags_pendingQ = q
        StaticPopup_Show("SERVERBAGS_SELL_CONFIRM", QUALITY_NAMES[q], count .. " items  (" .. GetCoinTextureString(value) .. ")")
    else
        DoSell(q)
    end
end

----------------------------------------------------------------- merchant "Sell all" bar (shows at a vendor)
local bar, barButtons
local function BuildBar()
    if bar or not MerchantFrame then return end
    bar = CreateFrame("Frame", "ServerBagsSellBar", MerchantFrame)
    bar:SetWidth(96); bar:SetHeight(190)
    bar:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 6, -12)
    bar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local hdr = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOP", 0, -8)
    hdr:SetText("Sell all")

    barButtons = {}
    for i, q in ipairs(SELL_TIERS) do
        local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        b:SetWidth(80); b:SetHeight(21)
        b:SetPoint("TOP", 0, -22 - (i-1)*26)
        b:SetText(QUALITY_NAMES[q])
        local c = ITEM_QUALITY_COLORS[q]
        local fs = b:GetFontString()
        if fs and c then fs:SetTextColor(c.r, c.g, c.b) end
        b:SetScript("OnClick", function() SellQuality(q) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local count, value = CountSellable(q)
            if q == 0 then
                GameTooltip:AddLine("Sell all Gray trash")
                GameTooltip:AddLine("All poor-quality junk (gear + misc). Never a bag. Skips |cffffd100locked|r items.", 0.8, 0.8, 0.8, true)
            else
                GameTooltip:AddLine("Sell all " .. QUALITY_NAMES[q] .. " equipment")
                GameTooltip:AddLine("Gear only (armor/weapons) — never trade goods, consumables, or quest items. Skips |cffffd100locked|r items.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:AddLine(count .. " item(s)  =  " .. GetCoinTextureString(value), 1, 1, 1)
            if q > CONFIRM_ABOVE then GameTooltip:AddLine("Asks to confirm first.", 0.6, 0.6, 0.6, true) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        barButtons[i] = b
    end

    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 8)
    hint:SetText("Alt+click item = lock")
end

-- fade quality buttons that have nothing to sell (visual feedback)
function ServerBags_UpdateBar()
    if not (bar and bar:IsShown() and barButtons) then return end
    for i, q in ipairs(SELL_TIERS) do
        local count = CountSellable(q)
        if count > 0 then barButtons[i]:Enable() else barButtons[i]:Disable() end
    end
end

----------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("MERCHANT_CLOSED")
ev:RegisterEvent("BAG_UPDATE")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "ServerBags" then
            EnsureDB()
            MigrateFromQuickBags()
        end
    elseif event == "MERCHANT_SHOW" then
        BuildBar()
        if bar then bar:Show(); ServerBags_UpdateBar() end
    elseif event == "MERCHANT_CLOSED" then
        if bar then bar:Hide() end
    elseif event == "BAG_UPDATE" then
        ServerBags_UpdateBar()
    end
end)

-- install hooks now (Bagnon has already loaded via OptionalDeps if present)
InstallTooltipHook()
local hookedBagnon = HookBagnon()
if not hookedBagnon then InstallClickHook() end   -- default-bags fallback; never both

----------------------------------------------------------------- slash commands
SLASH_SERVERBAGS1 = "/sbags"
SlashCmdList["SERVERBAGS"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "locks" then
        EnsureDB()
        local any = false
        for id in pairs(ServerBagsDB.locked) do
            local n = GetItemInfo(id)
            DEFAULT_CHAT_FRAME:AddMessage("  |cffffd100locked|r " .. (n or ("item:" .. id)))
            any = true
        end
        if not any then DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ServerBags|r no locked items.") end
    elseif msg == "unlockall" then
        EnsureDB(); ServerBagsDB.locked = {}; RefreshAllOverlays()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ServerBags|r all locks cleared.")
    elseif msg == "quiet" then
        EnsureDB()
        ServerBagsDB.quiet = not ServerBagsDB.quiet
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ServerBags|r chat messages: "
            .. (ServerBagsDB.quiet and "|cffff5555OFF|r" or "|cff33ff99ON|r"))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ServerBags|r commands: |cffffffff/sbags locks|r (list), |cffffffff/sbags unlockall|r, |cffffffff/sbags quiet|r (chat on/off). Sell-all buttons appear next to a vendor. |cffffd100Alt+click|r an item to lock it.")
    end
end

Notify("|cff33ff99ServerBags|r loaded"
    .. (hookedBagnon and " (Bagnon detected)" or " |cffff5555(Bagnon not found — lock overlay disabled)|r")
    .. ". Sell-all bar shows at vendors; |cffffd100Alt+click|r an item to lock it. /sbags for help.")
