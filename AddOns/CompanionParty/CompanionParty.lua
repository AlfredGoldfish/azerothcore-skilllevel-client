--[[============================================================================
  CompanionParty  —  WotLK 3.3.5a client addon (docs/companion-party-build-plan.md).

  A friends-list-style panel for your companion party:
    * CREATE  a companion of any class/race in your faction (server validates combo).
    * INVITE / DISMISS  a companion into/out of your group (up to 4 out at once).
    * SPEC    set a companion's cookie-cutter talent build (whispers "talents spec <n>").

  Companions are real party members: they roll on loot, take quest rewards on your
  turn-ins, and level from shared party XP (with catch-up XP if you out-level them).

  Server plumbing:
    * addon RPC (prefix COMPPTY) -> party_companions.lua (event 30):
        C:<race>:<class>:<name>:<gender>  create   I:<name> invite   D:<name> dismiss
        X dismiss-all      L request roster -> reply "R|name,lvl,cls,online;..."
    * spec change is a native bot whisper: /w <companion> talents spec <name>

  Open with /cp  (or /companion).  Install: copy this folder to
    <WoW 3.3.5a>\Interface\AddOns\CompanionParty\
============================================================================]]--

local PREFIX = "COMPPTY"

local FACTION_RACES = {
  Alliance = { {id=1,n="Human"}, {id=3,n="Dwarf"}, {id=4,n="Night Elf"}, {id=7,n="Gnome"}, {id=11,n="Draenei"} },
  Horde    = { {id=2,n="Orc"}, {id=5,n="Undead"}, {id=6,n="Tauren"}, {id=8,n="Troll"}, {id=10,n="Blood Elf"} },
}
local CLASSES = {
  {id=1,n="Warrior"}, {id=2,n="Paladin"}, {id=3,n="Hunter"}, {id=4,n="Rogue"},
  {id=5,n="Priest"}, {id=6,n="Death Knight"}, {id=7,n="Shaman"}, {id=8,n="Mage"},
  {id=9,n="Warlock"}, {id=11,n="Druid"},
}
local CLASS_NAME = {
  [1]="Warrior",[2]="Paladin",[3]="Hunter",[4]="Rogue",[5]="Priest",
  [6]="Death Knight",[7]="Shaman",[8]="Mage",[9]="Warlock",[11]="Druid",
}
local SPECS = {
  [1]={"arms pve","fury pve","prot pve","arms pvp","fury pvp","prot pvp"},
  [2]={"holy pve","prot pve","ret pve","holy pvp","prot pvp","ret pvp"},
  [3]={"bm pve","mm pve","surv pve","bm pvp","mm pvp","surv pvp"},
  [4]={"as pve","combat pve","subtlety pve","as pvp","combat pvp","subtlety pvp"},
  [5]={"disc pve","holy pve","shadow pve","disc pvp","holy pvp","shadow pvp"},
  [6]={"blood pve","frost pve","unholy pve","double aura blood pve","blood pvp","frost pvp","unholy pvp"},
  [7]={"ele pve","enh pve","resto pve","ele pvp","enh pvp","resto pvp"},
  [8]={"arcane pve","fire pve","frost pve","frostfire pve","arcane pvp","fire pvp","frost pvp"},
  [9]={"affli pve","demo pve","destro pve","affli pvp","demo pvp","destro pvp"},
  [11]={"balance pve","bear pve","resto pve","cat pve","balance pvp","cat pvp","resto pvp"},
}
local MAX_ACTIVE = 4

local function cprint(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[Companion]|r " .. msg) end
local function rpc(msg) SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player")) end
local function whisperSpec(name, spec) SendChatMessage("talents spec " .. spec, "WHISPER", nil, name) end

-- tiny timer (no C_Timer in 3.3.5): after(sec, fn)
local timers, timerHost = {}, CreateFrame("Frame")
timerHost:SetScript("OnUpdate", function(_, e)
  for i = #timers, 1, -1 do
    timers[i].t = timers[i].t - e
    if timers[i].t <= 0 then local fn = timers[i].fn; table.remove(timers, i); fn() end
  end
end)
local function after(sec, fn) timers[#timers + 1] = { t = sec, fn = fn } end

local frame, rows, selRace, selClass = nil, {}, nil, nil
local roster = {}

------------------------------------------------------------------ ROSTER UI ---
local function refresh() rpc("L") end

local function rebuildRoster()
  if not frame then return end
  local active = 0
  for _, c in ipairs(roster) do if c.online == 1 then active = active + 1 end end
  frame.count:SetText(string.format("Companions: %d   (out: %d/%d)", #roster, active, MAX_ACTIVE))

  for i, row in ipairs(rows) do row:Hide() end
  for i, c in ipairs(roster) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Frame", nil, frame)
      row:SetSize(320, 24)
      row:SetPoint("TOPLEFT", frame.listAnchor, "TOPLEFT", 0, -(i - 1) * 26)
      row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      row.label:SetPoint("LEFT", 2, 0); row.label:SetWidth(150); row.label:SetJustifyH("LEFT")

      row.act = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.act:SetSize(66, 20); row.act:SetPoint("LEFT", 156, 0)

      row.spec = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.spec:SetSize(60, 20); row.spec:SetPoint("LEFT", 226, 0); row.spec:SetText("Spec")
      rows[i] = row
    end

    row:SetPoint("TOPLEFT", frame.listAnchor, "TOPLEFT", 0, -(i - 1) * 26)
    row.label:SetText(string.format("%s |cffaaaaaa L%d %s|r", c.name, c.lvl, CLASS_NAME[c.cls] or "?"))

    row.act:SetText(c.online == 1 and "Dismiss" or "Invite")
    row.act:SetScript("OnClick", function()
      if c.online == 1 then rpc("D:" .. c.name)
      elseif active >= MAX_ACTIVE then cprint("You already have " .. MAX_ACTIVE .. " out. Dismiss one first.")
      else rpc("I:" .. c.name) end
      after(1.3, refresh)
    end)

    if c.online == 1 then row.spec:Enable() else row.spec:Disable() end
    row.spec:SetScript("OnClick", function()
      if c.online ~= 1 then cprint("Invite " .. c.name .. " first, then set its spec.") return end
      local menu = { { text = c.name .. " — spec", isTitle = true, notCheckable = true } }
      for _, s in ipairs(SPECS[c.cls] or {}) do
        menu[#menu + 1] = { text = s, notCheckable = true, func = function()
          whisperSpec(c.name, s); cprint(c.name .. " -> spec: " .. s)
        end }
      end
      EasyMenu(menu, frame.specMenu, "cursor", 0, 0, "MENU")
    end)

    row:Show()
  end
end

------------------------------------------------------------------ BUILD UI ----
local function buildFrame()
  if frame then return end
  frame = CreateFrame("Frame", "CompanionPartyFrame", UIParent)
  frame:SetSize(360, 420)
  frame:SetPoint("CENTER")
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true); frame:Hide()
  tinsert(UISpecialFrames, "CompanionPartyFrame")   -- ESC closes

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -16); title:SetText("Companion Party")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)

  -- ---- Create row -------------------------------------------------------
  local mk = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  mk:SetPoint("TOPLEFT", 20, -44); mk:SetText("Create a companion:")

  local raceDD = CreateFrame("Frame", "CompanionPartyRaceDD", frame, "UIDropDownMenuTemplate")
  raceDD:SetPoint("TOPLEFT", 8, -60)
  local myRaces = FACTION_RACES[UnitFactionGroup("player")] or FACTION_RACES.Horde
  UIDropDownMenu_SetWidth(raceDD, 90)
  UIDropDownMenu_Initialize(raceDD, function()
    for _, r in ipairs(myRaces) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = r.n; info.func = function() selRace = r.id; UIDropDownMenu_SetText(raceDD, r.n) end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetText(raceDD, "Race")

  local classDD = CreateFrame("Frame", "CompanionPartyClassDD", frame, "UIDropDownMenuTemplate")
  classDD:SetPoint("LEFT", raceDD, "RIGHT", -10, 0)
  UIDropDownMenu_SetWidth(classDD, 100)
  UIDropDownMenu_Initialize(classDD, function()
    for _, c in ipairs(CLASSES) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = c.n; info.func = function() selClass = c.id; UIDropDownMenu_SetText(classDD, c.n) end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetText(classDD, "Class")

  local nameBox = CreateFrame("EditBox", "CompanionPartyNameBox", frame, "InputBoxTemplate")
  nameBox:SetSize(120, 20); nameBox:SetPoint("TOPLEFT", 24, -92)
  nameBox:SetAutoFocus(false); nameBox:SetMaxLetters(12)
  local nlbl = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  nlbl:SetPoint("BOTTOMLEFT", nameBox, "TOPLEFT", -2, 1); nlbl:SetText("Name")

  local createBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  createBtn:SetSize(90, 22); createBtn:SetPoint("LEFT", nameBox, "RIGHT", 14, 0); createBtn:SetText("Create")
  createBtn:SetScript("OnClick", function()
    local name = nameBox:GetText()
    if not selRace or not selClass then cprint("Pick a race and class first.") return end
    if not name or name == "" then cprint("Enter a name.") return end
    local g = math.random(0, 1)
    rpc("C:" .. selRace .. ":" .. selClass .. ":" .. name .. ":" .. g)
    cprint("Creating " .. name .. " ... (watch for the server message)")
    nameBox:SetText("")
    after(1.6, refresh)
  end)

  -- ---- Divider + roster header -----------------------------------------
  local hdr = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdr:SetPoint("TOPLEFT", 20, -124); hdr:SetText("Your companions:")
  frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.count:SetPoint("TOPRIGHT", -20, -126)

  frame.listAnchor = CreateFrame("Frame", nil, frame)
  frame.listAnchor:SetSize(320, 1); frame.listAnchor:SetPoint("TOPLEFT", 20, -144)

  frame.specMenu = CreateFrame("Frame", "CompanionPartySpecMenu", UIParent, "UIDropDownMenuTemplate")

  -- ---- Footer buttons ---------------------------------------------------
  local dismissAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  dismissAll:SetSize(110, 22); dismissAll:SetPoint("BOTTOMLEFT", 20, 18); dismissAll:SetText("Dismiss all")
  dismissAll:SetScript("OnClick", function() rpc("X"); after(1.2, refresh) end)

  local refreshBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  refreshBtn:SetSize(90, 22); refreshBtn:SetPoint("BOTTOMRIGHT", -20, 18); refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", refresh)

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOM", 0, 44)
  hint:SetText("Invite up to " .. MAX_ACTIVE .. ". They level, quest & loot with you.")
end

local function toggle()
  buildFrame()
  if frame:IsShown() then frame:Hide() else frame:Show(); refresh() end
end

------------------------------------------------------------------- EVENTS -----
local function onMessage(message)
  local body = message:match("^R|(.*)$")
  if not body then return end
  roster = {}
  for entry in (body):gmatch("[^;]+") do
    local n, l, c, o = entry:match("^(.-),(%d+),(%d+),(%d+)$")
    if n then roster[#roster + 1] = { name = n, lvl = tonumber(l), cls = tonumber(c), online = tonumber(o) } end
  end
  rebuildRoster()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:SetScript("OnEvent", function(self, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, message = ...
    if prefix == PREFIX then onMessage(message) end
  elseif event == "PARTY_MEMBERS_CHANGED" then
    if frame and frame:IsShown() then after(0.5, refresh) end
  elseif event == "ADDON_LOADED" and ... == "CompanionParty" then
    CompanionPartyDB = CompanionPartyDB or {}
    cprint("loaded. Open with |cffffff00/cp|r  (create, invite, set spec).")
  end
end)

SLASH_COMPANIONPARTY1 = "/cp"
SLASH_COMPANIONPARTY2 = "/companion"
SLASH_COMPANIONPARTY3 = "/companions"
SlashCmdList["COMPANIONPARTY"] = toggle
