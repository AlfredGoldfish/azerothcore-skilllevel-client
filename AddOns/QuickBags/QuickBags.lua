-- QuickBags: unified inventory window for WotLK 3.3.5a
--   Sort · Sell-by-quality · Item-lock · Bag-slot bar · Search · Per-bag filter
--   Free-slot counter · New-item glow · Auto-open at vendor/mail/bank

local COLS   = 12       -- items per row
local BTN    = 37       -- button size
local PAD    = 4        -- gap between buttons
local LEFT   = 14       -- left margin
local TOP    = 72       -- space above the grid (title + sort + sell row)
local BOTTOM = 44       -- space below the grid (money + slot count + bag-slot bar)
local BAGS   = {0, 1, 2, 3, 4}

local QUALITY_NAMES = {[0]="Gray", [1]="White", [2]="Green", [3]="Blue", [4]="Purple"}
local SELL_TIERS    = {0, 1, 2, 3, 4}
local CONFIRM_ABOVE = 2         -- confirm before selling quality > 2 (Blue, Purple)

----------------------------------------------------------------- module state (shared by all closures)
local searchText = ""           -- lower-cased; "" = no filter
local filterBag  = nil          -- nil = show all bags; else a container id 0-4
local sorting    = false        -- true while an auto-sort runs (hoisted: new-item scan must see it)
local newFlags   = {}           -- newFlags[bag*100+slot] = true for freshly-added items
local prevItems  = {}           -- prevItems[bag][slot] = {id=, count=} snapshot for new detection
local newSeeded  = false        -- the first scan seeds the snapshot silently (no glow)
local glowT      = 0            -- pulse clock for the new-item glow

----------------------------------------------------------------- lock storage (SavedVariablesPerCharacter: QuickBagsDB)
local function EnsureDB()
    if type(QuickBagsDB) ~= "table" then QuickBagsDB = {} end
    if type(QuickBagsDB.locked) ~= "table" then QuickBagsDB.locked = {} end
    if QuickBagsDB.autoOpen == nil then QuickBagsDB.autoOpen = true end   -- auto-open at vendor/mail/bank
end

local function ItemIDFromLink(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function IsLockedID(id)
    if not id then return false end
    return (QuickBagsDB and QuickBagsDB.locked and QuickBagsDB.locked[id]) and true or false
end

local function IsLockedSlot(bag, slot)
    return IsLockedID(ItemIDFromLink(GetContainerItemLink(bag, slot)))
end

function QuickBags_ToggleLock(bag, slot)
    EnsureDB()
    local link = GetContainerItemLink(bag, slot)
    local id = ItemIDFromLink(link)
    if not id then return end
    if QuickBagsDB.locked[id] then
        QuickBagsDB.locked[id] = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r unlocked " .. (link or ("item:" .. id)) .. ".")
    else
        QuickBagsDB.locked[id] = true
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r locked " .. (link or ("item:" .. id)) .. " |cff888888(protected from Sell All)|r.")
    end
    QuickBags_Update()
end

----------------------------------------------------------------- sell by quality
local function IterSellable(q, fn)
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, quality, _, _, _, _, _, equipSlot, _, sellPrice = GetItemInfo(link)
                local isBag = (equipSlot == "INVTYPE_BAG")
                local isGear = equipSlot and equipSlot ~= "" and not isBag
                -- Gray (0): sell ALL trash (junk + gear), never a bag. White+ (1-4): equipment only.
                local sellable
                if q == 0 then sellable = not isBag else sellable = isGear end
                if quality == q and sellable and sellPrice and sellPrice > 0 then
                    if not IsLockedID(ItemIDFromLink(link)) then
                        local _, cnt = GetContainerItemInfo(bag, slot)
                        cnt = cnt or 1
                        fn(bag, slot, cnt * sellPrice)
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
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555QuickBags:|r open a vendor first.")
        return
    end
    local count, value = 0, 0
    IterSellable(q, function(bag, slot, v)
        UseContainerItem(bag, slot)     -- sells the stack at the open merchant
        count = count + 1; value = value + v
    end)
    if count > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r sold |cffffffff" .. count .. "|r " .. (QUALITY_NAMES[q] or "") .. " item(s) for " .. GetCoinTextureString(value) .. ".")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r no unlocked " .. (QUALITY_NAMES[q] or "") .. " items to sell.")
    end
    QuickBags_Update()
end

StaticPopupDialogs["QUICKBAGS_SELL_CONFIRM"] = {
    text = "Sell all %s items?\n%s",
    button1 = YES, button2 = NO,
    OnAccept = function() DoSell(QuickBags_pendingQ) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function QuickBags_SellQuality(q)
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555QuickBags:|r open a vendor first.")
        return
    end
    if q > CONFIRM_ABOVE then                       -- Blue / Purple: confirm first
        local count, value = CountSellable(q)
        if count == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r no unlocked " .. (QUALITY_NAMES[q] or "") .. " items to sell.")
            return
        end
        QuickBags_pendingQ = q
        StaticPopup_Show("QUICKBAGS_SELL_CONFIRM", QUALITY_NAMES[q], count .. " items  (" .. GetCoinTextureString(value) .. ")")
    else
        DoSell(q)
    end
end

----------------------------------------------------------------- window
local f = CreateFrame("Frame", "QuickBagsFrame", UIParent)
f:SetFrameStrata("HIGH")
f:SetWidth(LEFT*2 + COLS*(BTN+PAD) - PAD)
f:SetHeight(300)
f:SetPoint("CENTER")
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
f:Hide()
tinsert(UISpecialFrames, "QuickBagsFrame")   -- close with Escape

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -14)
title:SetText("Bags")

local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
sortBtn:SetSize(56, 22)
sortBtn:SetText("Sort")
sortBtn:SetPoint("TOPLEFT", 14, -12)
sortBtn:SetScript("OnClick", function() QuickBags_Sort() end)

----------------------------------------------------------------- search box (highlight matches, dim the rest)
local search = CreateFrame("EditBox", "QuickBagsSearch", f, "InputBoxTemplate")
search:SetAutoFocus(false)
search:SetSize(118, 16)
search:SetMaxLetters(24)
search:SetPoint("RIGHT", close, "LEFT", -8, 0)
local searchHint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchHint:SetPoint("LEFT", search, "LEFT", 4, 0)
searchHint:SetText("Search")
search:SetScript("OnTextChanged", function(self)
    local t = self:GetText() or ""
    searchText = t:lower()
    if t == "" then searchHint:Show() else searchHint:Hide() end
    QuickBags_Update()
end)
search:SetScript("OnEditFocusGained", function() searchHint:Hide() end)
search:SetScript("OnEditFocusLost", function(self)
    if (self:GetText() or "") == "" then searchHint:Show() end
end)
search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
search:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)

----------------------------------------------------------------- sell-by-quality row
local sellLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sellLbl:SetPoint("TOPLEFT", 16, -44)
sellLbl:SetText("Sell all:")

local sellButtons = {}
for i, q in ipairs(SELL_TIERS) do
    local sb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sb:SetSize(62, 21)
    sb:SetText(QUALITY_NAMES[q])
    sb:SetPoint("TOPLEFT", 62 + (i-1)*64, -40)
    local c = ITEM_QUALITY_COLORS[q]
    local fs = sb:GetFontString()
    if fs and c then fs:SetTextColor(c.r, c.g, c.b) end
    sb:SetScript("OnClick", function() QuickBags_SellQuality(q) end)
    sb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if q == 0 then
            GameTooltip:AddLine("Sell all Gray trash")
            GameTooltip:AddLine("At a vendor. All poor-quality junk (gear + misc). Skips |cffffd100locked|r items and bags.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Sell all " .. QUALITY_NAMES[q] .. " equipment")
            GameTooltip:AddLine("At a vendor. Gear only (armor/weapons) — never trade goods, consumables, or quest items. Skips |cffffd100locked|r items.", 0.8, 0.8, 0.8, true)
        end
        if q > CONFIRM_ABOVE then GameTooltip:AddLine("Asks to confirm first.", 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
    sb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    sellButtons[i] = sb
end

local money = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
money:SetPoint("BOTTOMLEFT", 16, 16)

local slotInfo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
slotInfo:SetPoint("BOTTOM", 0, 18)   -- free-slot counter, bottom-center

----------------------------------------------------------------- bag-slot bar (view / swap / filter bags)
-- Backpack + the 4 equippable bag slots, bottom-right.
--   Left-click (empty-handed) : show only that bag   (click again = show all)
--   Left-click holding a bag   : equip it into that slot
--   Right-click / drag off      : pick the equipped bag up (to move / replace)
--   Drag a bag on               : equip / swap
local BAGBAR_BTN    = 26
local BAGBAR_GAP    = 3
local BAGBAR_SLOTS  = { 0, 1, 2, 3, 4 }   -- 0 = backpack (fixed, filter-only); 1-4 = equippable
local EMPTY_BAG_TEX = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag"
local bagSlotButtons = {}

local function SetFilter(cid)
    if filterBag == cid then filterBag = nil else filterBag = cid end
    QuickBags_Update()
end

for i, cid in ipairs(BAGBAR_SLOTS) do
    local b = CreateFrame("Button", "QuickBagsBagSlot"..cid, f, "ItemButtonTemplate")
    b:SetSize(BAGBAR_BTN, BAGBAR_BTN)
    b.cid     = cid
    b.invSlot = (cid ~= 0) and ContainerIDToInventoryID(cid) or nil   -- bags 1-4 -> inv slots 20-23
    if i == 1 then
        local rowW = #BAGBAR_SLOTS * BAGBAR_BTN + (#BAGBAR_SLOTS - 1) * BAGBAR_GAP
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", -(rowW + 14), 12)
    else
        b:SetPoint("LEFT", bagSlotButtons[i-1], "RIGHT", BAGBAR_GAP, 0)
    end
    -- "showing only this bag" highlight
    local fg = b:CreateTexture(nil, "OVERLAY")
    fg:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    fg:SetBlendMode("ADD")
    fg:SetAllPoints(b)
    fg:Hide()
    b.filterGlow = fg

    if cid == 0 then
        -- backpack: built in, cannot be swapped — click filters to it
        b:SetScript("OnClick", function(self) SetFilter(0) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(BACKPACK_TOOLTIP or "Backpack")
            GameTooltip:AddLine("Click: show only the backpack.", 0.7, 0.9, 0.7, true)
            GameTooltip:AddLine("Built in — can't be swapped.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    else
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:RegisterForDrag("LeftButton")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                PickupInventoryItem(self.invSlot)      -- unequip / pick up the bag
            elseif CursorHasItem() then
                PutItemInBag(self.invSlot)             -- equip the bag on the cursor
            else
                SetFilter(self.cid)                    -- show only this bag
            end
        end)
        b:SetScript("OnReceiveDrag", function(self) PutItemInBag(self.invSlot) end)
        b:SetScript("OnDragStart",   function(self) PickupInventoryItem(self.invSlot) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if not GameTooltip:SetInventoryItem("player", self.invSlot) then
                GameTooltip:SetText("Empty Bag Slot")
                GameTooltip:AddLine("Drag a bag here to equip it.", 0.7, 0.7, 0.7, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click: show only this bag.", 0.7, 0.9, 0.7, true)
            GameTooltip:AddLine("Right-click: pick up (unequip).", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    bagSlotButtons[i] = b
end

local function QuickBags_UpdateBagBar()
    for _, b in ipairs(bagSlotButtons) do
        if b.cid == 0 then
            SetItemButtonTexture(b, "Interface\\Buttons\\Button-Backpack-Up")
        else
            local tex = GetInventoryItemTexture("player", b.invSlot)
            SetItemButtonTexture(b, tex or EMPTY_BAG_TEX)
            SetItemButtonDesaturated(b, not tex)   -- empty slots read as dimmed
        end
        if filterBag == b.cid then b.filterGlow:Show() else b.filterGlow:Hide() end
    end
end

----------------------------------------------------------------- item buttons
local bagFrames, buttons = {}, {}
for _, bag in ipairs(BAGS) do
    local bf = CreateFrame("Frame", "QuickBagsBag"..bag, f)
    bf:SetAllPoints(f)
    bf:SetID(bag)
    bagFrames[bag] = bf
    buttons[bag] = {}
end

local function GetButton(bag, slot)
    local pool = buttons[bag]
    if not pool[slot] then
        local b = CreateFrame("Button", "QuickBagsBag"..bag.."Item"..slot, bagFrames[bag], "ContainerFrameItemButtonTemplate")
        b:SetID(slot)
        b:SetSize(BTN, BTN)
        local q = b:CreateTexture(nil, "OVERLAY")
        q:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        q:SetBlendMode("ADD")
        q:SetAlpha(0.75)
        q:SetPoint("CENTER")
        q:SetSize(BTN + 22, BTN + 22)
        q:Hide()
        b.qborder = q
        -- new-item glow (pulses; sits under the quality border)
        local ng = b:CreateTexture(nil, "OVERLAY")
        ng:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        ng:SetBlendMode("ADD")
        ng:SetPoint("CENTER")
        ng:SetSize(BTN + 20, BTN + 20)
        ng:SetVertexColor(1, 0.95, 0.2)   -- gold = new
        ng:Hide()
        b.newglow = ng
        -- lock indicator (padlock, top-left corner)
        local lk = b:CreateTexture(nil, "OVERLAY")
        lk:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
        lk:SetSize(15, 15)
        lk:SetPoint("TOPLEFT", -2, 2)
        lk:Hide()
        b.lockicon = lk
        -- Alt+Click toggles lock; otherwise default container behavior (use/sell/pickup)
        b:SetScript("OnClick", function(self, button)
            if IsAltKeyDown() then
                QuickBags_ToggleLock(self:GetParent():GetID(), self:GetID())
            else
                ContainerFrameItemButton_OnClick(self, button)
            end
        end)
        -- append a "Locked" line to the item tooltip
        b:HookScript("OnEnter", function(self)
            if IsLockedSlot(self:GetParent():GetID(), self:GetID()) then
                GameTooltip:AddLine("|cff33ff99QuickBags: Locked|r |cff888888(protected from Sell All)|r")
                GameTooltip:Show()
            end
        end)
        pool[slot] = b
    end
    return pool[slot]
end

----------------------------------------------------------------- free-slot counter + new-item detection
local function CountSlots()
    local free, total = 0, 0
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        total = total + n
        for slot = 1, n do
            if not GetContainerItemLink(bag, slot) then free = free + 1 end
        end
    end
    return free, total
end

-- Snapshot bag contents; flag slots that gained a new item (or a bigger stack).
-- seed=true fills the snapshot silently (login / after a sort) so nothing false-flags.
local function ScanNew(seed)
    for _, bag in ipairs(BAGS) do
        prevItems[bag] = prevItems[bag] or {}
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            local id   = link and ItemIDFromLink(link) or false
            local cnt  = 0
            if id then local _, c = GetContainerItemInfo(bag, slot); cnt = c or 1 end
            local prev = prevItems[bag][slot]
            local isNew = false
            if id then
                if not prev or prev.id ~= id then isNew = true
                elseif prev.count and cnt > prev.count then isNew = true end
            end
            local key = bag * 100 + slot
            if isNew and not seed and not sorting then
                newFlags[key] = true
            elseif not id then
                newFlags[key] = nil            -- emptied slot is no longer "new"
            end
            prevItems[bag][slot] = id and { id = id, count = cnt } or false
        end
        for slot = n + 1, 40 do newFlags[bag*100+slot] = nil end   -- clear flags past bag size
    end
end

local function IsNewSlot(bag, slot) return newFlags[bag*100+slot] == true end

----------------------------------------------------------------- update / layout
function QuickBags_Update()
    if not f:IsShown() then return end
    local index = 0
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        if filterBag ~= nil and bag ~= filterBag then
            for slot = 1, #buttons[bag] do buttons[bag][slot]:Hide() end   -- filtered out
        else
            for slot = 1, n do
                local b = GetButton(bag, slot)
                local col, row = index % COLS, math.floor(index / COLS)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT + col*(BTN+PAD), -TOP - row*(BTN+PAD))

                local texture, count, locked, quality = GetContainerItemInfo(bag, slot)
                SetItemButtonTexture(b, texture)
                SetItemButtonCount(b, count)
                SetItemButtonDesaturated(b, locked)

                if quality and quality > 1 and ITEM_QUALITY_COLORS[quality] then
                    local c = ITEM_QUALITY_COLORS[quality]
                    b.qborder:SetVertexColor(c.r, c.g, c.b)
                    b.qborder:Show()
                else
                    b.qborder:Hide()
                end

                if IsLockedSlot(bag, slot) then b.lockicon:Show() else b.lockicon:Hide() end
                if IsNewSlot(bag, slot)    then b.newglow:Show()  else b.newglow:Hide()  end

                -- search: dim anything whose name doesn't contain the query
                local dim = false
                if searchText ~= "" then
                    local link = GetContainerItemLink(bag, slot)
                    local name = link and link:match("%[(.-)%]")
                    dim = not (name and name:lower():find(searchText, 1, true))
                end
                b:SetAlpha(dim and 0.25 or 1.0)

                b:Show()
                index = index + 1
            end
            for slot = n + 1, #buttons[bag] do buttons[bag][slot]:Hide() end
        end
    end
    local rows = math.max(1, math.ceil(index / COLS))
    f:SetHeight(TOP + rows*(BTN+PAD) - PAD + BOTTOM)
    money:SetText(GetCoinTextureString(GetMoney()))

    local free, total = CountSlots()
    if     free == 0  then slotInfo:SetTextColor(1.0, 0.3, 0.3)
    elseif free <= 3  then slotInfo:SetTextColor(1.0, 0.85, 0.3)
    else                   slotInfo:SetTextColor(0.7, 0.9, 0.7) end
    slotInfo:SetText(free .. "/" .. total .. " free")

    title:SetText(filterBag == nil and "Bags"
              or (filterBag == 0 and "Backpack" or ("Bag " .. filterBag)))
    QuickBags_UpdateBagBar()
end

----------------------------------------------------------------- WotLK sort (manual swaps)
local driver = CreateFrame("Frame")
local acc = 0

local function KeyOf(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return "\255" end          -- empties sort to the end
    local name, _, quality, _, _, class, subclass = GetItemInfo(link)
    -- higher quality first, then class, subclass, name
    return string.format("%d~%s~%s~%s", 9 - (quality or 0), class or "", subclass or "", name or "")
end

local function AnyLocked()
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local _, _, locked = GetContainerItemInfo(bag, slot)
            if locked then return true end
        end
    end
    return false
end

local function SortStep()
    if AnyLocked() then return end               -- wait for the last move to finish
    local slots = {}
    for _, bag in ipairs(BAGS) do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            slots[#slots+1] = { bag = bag, slot = slot, key = KeyOf(bag, slot) }
        end
    end
    local desired = {}
    for i, s in ipairs(slots) do desired[i] = s.key end
    table.sort(desired)

    for i = 1, #slots do
        if slots[i].key ~= desired[i] then
            for j = i + 1, #slots do
                if slots[j].key == desired[i] then
                    PickupContainerItem(slots[j].bag, slots[j].slot)   -- grab desired item
                    PickupContainerItem(slots[i].bag, slots[i].slot)   -- drop at target (swaps)
                    if CursorHasItem() then
                        PickupContainerItem(slots[j].bag, slots[j].slot) -- put displaced item back
                    end
                    return                          -- one move per step
                end
            end
            return
        end
    end
    -- fully sorted
    sorting = false
    driver:SetScript("OnUpdate", nil)
    ScanNew(true)                                 -- re-seed so the shuffle didn't flag items "new"
    QuickBags_Update()
end

function QuickBags_Sort()
    if sorting then return end
    sorting = true
    acc = 0
    driver:SetScript("OnUpdate", function(_, e)
        acc = acc + e
        if acc >= 0.12 then acc = 0; SortStep() end
    end)
end

----------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("ITEM_LOCK_CHANGED")
ev:RegisterEvent("BAG_UPDATE_COOLDOWN")
ev:RegisterEvent("PLAYER_MONEY")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "QuickBags" then EnsureDB() end
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        ScanNew(true); newSeeded = true          -- silent seed of the snapshot
    elseif event == "BAG_UPDATE" then
        if not newSeeded then ScanNew(true); newSeeded = true else ScanNew(false) end
    end
    QuickBags_Update()
end)

f:SetScript("OnShow", QuickBags_Update)
f:SetScript("OnHide", function() for k in pairs(newFlags) do newFlags[k] = nil end end)  -- seen = clear glow

-- pulse the new-item glow while the window is open and anything is flagged
f:SetScript("OnUpdate", function(self, elapsed)
    if not next(newFlags) then return end
    glowT = glowT + elapsed
    local a = 0.35 + 0.45 * (0.5 + 0.5 * math.sin(glowT * 4))
    for _, bag in ipairs(BAGS) do
        for _, b in pairs(buttons[bag]) do
            if b.newglow:IsShown() then b.newglow:SetAlpha(a) end
        end
    end
end)

----------------------------------------------------------------- open with the bag key
local function Show() f:Show(); QuickBags_Update() end
local function Toggle() if f:IsShown() then f:Hide() else Show() end end
ToggleBackpack   = Toggle
ToggleAllBags    = Toggle
OpenAllBags      = Show
OpenBackpack     = Show
CloseAllBags     = function() f:Hide() end
CloseBackpack    = function() f:Hide() end
ToggleBag        = function() Toggle() end

----------------------------------------------------------------- auto open/close at vendor, mail, bank
local autoOpened = false
local function AutoOpen()
    if not (QuickBagsDB and QuickBagsDB.autoOpen) then return end
    if not f:IsShown() then autoOpened = true; Show() end
end
local function AutoClose()
    if autoOpened then autoOpened = false; f:Hide() end   -- only close what we auto-opened
end
local auto = CreateFrame("Frame")
auto:RegisterEvent("MERCHANT_SHOW");    auto:RegisterEvent("MERCHANT_CLOSED")
auto:RegisterEvent("MAIL_SHOW");        auto:RegisterEvent("MAIL_CLOSED")
auto:RegisterEvent("BANKFRAME_OPENED"); auto:RegisterEvent("BANKFRAME_CLOSED")
auto:SetScript("OnEvent", function(_, e)
    if e == "MERCHANT_SHOW" or e == "MAIL_SHOW" or e == "BANKFRAME_OPENED" then
        AutoOpen()
    else
        AutoClose()
    end
end)

----------------------------------------------------------------- slash commands
SLASH_QUICKBAGS1 = "/qb"
SLASH_QUICKBAGS2 = "/bags"
SlashCmdList["QUICKBAGS"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "sort" then
        QuickBags_Sort()
    elseif msg == "auto" then
        EnsureDB()
        QuickBagsDB.autoOpen = not QuickBagsDB.autoOpen
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r auto-open at vendor/mail/bank: "
            .. (QuickBagsDB.autoOpen and "|cff33ff99ON|r" or "|cffff5555OFF|r"))
    elseif msg == "locks" then
        EnsureDB()
        local any = false
        for id in pairs(QuickBagsDB.locked) do
            local n = GetItemInfo(id)
            DEFAULT_CHAT_FRAME:AddMessage("  |cffffd100locked|r " .. (n or ("item:" .. id)))
            any = true
        end
        if not any then DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r no locked items.") end
    elseif msg == "unlockall" then
        EnsureDB(); QuickBagsDB.locked = {}; QuickBags_Update()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r all locks cleared.")
    else
        Toggle()
    end
end
SLASH_QBSORT1 = "/sort"
SlashCmdList["QBSORT"] = function() QuickBags_Sort() end

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickBags|r loaded. /qb to open · Sort · Sell-all at a vendor · |cffffd100Alt+Click|r an item to lock · type in the Search box to find items · click a bag slot (bottom-right) to show only that bag, or drag a bag on to equip. /qb auto toggles auto-open.")
