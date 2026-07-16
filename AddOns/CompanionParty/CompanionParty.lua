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

------------------------------------------------------- ROLES & COMMANDS ------
-- You address a ROLE, not a name. Roles follow the SPEC you assign (prot/bear ->
-- tank, holy/disc/resto -> heal, else dps); DK tanks & oddities: click the role
-- pill to override. Stored per companion in CompanionPartyDB.roles. When several
-- of a role are out, the "primary" (CompanionPartyDB.primary) is who gets tank/
-- heal orders; dps orders go to ALL dps.
local ROLE_TXT  = { TANK="|cff6f9bc4T|r", HEAL="|cff8cc07aH|r", DPS="|cffd1706bD|r" }
local ROLE_NEXT = { DPS="TANK", TANK="HEAL", HEAL="DPS" }

local function roleFromSpec(spec)
  spec = string.lower(spec or "")
  if spec:find("prot") or spec:find("bear") then return "TANK" end
  if spec:find("holy") or spec:find("disc") or spec:find("resto") then return "HEAL" end
  return "DPS"
end

local function getRole(name) return (CompanionPartyDB.roles or {})[name] or "DPS" end

local function setRole(name, role, makePrimary)
  CompanionPartyDB.roles = CompanionPartyDB.roles or {}
  CompanionPartyDB.primary = CompanionPartyDB.primary or {}
  CompanionPartyDB.roles[name] = role
  for r, pn in pairs(CompanionPartyDB.primary) do                 -- release a stale primary slot
    if pn == name and r ~= role then CompanionPartyDB.primary[r] = nil end
  end
  if makePrimary and (role == "TANK" or role == "HEAL") then
    CompanionPartyDB.primary[role] = name
  end
end

-- A bot only obeys 'tank attack'/'focus heal' if it's actually in that combat
-- strategy (IsTank/IsHeal = "has tank/heal strategy"), so assigning a role must
-- push the strategy to the bot. It persists on the bot server-side once set.
local ROLE_STRAT = {
  TANK = "+tank,+tank assist,-heal",       -- tank assist = pick up your target
  HEAL = "+heal,-tank,-tank assist",
  DPS  = "+dps,-tank,-tank assist,-heal",
}
local function applyRole(name)             -- send to an OUT companion (whisper is ignored if offline)
  local s = ROLE_STRAT[getRole(name)]
  if s then SendChatMessage("co " .. s, "WHISPER", nil, name) end
end
local function applyRoleIfSpecial(name)    -- on invite: only tank/heal need it (dps is the default)
  local r = getRole(name)
  if r == "TANK" or r == "HEAL" then applyRole(name) end
end

-- Re-push every out companion's strategy in one click (only those you've given a role).
local function applyAllRoles()
  if GetNumPartyMembers() == 0 then cprint("No companions are out.") return end
  local n = 0
  for i = 1, GetNumPartyMembers() do
    local nm = UnitName("party" .. i)
    if nm and CompanionPartyDB.roles and CompanionPartyDB.roles[nm] then applyRole(nm); n = n + 1 end
  end
  if n == 0 then cprint("None of your out companions has a role yet — set one with the T/H/D pill.")
  else cprint("Applied roles to " .. n .. " companion" .. (n == 1 and "" or "s") .. ".") end
end

-- Seed a few BASE macros in the WoW macro list you can copy into your own. They use
-- the addon's own /ct /cd slashes + party chat, so they're ready to extend (add a
-- /target, /cast, etc. above them). Two are combo templates showing the pattern.
local function makeExampleMacros()
  if InCombatLockdown() then cprint("Can't create macros during combat — try again after the fight.") return end
  local me = UnitName("player")
  local list = {
    { n = "CP Assist",    b = "/p attack" },                                   -- all companions -> your target
    { n = "CP TankPull",  b = "/ct tank attack" },                             -- your tank -> your target
    { n = "CP HealMe",    b = "/ch focus heal +" .. me },                      -- your healer prioritizes you
    { n = "CP DpsAll",    b = "/cd attack" },                                  -- all dps -> your target
    { n = "CP Engage",    b = "/targetenemy\n/startattack\n/p attack" },       -- combo: target, swing, party assist
    { n = "CP PullCombo", b = "/targetenemy\n/ct tank attack" },              -- combo: target, tank pulls (you hang back)
  }
  local made, upd = 0, 0
  for _, m in ipairs(list) do
    local idx = GetMacroIndexByName(m.n)
    if idx and idx > 0 then EditMacro(idx, m.n, "INV_Misc_GroupLooking", m.b); upd = upd + 1
    elseif CreateMacro(m.n, "INV_Misc_GroupLooking", m.b, nil) then made = made + 1
    else cprint("Your macro list is full — free a general slot (|cffffff00/macro|r) and try again."); break end
  end
  cprint("Example macros ready (" .. made .. " new, " .. upd .. " updated). Open |cffffff00/macro|r to copy them; swap in your own /cast or /target lines.")
end

-- who is actually OUT (real party members), grouped by assigned role
local function partyByRole()
  local t = { TANK = {}, HEAL = {}, DPS = {} }
  for i = 1, GetNumPartyMembers() do
    local nm = UnitName("party" .. i)
    if nm then local r = getRole(nm); t[r][#t[r] + 1] = nm end
  end
  return t
end

local function primaryName(role)
  local list = partyByRole()[role]
  if #list == 0 then return nil end
  local p = (CompanionPartyDB.primary or {})[role]
  if p then for _, nm in ipairs(list) do if nm == p then return p end end end
  return list[1]                                    -- fallback: first of that role who is out
end

local function sendTo(name, cmd) SendChatMessage(cmd, "WHISPER", nil, name) end

-- Address a role. tank/heal -> the primary holder; dps -> EVERY dps that is out.
local function cmdRole(role, cmd)
  if not cmd or cmd == "" then cprint("Give a command, e.g. |cffffff00/ct attack|r") return end
  if role == "DPS" then
    local list = partyByRole().DPS
    if #list == 0 then cprint("No DPS companion is out.") return end
    for _, nm in ipairs(list) do sendTo(nm, cmd) end
  else
    local nm = primaryName(role)
    if not nm then cprint("No " .. string.lower(role) .. " companion is out.") return end
    sendTo(nm, cmd)
  end
end

local function cmdAll(cmd)
  if GetNumPartyMembers() == 0 then cprint("No companions are out.") return end
  SendChatMessage(cmd, "PARTY")
end

local frame, rows, selRace, selClass = nil, {}, nil, nil
local bar
local selFilter = 1          -- roster filter: a class id, or 0 = currently-out companions
local roster = {}

------------------------------------------------------------------ ROSTER UI ---
local function refresh() rpc("L:" .. (selFilter or 1)) end

-- FAVORITES: check up to 4 companions once; "Invite Favorite Party" summons them.
local function countFavs()
  local n = 0; for _ in pairs(CompanionPartyDB.favorites or {}) do n = n + 1 end; return n
end
local function isFav(name) return CompanionPartyDB.favorites and CompanionPartyDB.favorites[name] end
local function toggleFav(name)
  CompanionPartyDB.favorites = CompanionPartyDB.favorites or {}
  if CompanionPartyDB.favorites[name] then CompanionPartyDB.favorites[name] = nil; return false end
  if countFavs() >= MAX_ACTIVE then
    cprint("You already have " .. MAX_ACTIVE .. " favorites — uncheck one first.") return nil
  end
  CompanionPartyDB.favorites[name] = true; return true
end
local function inviteFavorites()
  local favs = CompanionPartyDB.favorites or {}
  local out = {}                                    -- who's already in the party
  for i = 1, GetNumPartyMembers() do local nm = UnitName("party" .. i); if nm then out[nm] = true end end
  local names = {}
  for name in pairs(favs) do names[#names + 1] = name end
  if #names == 0 then cprint("No favorites yet — check the box on up to " .. MAX_ACTIVE .. " companions first.") return end
  local delay, sent = 0, 0
  for _, name in ipairs(names) do                   -- stagger the invites so the logins queue cleanly
    if not out[name] then
      local nm = name
      after(delay, function() rpc("I:" .. nm) end)
      after(delay + 3, function() applyRoleIfSpecial(nm) end)   -- restore its tank/heal strategy once logged in
      delay = delay + 0.4; sent = sent + 1
    end
  end
  if sent == 0 then cprint("Your favorite party is already out.")
  else cprint("Summoning your favorite party (" .. sent .. " incoming)...") end
  after(delay + 1.3, refresh)
end

local function rebuildRoster()
  if not frame then return end
  frame.count:SetText(string.format("%d shown  |  max %d out", #roster, MAX_ACTIVE))

  for i, row in ipairs(rows) do row:Hide() end
  for i, c in ipairs(roster) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Frame", nil, frame)
      row:SetSize(320, 24)
      row:SetPoint("TOPLEFT", frame.listAnchor, "TOPLEFT", 0, -(i - 1) * 26)
      row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      row.label:SetPoint("LEFT", 2, 0); row.label:SetWidth(106); row.label:SetJustifyH("LEFT")

      row.role = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.role:SetSize(24, 20); row.role:SetPoint("LEFT", 112, 0)
      row.role:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Role: " .. getRole(row._name))
        GameTooltip:AddLine("Click to change. Tank/Heal become the primary that /ct /ch address.", .7,.7,.7, true)
        GameTooltip:Show()
      end)
      row.role:SetScript("OnLeave", function() GameTooltip:Hide() end)

      row.act = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.act:SetSize(60, 20); row.act:SetPoint("LEFT", 140, 0)

      row.spec = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.spec:SetSize(58, 20); row.spec:SetPoint("LEFT", 204, 0); row.spec:SetText("Spec")

      row.fav = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      row.fav:SetSize(22, 22); row.fav:SetPoint("LEFT", 266, -1)
      row.fav:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Favorite")
        GameTooltip:AddLine("Check up to " .. MAX_ACTIVE .. "; 'Invite Favorite Party' summons them all in one click.", .7,.7,.7, true)
        GameTooltip:Show()
      end)
      row.fav:SetScript("OnLeave", function() GameTooltip:Hide() end)
      rows[i] = row
    end

    row._name = c.name
    row:SetPoint("TOPLEFT", frame.listAnchor, "TOPLEFT", 0, -(i - 1) * 26)
    row.label:SetText(string.format("%s |cffaaaaaa L%d %s|r", c.name, c.lvl, CLASS_NAME[c.cls] or "?"))

    row.role:SetText(ROLE_TXT[getRole(c.name)])
    row.role:SetScript("OnClick", function()
      local nxt = ROLE_NEXT[getRole(c.name)]
      setRole(c.name, nxt, true)
      row.role:SetText(ROLE_TXT[nxt])
      if c.online == 1 then applyRole(c.name) end   -- make the bot actually that role now
      cprint(c.name .. " is now " .. nxt ..
        (c.online == 1 and " (applied)" or " — invite it to apply") .. ".")
    end)

    row.fav:SetChecked(isFav(c.name) and true or false)
    row.fav:SetScript("OnClick", function(self) self:SetChecked(toggleFav(c.name) == true) end)

    row.act:SetText(c.online == 1 and "Dismiss" or "Invite")
    row.act:SetScript("OnClick", function()
      -- Server enforces the max-out cap (across all accounts) and messages you if exceeded.
      if c.online == 1 then rpc("D:" .. c.name)
      else local nm = c.name; rpc("I:" .. nm); after(3, function() applyRoleIfSpecial(nm) end) end
      after(1.3, refresh)
    end)

    if c.online == 1 then row.spec:Enable() else row.spec:Disable() end
    row.spec:SetScript("OnClick", function()
      if c.online ~= 1 then cprint("Invite " .. c.name .. " first, then set its spec.") return end
      local menu = { { text = c.name .. " — spec (sets role)", isTitle = true, notCheckable = true } }
      for _, s in ipairs(SPECS[c.cls] or {}) do
        menu[#menu + 1] = { text = s, notCheckable = true, func = function()
          whisperSpec(c.name, s)
          local r = roleFromSpec(s); setRole(c.name, r, true); row.role:SetText(ROLE_TXT[r])
          if c.online == 1 then applyRole(c.name) end
          cprint(c.name .. " -> " .. s .. "  |cff888888(role: " .. r .. ")|r")
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
  frame:SetSize(360, 566)
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

  -- ---- Divider + roster header + class filter --------------------------
  local hdr = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdr:SetPoint("TOPLEFT", 20, -120); hdr:SetText("Bench:")

  local FILTERS = {
    {id=0,n="Out (active)"}, {id=1,n="Warrior"}, {id=2,n="Paladin"}, {id=3,n="Hunter"}, {id=4,n="Rogue"},
    {id=5,n="Priest"}, {id=6,n="Death Knight"}, {id=7,n="Shaman"}, {id=8,n="Mage"}, {id=9,n="Warlock"}, {id=11,n="Druid"},
  }
  local filterDD = CreateFrame("Frame", "CompanionPartyFilterDD", frame, "UIDropDownMenuTemplate")
  filterDD:SetPoint("TOPLEFT", 44, -114)
  UIDropDownMenu_SetWidth(filterDD, 110)
  UIDropDownMenu_Initialize(filterDD, function()
    for _, f in ipairs(FILTERS) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = f.n
      info.func = function() selFilter = f.id; UIDropDownMenu_SetText(filterDD, f.n); refresh() end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetText(filterDD, "Warrior")

  frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.count:SetPoint("TOPRIGHT", -20, -124)

  frame.listAnchor = CreateFrame("Frame", nil, frame)
  frame.listAnchor:SetSize(320, 1); frame.listAnchor:SetPoint("TOPLEFT", 20, -150)

  frame.specMenu = CreateFrame("Frame", "CompanionPartySpecMenu", UIParent, "UIDropDownMenuTemplate")

  -- ---- Footer: one-click favorite party + management -------------------
  local favBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  favBtn:SetSize(200, 26); favBtn:SetPoint("BOTTOM", 0, 46); favBtn:SetText("Invite Favorite Party")
  favBtn:SetScript("OnClick", inviteFavorites)
  favBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Invite Favorite Party")
    GameTooltip:AddLine("Summons the (up to " .. MAX_ACTIVE .. ") companions you checked as favorites.", .8,.8,.8, true)
    GameTooltip:Show()
  end)
  favBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local macroBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  macroBtn:SetSize(150, 22); macroBtn:SetPoint("BOTTOM", 0, 76); macroBtn:SetText("Example macros")
  macroBtn:SetScript("OnClick", makeExampleMacros)
  macroBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Make example macros")
    GameTooltip:AddLine("Adds base macros (Assist, TankPull, HealMe + combos) to your list to copy from.", .8,.8,.8, true)
    GameTooltip:Show()
  end)
  macroBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local dismissAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  dismissAll:SetSize(96, 22); dismissAll:SetPoint("BOTTOMLEFT", 20, 16); dismissAll:SetText("Dismiss all")
  dismissAll:SetScript("OnClick", function() rpc("X"); after(1.2, refresh) end)

  local applyRolesBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  applyRolesBtn:SetSize(104, 22); applyRolesBtn:SetPoint("BOTTOM", 0, 16); applyRolesBtn:SetText("Apply Roles")
  applyRolesBtn:SetScript("OnClick", applyAllRoles)
  applyRolesBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Apply Roles")
    GameTooltip:AddLine("Re-push tank/heal/dps strategy to every companion that's out.", .8,.8,.8, true)
    GameTooltip:Show()
  end)
  applyRolesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local refreshBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  refreshBtn:SetSize(84, 22); refreshBtn:SetPoint("BOTTOMRIGHT", -20, 16); refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", refresh)
end

------------------------------------------------------------- COMMAND BAR ------
-- A movable order bar (the "totem bar"). Role buttons resolve to whoever holds
-- that role right now; the rest broadcast to the whole party. All combat-safe.
local BAR_BTNS = {
  { t="Assist", tip="All companions attack your current target",   fn=function() cmdAll("attack") end },
  { t="Tank",   tip="Your tank engages/pulls your target",         fn=function() cmdRole("TANK", "tank attack") end },
  { t="Heal",   tip="Your healer prioritizes healing you",         fn=function() cmdRole("HEAL", "focus heal +" .. UnitName("player")) end },
  { t="DPS",    tip="All DPS companions attack your target",        fn=function() cmdRole("DPS", "attack") end },
  { t="Follow", tip="Everyone follows you",                         fn=function() cmdAll("follow") end },
  { t="Stay",   tip="Everyone holds position",                      fn=function() cmdAll("stay") end },
  { t="Come",   tip="Teleport companions to you",                   fn=function() cmdAll("summon") end },
  { t="Defend", tip="Everyone steps out of ground AoE",             fn=function() cmdAll("co +avoid aoe") end },
  { t="Loot",   tip="Everyone loots nearby",                        fn=function() cmdAll("add all loot") end },
  { t="Rez",    tip="Revive fallen companions",                     fn=function() cmdAll("revive") end },
}

local function buildBar()
  if bar then return end
  local n = #BAR_BTNS
  bar = CreateFrame("Frame", "CompanionBar", UIParent)
  bar:SetSize(10 + n * 52, 40)
  bar:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  bar:SetMovable(true); bar:EnableMouse(true); bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", bar.StartMoving)
  bar:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    CompanionPartyDB.bar = CompanionPartyDB.bar or {}
    CompanionPartyDB.bar.p, CompanionPartyDB.bar.rp, CompanionPartyDB.bar.x, CompanionPartyDB.bar.y = p, rp, x, y
  end)
  bar:SetClampedToScreen(true)
  local sv = CompanionPartyDB.bar or {}
  bar:SetPoint(sv.p or "CENTER", UIParent, sv.rp or "CENTER", sv.x or 0, sv.y or -160)

  local lbl = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  lbl:SetPoint("BOTTOM", 0, -13); lbl:SetText("Companion orders — drag to move · /cp bar to hide")

  for i, b in ipairs(BAR_BTNS) do
    local btn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    btn:SetSize(48, 26); btn:SetPoint("LEFT", 6 + (i - 1) * 52, 0)
    btn:SetText(b.t); btn:SetScript("OnClick", b.fn)
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(b.t); GameTooltip:AddLine(b.tip, .8, .8, .8, true); GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
end

local function toggleBar()
  buildBar()
  CompanionPartyDB.bar = CompanionPartyDB.bar or {}
  if bar:IsShown() then bar:Hide(); CompanionPartyDB.bar.shown = false
  else bar:Show(); CompanionPartyDB.bar.shown = true end
end

local function toggle()
  buildFrame()
  if frame:IsShown() then frame:Hide() else frame:Show(); refresh() end
end

------------------------------------------------------------------- EVENTS -----
local function onMessage(message)
  local fcls, body = message:match("^R|(%d+)|(.*)$")
  if not fcls then return end
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
    CompanionPartyDB.roles = CompanionPartyDB.roles or {}
    CompanionPartyDB.primary = CompanionPartyDB.primary or {}
    CompanionPartyDB.favorites = CompanionPartyDB.favorites or {}
    CompanionPartyDB.bar = CompanionPartyDB.bar or { shown = true }
    buildBar()
    if CompanionPartyDB.bar.shown == false then bar:Hide() else bar:Show() end
    cprint("loaded. |cffffff00/cp|r panel · |cffffff00/cp bar|r order bar · roles: |cffffff00/ct /ch /cd|r <cmd>.")
  end
end)

SLASH_COMPANIONPARTY1 = "/cp"
SLASH_COMPANIONPARTY2 = "/companion"
SLASH_COMPANIONPARTY3 = "/companions"
SlashCmdList["COMPANIONPARTY"] = function(msg)
  msg = string.lower(msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "bar" then toggleBar() else toggle() end
end

-- Role-addressed orders: address the ROLE, whoever holds it acts.
--   /ct <cmd>  -> your primary tank      e.g.  /ct tank attack   /ct summon
--   /ch <cmd>  -> your primary healer    e.g.  /ch focus heal +Zeackhunter
--   /cd <cmd>  -> ALL dps that are out   e.g.  /cd attack
SLASH_CPTANK1 = "/ct"; SlashCmdList["CPTANK"] = function(m) cmdRole("TANK", (m or ""):gsub("^%s+", "")) end
SLASH_CPHEAL1 = "/ch"; SlashCmdList["CPHEAL"] = function(m) cmdRole("HEAL", (m or ""):gsub("^%s+", "")) end
SLASH_CPDPS1  = "/cd"; SlashCmdList["CPDPS"]  = function(m) cmdRole("DPS",  (m or ""):gsub("^%s+", "")) end
