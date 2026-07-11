--[[============================================================================
  SkillTrainerUI  —  WotLK 3.3.5a client addon (v3, docs/skill-leveling-v3-spec.md §5).

  Replaces the native class-trainer window with a TWO-TAB frame:
    Tab 1 "Skill Levels" — the infinite v3 level track for damage + heal skills:
        level / cap, next-level cost, the curve ladder (+1 per level, +10% spike
        every 10th), buy / buy-to-cap. Server RPC (prefix SKILLTR).
    Tab 2 "Training"     — the VANILLA trainer: every spell + rank the trainer
        sells, native API (GetTrainerServiceInfo / BuyTrainerService), restyled.
        Only usable while a trainer is actually open.

  Server messages: REQ / INFO:<id> / BUY:<id> / BUYMAX:<id>  ->
  BEGIN/ROWS/END + IBEGIN/IMETA/IBONUS/IEND (v3: no milestone IROW/ILOOP).

  Install: copy this folder to  <WoW 3.3.5a>\Interface\AddOns\SkillTrainerUI\
============================================================================]]--

local PREFIX = "SKILLTR"

-- DB[id] = { lvl, cap, cost, unlock, known, talent, bonusText, cat }
local DB
local ORDER = {}
local pending = nil
local infoBuf = nil
local selectedId = nil
local filterMode = "all"
local mode = "levels"          -- "levels" | "ranks"
local atTrainer = false
local selectedSvc = nil

local FILTERS = {
  { t = "All skills", v = "all" },
  { t = "Upgradable", v = "up" },
  { t = "At cap",     v = "cap" },
  { t = "Locked",     v = "locked" },
}

local function rpc(msg) SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player")) end

local function stateOf(d)
  if not d then return "locked" end
  if d.known == 0 then return "locked" end
  if d.lvl >= d.cap then return "cap" end
  return "up"
end

local function unlockText(d)
  if d.talent == 1 then return "Unlocked via talent" end
  if d.unlock and d.unlock > 0 then return "Trains at level " .. d.unlock end
  return "Not yet learned"
end

-- real spell description via a hidden tooltip scan (works for unknown spells too).
local scanTip = CreateFrame("GameTooltip", "SkillTrainerUIScan", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")
local function spellDesc(id)
  scanTip:ClearLines(); scanTip:SetHyperlink("spell:" .. id)
  local desc = ""
  for i = 2, scanTip:NumLines() do
    local fs = _G["SkillTrainerUIScanTextLeft" .. i]
    local s = fs and fs:GetText()
    if s and s ~= "" and not s:find("^Rank ") then desc = s end
  end
  return desc
end

-- v3 curve — MUST match SkillCurve in mod-skilllevel/SkillMilestones.h:
--   final = (D + 1*(L-1)) * (1 + 0.10*floor(L/10))
local SL_FLAT_PER_LEVEL = 1
local SL_SPIKE_PER_10   = 0.10

-- What a given LEVEL grants. Every 10th level is the +10% spike (milestone-styled).
local function levelEffect(d, L)
  local noun = (d and (d.isHeal or d.cat == "H")) and "healing" or "damage"
  if L % 10 == 0 then
    return "+10% " .. noun .. "  — spike!", true
  end
  return "+" .. SL_FLAT_PER_LEVEL .. " " .. noun, false
end

-- Rewrite the damage numbers in a description string to the v3-scaled values:
-- ranges scale both ends; DoT "over N sec" totals get the multiplier only (no
-- flat); direct numbers get flat + multiplier.
local function scaleDesc(txt, lvl)
  if not txt or lvl <= 1 then return txt end
  local mult = 1 + SL_SPIKE_PER_10 * math.floor(lvl / 10)
  local flat = SL_FLAT_PER_LEVEL * (lvl - 1)
  local isDoT = txt:find("over %d") ~= nil
  local function full(n) local v = tonumber(n); if not v then return n end
    return tostring(math.floor((v + (isDoT and 0 or flat)) * mult + 0.5)) end
  local newtxt, c = txt:gsub("(%d+)(%s+to%s+)(%d+)([%a%s]-damage)",
    function(a, m, b, t) return full(a) .. m .. full(b) .. t end)
  if c == 0 then
    newtxt = newtxt:gsub("(%d+)([%a%s]-damage)", function(n, t) return full(n) .. t end)
  end
  newtxt = newtxt:gsub("(damage by )(%d+)", function(p, n) return p .. full(n) end)
  return newtxt
end

--=============================== frame build ===============================--
local ROWH, NUMROWS = 34, 12
local LINEH, LROWS  = 14, 14
local frame, scroll, rows, dd, moneyFS, ladderScroll, ladderLines
local selName, selLevel, selDesc, selBonus, selCost, selIcon, upBtn, capBtn
local tab1, tab2, upTitle
local parkNative, restoreNative   -- forward-declared: buildFrame's close button captures restoreNative

local function filtered()
  local out = {}
  for _, id in ipairs(ORDER) do
    local d = DB[id]
    if d and (filterMode == "all" or filterMode == stateOf(d)) then out[#out + 1] = id end
  end
  return out
end

--============================ Tab 2: vanilla services ======================--
-- svc list rebuilt from the native trainer API each update (headers included).
local svcList = {}   -- { {idx=, name=, rank=, cat=, icon=, cost=, req=} | {header=name} }

local function rebuildServices()
  svcList = {}
  if not atTrainer then return end
  local n = GetNumTrainerServices() or 0
  for i = 1, n do
    local name, rank, category = GetTrainerServiceInfo(i)
    if category == "header" then
      svcList[#svcList + 1] = { header = name or "" }
    elseif name then
      svcList[#svcList + 1] = {
        idx  = i, name = name, rank = rank or "", cat = category,
        icon = GetTrainerServiceIcon(i),
        cost = (GetTrainerServiceCost(i)) or 0,
        req  = (GetTrainerServiceLevelReq and GetTrainerServiceLevelReq(i)) or 0,
      }
    end
  end
end

local function svcDesc(idx)
  scanTip:ClearLines(); scanTip:SetTrainerService(idx)
  local desc = ""
  for i = 2, scanTip:NumLines() do
    local fs = _G["SkillTrainerUIScanTextLeft" .. i]
    local s = fs and fs:GetText()
    if s and s ~= "" and not s:find("^Rank ") then desc = s end
  end
  return desc
end

--=============================== ladder (tab 1) ============================--
local function updateLadder()
  if not ladderScroll then return end
  if mode ~= "levels" then FauxScrollFrame_Update(ladderScroll, 0, LROWS, LINEH); return end
  local d = selectedId and DB[selectedId]
  local lvl = (d and d.lvl) or 1
  local cap = (d and d.cap) or 1
  local numLevels = math.max(0, lvl)          -- ladder = levels 2..lvl+1: earned + the next
  local offset = FauxScrollFrame_GetOffset(ladderScroll)
  for i = 1, LROWS do
    local fs = ladderLines[i]
    local idx = offset + i
    local L = idx + 1
    if d and mode == "levels" and idx <= numLevels then
      local text, isM = levelEffect(d, L)
      if L <= lvl then
        local c = isM and "ffd100" or "bfe8bf"
        fs:SetText("|cff40dd66Lv " .. L .. "|r  |cff" .. c .. text .. "|r")                          -- earned
      elseif L > cap then
        fs:SetText("|cffbb99ee\194\187 Lv " .. L .. "  " .. text .. "   (raise cap to reach)|r")     -- next, beyond cap
      elseif d.known == 1 then
        fs:SetText("|cffffd100\194\187 Lv " .. L .. "|r  |cffffe680" .. text .. "  (next)|r")        -- next, buyable
      else
        local c = isM and "d0c060" or "999999"
        fs:SetText("|cff" .. c .. "\194\187 Lv " .. L .. "  " .. text .. "|r")                       -- next, unlearned
      end
      fs:Show()
    else
      fs:SetText(""); fs:Hide()
    end
  end
  FauxScrollFrame_Update(ladderScroll, mode == "levels" and numLevels or 0, LROWS, LINEH)
end

local function ladderFocusCurrent()
  local d = selectedId and DB[selectedId]
  if not d then return end
  local sb = _G["SkillTrainerUILadderScrollBar"]
  local idx = math.max(0, (d.lvl or 1) - 1 - 4)
  if sb then sb:SetValue(idx * LINEH) end
  updateLadder()
end

--=============================== detail pane ===============================--
local function updateDetail()
  if not selName then return end

  if mode == "ranks" then
    upTitle:SetText("")
    local s = selectedSvc and svcList[selectedSvc]
    if not s or s.header then
      selName:SetText("Select a spell"); selLevel:SetText(""); selDesc:SetText("")
      selBonus:SetText(""); selCost:SetText(""); selIcon:SetTexture(nil)
      upBtn:Disable(); capBtn:Hide(); updateLadder(); return
    end
    selIcon:SetTexture(s.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    selName:SetText(s.name .. (s.rank ~= "" and ("  |cffb0b0b0(" .. s.rank .. ")|r") or ""))
    selLevel:SetText(s.req > 0 and ("|cffffffffRequires level " .. s.req .. "|r") or "")
    selDesc:SetText(svcDesc(s.idx))
    selBonus:SetText("")
    capBtn:Hide()
    upBtn:SetText("Train")
    if s.cat == "available" then
      selCost:SetText("Cost:  " .. GetCoinTextureString(s.cost))
      if GetMoney() >= s.cost then upBtn:Enable() else upBtn:Disable() end
    elseif s.cat == "used" then
      selCost:SetText("|cff40dd66Already known|r"); upBtn:Disable()
    else
      selCost:SetText("|cffbb6666Requirements not met|r"); upBtn:Disable()
    end
    updateLadder(); return
  end

  upTitle:SetText("|cffffd100Level track|r  |cff777777(+1 per level, +10% every 10th)|r")
  upBtn:SetText("Upgrade"); capBtn:Show()
  local id = selectedId
  local d = id and DB[id]
  if not d then
    selName:SetText("Select a skill"); selLevel:SetText(""); selDesc:SetText("")
    selBonus:SetText(""); selCost:SetText(""); selIcon:SetTexture(nil)
    upBtn:Disable(); capBtn:Disable(); updateLadder(); return
  end
  local name, _, icon = GetSpellInfo(id)
  selIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  selName:SetText(name or ("Spell " .. id))
  selLevel:SetText("|cffffffffLevel " .. d.lvl .. "|r  /  cap " .. d.cap)
  local desc = spellDesc(id) or ""
  if not d.isHeal then desc = scaleDesc(desc, d.lvl or 1) end
  selDesc:SetText(desc)
  if d.bonusText and d.bonusText ~= "" then
    selBonus:SetText("|cff00dd00At level " .. d.lvl .. ":  " .. d.bonusText .. " from skill leveling|r")
  else selBonus:SetText("") end
  local st = stateOf(d)
  if st == "locked" then
    selCost:SetText("|cffbb66ff" .. unlockText(d) .. "|r")
    upBtn:Disable(); capBtn:Disable()
  elseif st == "cap" then
    selCost:SetText("|cffcccc66At cap — manually level to raise it|r")
    upBtn:Disable(); capBtn:Disable()
  else
    selCost:SetText("Next level:  " .. GetCoinTextureString(d.cost))
    capBtn:Enable()
    if GetMoney() >= d.cost then upBtn:Enable() else upBtn:Disable() end
  end
  updateLadder()
end

--=============================== list (both tabs) ==========================--
local function updateList()
  if not scroll then return end

  if mode == "ranks" then
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i = 1, NUMROWS do
      local row = rows[i]
      local s = svcList[i + offset]
      if s then
        row.id = nil; row.svc = i + offset
        if s.header then
          row.icon:SetTexture(nil)
          row.name:SetText(s.header); row.name:SetTextColor(1, 0.82, 0)
          row.info:SetText(""); row.cost:SetText("")
          row.sel:Hide()
        else
          row.icon:SetTexture(s.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
          row.name:SetText(s.name .. (s.rank ~= "" and ("  |cff909090" .. s.rank .. "|r") or ""))
          if s.cat == "available" then row.name:SetTextColor(0.3, 0.85, 0.45)
          elseif s.cat == "used" then row.name:SetTextColor(0.55, 0.55, 0.55)
          else row.name:SetTextColor(0.75, 0.32, 0.32) end
          row.info:SetText(s.req > 0 and ("Requires level " .. s.req) or "")
          row.info:SetTextColor(0.65, 0.65, 0.65)
          row.cost:SetText(s.cat == "available" and GetCoinTextureString(s.cost) or "")
          if row.svc == selectedSvc then row.sel:Show() else row.sel:Hide() end
        end
        row:Show()
      else
        row.id = nil; row.svc = nil; row:Hide()
      end
    end
    FauxScrollFrame_Update(scroll, #svcList, NUMROWS, ROWH)
    return
  end

  local list = filtered()
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, NUMROWS do
    local row = rows[i]
    local id = list[i + offset]
    row.svc = nil
    if id then
      local d = DB[id]
      local name, _, icon = GetSpellInfo(id)
      row.id = id
      row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetText(name or ("Spell " .. id))
      local st = stateOf(d)
      if st == "locked" then
        row.name:SetTextColor(d.talent == 1 and 0.72 or 0.55, d.talent == 1 and 0.5 or 0.55, d.talent == 1 and 0.95 or 0.55)
        row.info:SetText(unlockText(d))
        if d.talent == 1 then row.info:SetTextColor(0.66, 0.45, 0.9) else row.info:SetTextColor(0.75, 0.32, 0.32) end
        row.cost:SetText("")
      elseif st == "cap" then
        row.name:SetTextColor(1, 0.82, 0)
        row.info:SetText("Level " .. d.lvl .. " / " .. d.cap .. "  (at cap)")
        row.info:SetTextColor(0.65, 0.65, 0.65); row.cost:SetText("")
      else
        row.name:SetTextColor(1, 0.82, 0)
        row.info:SetText("Level " .. d.lvl .. " / " .. d.cap)
        row.info:SetTextColor(0.3, 0.85, 0.45)
        row.cost:SetText(GetCoinTextureString(d.cost))
      end
      if id == selectedId then row.sel:Show() else row.sel:Hide() end
      row:Show()
    else
      row.id = nil; row:Hide()
    end
  end
  FauxScrollFrame_Update(scroll, #list, NUMROWS, ROWH)
end

local function render()
  if not frame then return end
  if moneyFS then moneyFS:SetText(GetCoinTextureString(GetMoney())) end
  if dd then if mode == "levels" then dd:Show() else dd:Hide() end end
  updateList(); updateDetail()
end

local function selectSkill(id)
  selectedId = id
  rpc("INFO:" .. id)
  updateList(); updateDetail()
end

local function selectService(i)
  selectedSvc = i
  updateList(); updateDetail()
end

local function setMode(m)
  mode = m
  if tab1 and tab2 then
    if m == "levels" then PanelTemplates_SelectTab(tab1); PanelTemplates_DeselectTab(tab2)
    else PanelTemplates_SelectTab(tab2); PanelTemplates_DeselectTab(tab1) end
  end
  local sb = _G["SkillTrainerUIScrollScrollBar"]; if sb then sb:SetValue(0) end
  if m == "ranks" then rebuildServices() end
  render()
end

local function buildFrame()
  if frame then return end

  frame = CreateFrame("Frame", "SkillTrainerUIFrame", UIParent)
  frame:SetWidth(700); frame:SetHeight(560); frame:SetPoint("CENTER"); frame:SetFrameStrata("HIGH")
  frame:SetBackdrop({ edgeFile = "Interface/DialogFrame/UI-DialogBox-Border", edgeSize = 28 })
  frame:SetBackdropBorderColor(1, 1, 1, 1)
  frame:EnableMouse(true); frame:SetMovable(true); frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()

  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(0.07, 0.05, 0.035, 1)
  bg:SetPoint("TOPLEFT", 7, -7); bg:SetPoint("BOTTOMRIGHT", -7, 7)
  local parch = frame:CreateTexture(nil, "BORDER")
  parch:SetTexture("Interface/QuestFrame/QuestBackground"); parch:SetAllPoints(bg); parch:SetAlpha(0.45)

  local header = frame:CreateTexture(nil, "ARTWORK")
  header:SetTexture("Interface/DialogFrame/UI-DialogBox-Header")
  header:SetWidth(340); header:SetHeight(64); header:SetPoint("TOP", 0, 12)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", header, "TOP", 0, -14); title:SetText("Skill Trainer")

  local pf = CreateFrame("Frame", nil, frame)
  pf:SetWidth(58); pf:SetHeight(58); pf:SetPoint("TOPLEFT", 16, -16)
  pf:SetBackdrop({ edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = 14 })
  pf:SetBackdropBorderColor(0.75, 0.62, 0.35, 1)
  local portrait = pf:CreateTexture(nil, "ARTWORK")
  portrait:SetPoint("TOPLEFT", 4, -4); portrait:SetPoint("BOTTOMRIGHT", -4, 4)
  portrait:SetTexCoord(0.14, 0.86, 0.14, 0.86)
  frame.portrait = portrait
  local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("LEFT", pf, "RIGHT", 10, 6); sub:SetText(""); frame.sub = sub

  local flabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  flabel:SetPoint("LEFT", pf, "RIGHT", 14, -12); flabel:SetText("Show")
  dd = CreateFrame("Frame", "SkillTrainerUIFilter", frame, "UIDropDownMenuTemplate")
  dd:SetPoint("LEFT", flabel, "RIGHT", -6, -2)
  UIDropDownMenu_Initialize(dd, function(self, level)
    for _, f in ipairs(FILTERS) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = f.t; info.value = f.v; info.checked = (filterMode == f.v)
      info.func = function(b) filterMode = b.value; UIDropDownMenu_SetSelectedValue(dd, b.value); updateList() end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(dd, 110); UIDropDownMenu_SetSelectedValue(dd, filterMode)

  local mlabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  mlabel:SetPoint("BOTTOMLEFT", 26, 40); mlabel:SetText("|cffb0b0b0Your money|r")
  moneyFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  moneyFS:SetPoint("BOTTOMLEFT", 26, 22)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)
  close:SetScript("OnClick", function() frame:Hide(); restoreNative() end)

  -- bottom tabs
  tab1 = CreateFrame("Button", "SkillTrainerUIFrameTab1", frame, "CharacterFrameTabButtonTemplate")
  tab1:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, -28)
  tab1:SetText("Skill Levels"); tab1:SetID(1)
  tab1:SetScript("OnClick", function() setMode("levels") end)
  tab2 = CreateFrame("Button", "SkillTrainerUIFrameTab2", frame, "CharacterFrameTabButtonTemplate")
  tab2:SetPoint("LEFT", tab1, "RIGHT", -14, 0)
  tab2:SetText("Training"); tab2:SetID(2)
  tab2:SetScript("OnClick", function() setMode("ranks") end)
  PanelTemplates_TabResize(tab1, 0); PanelTemplates_TabResize(tab2, 0)
  PanelTemplates_SelectTab(tab1); PanelTemplates_DeselectTab(tab2)

  -- list (left)
  scroll = CreateFrame("ScrollFrame", "SkillTrainerUIScroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 22, -88); scroll:SetWidth(292); scroll:SetHeight(NUMROWS * ROWH)
  scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROWH, updateList) end)
  rows = {}
  for i = 1, NUMROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetWidth(290); row:SetHeight(ROWH)
    if i == 1 then row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    else row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0) end
    row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
    local hl = row:GetHighlightTexture(); if hl then hl:SetAlpha(0.4) end
    local sel = row:CreateTexture(nil, "BACKGROUND")
    sel:SetAllPoints(row); sel:SetTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
    sel:SetAlpha(0.6); sel:Hide(); row.sel = sel
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(28); icon:SetHeight(28); icon:SetPoint("LEFT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); row.icon = icon
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 0); name:SetJustifyH("LEFT"); row.name = name
    local info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, 0); info:SetJustifyH("LEFT"); row.info = info
    local cost = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cost:SetPoint("RIGHT", -6, 0); cost:SetJustifyH("RIGHT"); row.cost = cost
    row:SetScript("OnClick", function(self)
      if self.svc then
        local s = svcList[self.svc]
        if s and not s.header then selectService(self.svc) end
      elseif self.id then selectSkill(self.id) end
    end)
    rows[i] = row
  end

  -- detail pane (right)
  local pane = CreateFrame("Frame", nil, frame)
  pane:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 26, 8); pane:SetPoint("BOTTOMRIGHT", -20, 50)
  pane:SetBackdrop({ edgeFile = "Interface/Tooltips/UI-Tooltip-Border", edgeSize = 14 })
  pane:SetBackdropBorderColor(0.7, 0.58, 0.32, 0.9)
  local pbg = pane:CreateTexture(nil, "BACKGROUND")
  pbg:SetTexture(0.03, 0.025, 0.02, 0.92); pbg:SetPoint("TOPLEFT", 3, -3); pbg:SetPoint("BOTTOMRIGHT", -3, 3)

  selIcon = pane:CreateTexture(nil, "ARTWORK")
  selIcon:SetWidth(38); selIcon:SetHeight(38); selIcon:SetPoint("TOPLEFT", 14, -12)
  selIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  selName = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  selName:SetPoint("TOPLEFT", selIcon, "TOPRIGHT", 12, -1); selName:SetJustifyH("LEFT")
  selLevel = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  selLevel:SetPoint("TOPLEFT", selIcon, "TOPRIGHT", 12, -21); selLevel:SetJustifyH("LEFT")

  local div = pane:CreateTexture(nil, "ARTWORK")
  div:SetTexture(0.6, 0.5, 0.3, 0.55); div:SetHeight(2)
  div:SetPoint("TOPLEFT", 12, -56); div:SetPoint("TOPRIGHT", -12, -56)

  selDesc = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  selDesc:SetPoint("TOPLEFT", 14, -64); selDesc:SetPoint("RIGHT", pane, "RIGHT", -14, 0)
  selDesc:SetJustifyH("LEFT"); selDesc:SetJustifyV("TOP"); selDesc:SetHeight(40)

  selBonus = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  selBonus:SetPoint("TOPLEFT", 14, -106); selBonus:SetPoint("RIGHT", pane, "RIGHT", -14, 0)
  selBonus:SetJustifyH("LEFT")

  upTitle = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  upTitle:SetPoint("TOPLEFT", 14, -126)
  upTitle:SetText("|cffffd100Level track|r  |cff777777(+1 per level, +10% every 10th)|r")
  local div2 = pane:CreateTexture(nil, "ARTWORK")
  div2:SetTexture(0.6, 0.5, 0.3, 0.4); div2:SetHeight(1)
  div2:SetPoint("TOPLEFT", 12, -140); div2:SetPoint("TOPRIGHT", -12, -140)

  -- infinite, scrollable curve ladder
  ladderScroll = CreateFrame("ScrollFrame", "SkillTrainerUILadder", pane, "FauxScrollFrameTemplate")
  ladderScroll:SetPoint("TOPLEFT", 14, -146)
  ladderScroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -28, 74)
  ladderScroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, LINEH, updateLadder) end)
  ladderLines = {}
  for i = 1, LROWS do
    local fs = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if i == 1 then fs:SetPoint("TOPLEFT", ladderScroll, "TOPLEFT", 2, 0)
    else fs:SetPoint("TOPLEFT", ladderLines[i - 1], "BOTTOMLEFT", 0, -1) end
    fs:SetPoint("RIGHT", ladderScroll, "RIGHT", -2, 0); fs:SetJustifyH("LEFT")
    ladderLines[i] = fs
  end

  selCost = pane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  selCost:SetPoint("BOTTOMLEFT", 14, 48); selCost:SetPoint("RIGHT", pane, "RIGHT", -14, 0); selCost:SetJustifyH("LEFT")

  upBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
  upBtn:SetWidth(118); upBtn:SetHeight(24); upBtn:SetPoint("BOTTOMLEFT", 14, 14); upBtn:SetText("Upgrade")
  upBtn:SetScript("OnClick", function()
    if mode == "ranks" then
      local s = selectedSvc and svcList[selectedSvc]
      if s and s.idx then BuyTrainerService(s.idx) end
    elseif selectedId then rpc("BUY:" .. selectedId) end
  end)
  capBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
  capBtn:SetWidth(118); capBtn:SetHeight(24); capBtn:SetPoint("BOTTOMRIGHT", -14, 14); capBtn:SetText("Buy to cap")
  capBtn:SetScript("OnClick", function() if selectedId then rpc("BUYMAX:" .. selectedId) end end)

  frame.pane = pane
end

--============================ native trainer swap ==========================--
-- Park Blizzard's ClassTrainerFrame instead of hiding it. CRITICAL: its OnHide
-- runs CloseTrainer(), which ENDS the trainer session — and the Training tab reads
-- that session (GetNumTrainerServices). HideUIPanel here made every service vanish.
-- So keep it SHOWN (session alive) but off-screen + click-through.
function parkNative()
  if LoadAddOn then LoadAddOn("Blizzard_TrainerUI") end
  local f = ClassTrainerFrame
  if not f then return end
  if not f:IsShown() and ShowUIPanel then ShowUIPanel(f) end
  f:SetAlpha(0)
  f:EnableMouse(false)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -6000, 0)
end

-- Undo the park and let it close the session (its OnHide -> CloseTrainer).
function restoreNative()
  local f = ClassTrainerFrame
  if not f then return end
  f:SetAlpha(1)
  f:EnableMouse(true)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
  if f:IsShown() and HideUIPanel then HideUIPanel(f) end   -- fires CloseTrainer()
end

--============================ addon message parse ==========================--
local function onMessage(msg)
  if msg == "BEGIN" then pending = {}; return end
  if msg == "END" then
    ORDER = pending or ORDER; pending = nil
    if (selectedId == nil or DB[selectedId] == nil) and ORDER[1] then selectSkill(ORDER[1]) end
    render(); return
  end
  if strsub(msg, 1, 5) == "ROWS|" then
    for entry in string.gmatch(strsub(msg, 6), "[^,]+") do
      local cat  = strsub(entry, 1, 1)   -- H heal / D damage
      local body = strsub(entry, 2)
      local id, lvl, cap, cost, unlock, known, talent =
        string.match(body, "(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)")
      id = tonumber(id)
      if id then
        local d = DB[id] or {}
        d.lvl = tonumber(lvl); d.cap = tonumber(cap); d.cost = tonumber(cost)
        d.unlock = tonumber(unlock); d.known = tonumber(known); d.talent = tonumber(talent)
        d.isHeal = (cat == "H"); d.cat = cat
        DB[id] = d
        if pending then pending[#pending + 1] = id end
      end
    end
    return
  end
  if strsub(msg, 1, 7) == "IBEGIN|" then infoBuf = { id = tonumber(strsub(msg, 8)) }; return end
  if strsub(msg, 1, 6) == "IMETA|" then
    local id, _, _, tal, cat = string.match(msg, "IMETA|(%d+)|(%d+)|(%d+)|(%d+)|?(%a*)")
    id = tonumber(id)
    if id and infoBuf and infoBuf.id == id then
      infoBuf.talent = tonumber(tal)
      if cat and cat ~= "" then infoBuf.cat = cat end
    end
    return
  end
  if strsub(msg, 1, 7) == "IBONUS|" then
    local id, b = string.match(msg, "IBONUS|(%d+)|(.*)")
    id = tonumber(id); if id then DB[id] = DB[id] or {}; DB[id].bonusText = b or "" end
    return
  end
  if strsub(msg, 1, 5) == "IEND|" then
    local id = tonumber(strsub(msg, 6))
    if infoBuf and infoBuf.id == id then
      local d = DB[id] or {}
      if infoBuf.talent then d.talent = infoBuf.talent end
      if infoBuf.cat then d.cat = infoBuf.cat; d.isHeal = (infoBuf.cat == "H") end
      DB[id] = d; infoBuf = nil
      if id == selectedId then updateDetail(); ladderFocusCurrent() end
    end
    return
  end
end

--================================ events ===================================--
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED"); ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("TRAINER_SHOW"); ev:RegisterEvent("TRAINER_CLOSED"); ev:RegisterEvent("TRAINER_UPDATE")
ev:RegisterEvent("PLAYER_MONEY")
ev:SetScript("OnEvent", function(self, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, message = ...
    if prefix == PREFIX then onMessage(message) end
  elseif event == "ADDON_LOADED" then
    if ... == "SkillTrainerUI" then
      SkillTrainerUIDB = SkillTrainerUIDB or {}
      DB = SkillTrainerUIDB
      for _, d in pairs(DB) do d.sig = nil; d.loop = nil end   -- v2 milestone leftovers
      buildFrame()
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SkillTrainerUI|r loaded. Talk to your class trainer, or |cffffff00/skilltrainer|r to open.")
    end
  elseif event == "TRAINER_SHOW" then
    if IsTradeskillTrainer and IsTradeskillTrainer() then return end
    atTrainer = true
    buildFrame()
    frame.sub:SetText("|cffffd100" .. (UnitName("npc") or "") .. "|r")
    if SetPortraitTexture then SetPortraitTexture(frame.portrait, "npc") end
    -- show every service category in tab 2
    if SetTrainerServiceTypeFilter then
      SetTrainerServiceTypeFilter("available", 1)
      SetTrainerServiceTypeFilter("unavailable", 1)
      SetTrainerServiceTypeFilter("used", 1)
    end
    parkNative(); frame:Show(); rpc("REQ")
    rebuildServices(); render()
  elseif event == "TRAINER_UPDATE" then
    if atTrainer then rebuildServices(); if frame and frame:IsShown() then render() end end
  elseif event == "TRAINER_CLOSED" then
    -- The session really ended (walked away / Esc / bought-out). Close our window too.
    atTrainer = false; svcList = {}; selectedSvc = nil
    if frame then frame:Hide() end
  elseif event == "PLAYER_MONEY" then
    if frame and frame:IsShown() then render() end
  end
end)

SLASH_SKILLTRAINER1 = "/skilltrainer"
SLASH_SKILLTRAINER2 = "/str"
SlashCmdList["SKILLTRAINER"] = function()
  buildFrame()
  if frame:IsShown() then frame:Hide()
  else
    if SetPortraitTexture then SetPortraitTexture(frame.portrait, "player") end
    frame.sub:SetText(""); setMode("levels"); frame:Show(); rpc("REQ"); render()
  end
end
