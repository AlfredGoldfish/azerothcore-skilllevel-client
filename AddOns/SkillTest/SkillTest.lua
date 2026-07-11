--[[ SkillTest — a combat logger + meter for the skill-leveling test skills.
     Tracks EVERY seeded skill (SkillTest_Names.lua, all classes) and calls out the
     milestone mechanics as they fire, so you can VERIFY the engine on any class:
       • CAST lines with the gap since last cast  -> effective cooldown (M-CD)
       • multiple hits of one spell in a burst     -> +target / +shot / ricochet / splash
       • DoT tick count & stacks                   -> +tick / +stack / faster (M-AURA)
     Matches by spell NAME so every rank counts. The meter shows the top skills you cast.
     /stlog toggles the log · /stmeter toggles the bar meter. Recording -> SkillTestDB. ]]--

-- Every seeded skill name (generated). Falls back to the 5 Hunter test skills if the
-- data file is missing, so the addon still works standalone.
local TRACKED = SkillTest_TRACKED or {
  ["Steady Shot"] = true, ["Arcane Shot"] = true, ["Multi-Shot"] = true,
  ["Serpent Sting"] = true, ["Kill Shot"] = true,
}
local FLUSH    = 0.5       -- seconds: hits of one spell within this window = one "burst"
local MAX_ROWS = 12        -- meter shows the top-N skills by damage

local playerGUID
local lastCast  = {}       -- name -> GetTime() of last cast
local burst     = {}       -- name -> { t, n, tg = {targetName=true} }
local tickRun   = {}       -- name -> running tick # since last (re)application
local echoChat  = false

-- Structured recorder -> SkillTestDB (SavedVariables). Flushed to disk on /reload or
-- logout, so the log can be read + parsed off-client.
local DB
local function recEv(t)  if DB then local e = DB.events; e[#e + 1] = t; if #e > 1500 then table.remove(e, 1) end end end
local function recNote(s) if DB then local n = DB.notes;  n[#n + 1] = s; if #n > 500  then table.remove(n, 1) end end end

-- stable-ish color per skill name (hash into a palette)
local PALETTE = {
  {0.80,0.78,0.30},{0.60,0.40,0.90},{0.95,0.60,0.20},{0.30,0.80,0.45},{0.90,0.30,0.22},
  {0.35,0.65,0.95},{0.85,0.45,0.75},{0.55,0.85,0.30},{0.95,0.85,0.35},{0.45,0.80,0.80},
  {0.75,0.55,0.35},{0.65,0.55,0.95},{0.90,0.50,0.45},{0.50,0.75,0.55},
}
local colorCache = {}
local function colorFor(name)
  local c = colorCache[name]
  if not c then
    local h = 5381
    for i = 1, #name do h = (h * 33 + name:byte(i)) % 2147483648 end
    c = PALETTE[(h % #PALETTE) + 1]
    colorCache[name] = c
  end
  return c
end

local stats = {}
local function S(n)
  local s = stats[n]
  if not s then s = { dmg = 0, casts = 0, hits = 0, crits = 0, ticks = 0 }; stats[n] = s end
  return s
end
local function shortnum(n)
  if n >= 1e6 then return string.format("%.1fm", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

--============================== log window =================================--
local win = CreateFrame("Frame", "SkillTestWin", UIParent)
win:SetWidth(460); win:SetHeight(300); win:SetPoint("CENTER", 260, -80)
win:SetBackdrop({
  bgFile = "Interface/Tooltips/UI-Tooltip-Background",
  edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
win:SetBackdropColor(0, 0, 0, 0.88)
win:EnableMouse(true); win:SetMovable(true); win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)

local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 12, -10); title:SetText("|cff33ff99SkillTest|r  combat log")
local close = CreateFrame("Button", nil, win, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)

local scroll = CreateFrame("ScrollingMessageFrame", "SkillTestScroll", win)
scroll:SetPoint("TOPLEFT", 12, -30); scroll:SetPoint("BOTTOMRIGHT", -12, 12)
scroll:SetFontObject(GameFontHighlightSmall); scroll:SetJustifyH("LEFT")
scroll:SetMaxLines(400); scroll:SetFading(false); scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, d) if d > 0 then self:ScrollUp() else self:ScrollDown() end end)

local function log(msg, r, g, b)
  scroll:AddMessage(msg, r or 0.9, g or 0.9, b or 0.9)
  if echoChat then DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ST]|r " .. msg) end
end

--=================== flush bursts (extra-hit detection) ====================--
local acc = 0
win:SetScript("OnUpdate", function(self, elapsed)
  acc = acc + elapsed
  if acc < 0.1 then return end
  acc = 0
  local now = GetTime()
  for name, b in pairs(burst) do
    if now - b.t > FLUSH then
      if b.n > 1 then
        local nt = 0; for _ in pairs(b.tg) do nt = nt + 1 end
        recNote(string.format("BURST %s: %d hits on %d target(s)", name, b.n, nt))
        log(string.format("   %s: %d hits on %d target(s)  =>  +shot/+target/splash FIRING", name, b.n, nt), 0.4, 1.0, 0.4)
      end
      burst[name] = nil
    end
  end
end)

--============================== meter GUI ==================================--
-- Damage-meter style: top-N bars, scaled to the top skill, with the stats that verify
-- the mechanics — "Nh/Mc" (hits vs casts: >casts = extras fired), crit %, tick count,
-- and a green +extra tag. Bars are assigned dynamically to whatever you're casting.
local meter = CreateFrame("Frame", "SkillTestMeter", UIParent)
meter:SetWidth(340); meter:SetHeight(40 + MAX_ROWS * 22); meter:SetPoint("CENTER", -290, -40)
meter:SetBackdrop({
  bgFile = "Interface/Tooltips/UI-Tooltip-Background",
  edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
meter:SetBackdropColor(0, 0, 0, 0.88)
meter:EnableMouse(true); meter:SetMovable(true); meter:RegisterForDrag("LeftButton")
meter:SetScript("OnDragStart", meter.StartMoving); meter:SetScript("OnDragStop", meter.StopMovingOrSizing)

local mt = meter:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
mt:SetPoint("TOPLEFT", 10, -8); mt:SetText("|cff33ff99SkillTest Meter|r")
local mtot = meter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); mtot:SetPoint("TOP", 0, -9)
local mreset = CreateFrame("Button", nil, meter, "UIPanelButtonTemplate")
mreset:SetWidth(52); mreset:SetHeight(16); mreset:SetPoint("TOPRIGHT", -6, -6); mreset:SetText("Reset")
mreset:SetScript("OnClick", function() for k in pairs(stats) do stats[k] = nil end end)

local rows = {}
for i = 1, MAX_ROWS do
  local bar = CreateFrame("StatusBar", nil, meter)
  bar:SetHeight(18)
  bar:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 22)
  bar:SetPoint("RIGHT", meter, "RIGHT", -8, 0)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetMinMaxValues(0, 1); bar:SetValue(0)
  local bg = bar:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(bar); bg:SetTexture(0, 0, 0, 0.55)
  local lt = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); lt:SetPoint("LEFT", 4, 0); lt:SetJustifyH("LEFT")
  local rt = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); rt:SetPoint("RIGHT", -4, 0); rt:SetJustifyH("RIGHT")
  bar:Hide()
  rows[i] = { bar = bar, lt = lt, rt = rt }
end

local macc = 0
meter:SetScript("OnUpdate", function(self, e)
  macc = macc + e; if macc < 0.25 then return end; macc = 0
  local order = {}
  for n, s in pairs(stats) do if s.dmg > 0 then order[#order + 1] = n end end
  table.sort(order, function(a, b) return stats[a].dmg > stats[b].dmg end)
  local maxd, total = 1, 0
  for _, n in ipairs(order) do local d = stats[n].dmg; if d > maxd then maxd = d end; total = total + d end
  for i = 1, MAX_ROWS do
    local row, n = rows[i], order[i]
    if n then
      local s = stats[n]; local c = colorFor(n)
      row.bar:SetStatusBarColor(c[1], c[2], c[3]); row.bar:SetValue(s.dmg / maxd); row.bar:Show()
      local critp = s.hits > 0 and math.floor(s.crits / s.hits * 100) or 0
      local xtra  = (s.casts > 0 and s.hits > s.casts) and "  |cff40ff40+extra|r" or ""
      local tk    = s.ticks > 0 and ("  " .. s.ticks .. "t") or ""
      row.lt:SetText(string.format("%s |cff999999%dh/%dc %d%%cr%s|r%s", n, s.hits, s.casts, critp, tk, xtra))
      row.rt:SetText(shortnum(s.dmg))
    else
      row.bar:Hide()
    end
  end
  mtot:SetText("total " .. shortnum(total))
  if DB then
    DB.summary = DB.summary or {}
    for n, s in pairs(stats) do
      DB.summary[n] = { dmg = s.dmg, casts = s.casts, hits = s.hits, crits = s.crits, ticks = s.ticks }
    end
  end
end)

--============================ combat log ===================================--
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
ev:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then playerGUID = UnitGUID("player"); return end
  local timestamp, sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags = ...
  if not playerGUID then playerGUID = UnitGUID("player") end
  if srcGUID ~= playerGUID then return end
  local now = GetTime()

  if sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" then
    local spellId, spellName, spellSchool, amount, overkill, dS, resisted, blocked, absorbed, critical = select(9, ...)
    if not spellName or not TRACKED[spellName] then return end
    local crit = critical and "  |cffffff00CRIT|r" or ""
    local st = S(spellName)
    st.dmg = st.dmg + (amount or 0)
    if sub == "SPELL_PERIODIC_DAMAGE" then
      st.ticks = st.ticks + 1
      tickRun[spellName] = (tickRun[spellName] or 0) + 1
      recEv({ e = "tick", s = spellName, d = dstName, a = amount or 0, c = critical and 1 or 0 })
      log(string.format("%s  tick #%d   %d%s  -> %s", spellName, tickRun[spellName], amount or 0, crit, dstName or "?"), 0.55, 0.8, 1.0)
    else
      st.hits = st.hits + 1; if critical then st.crits = st.crits + 1 end
      recEv({ e = "hit", s = spellName, d = dstName, a = amount or 0, c = critical and 1 or 0 })
      -- accumulate into the current burst window for this spell (extra-hit detection)
      local b = burst[spellName]
      if b and (now - b.t) < FLUSH then b.n = b.n + 1; b.tg[dstName or "?"] = true; b.t = now
      else burst[spellName] = { t = now, n = 1, tg = { [dstName or "?"] = true } } end
      log(string.format("%s   %d%s  -> %s", spellName, amount or 0, crit, dstName or "?"), 0.95, 0.95, 0.95)
    end

  elseif sub == "SPELL_CAST_SUCCESS" then
    local spellId, spellName = select(9, ...)
    if not spellName or not TRACKED[spellName] then return end
    local prev = lastCast[spellName]
    lastCast[spellName] = now
    S(spellName).casts = S(spellName).casts + 1
    recEv({ e = "cast", s = spellName, gap = prev and (now - prev) or -1 })
    if prev then recNote(string.format("CAST %s  gap %.1fs", spellName, now - prev)) end
    local gap = prev and string.format("   |cff888888(%.1fs since last -> effective cooldown)|r", now - prev) or ""
    log("CAST  " .. spellName .. gap, 0.85, 0.8, 0.5)

  elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" then
    local spellId, spellName = select(9, ...)
    if spellName and TRACKED[spellName] then
      tickRun[spellName] = 0   -- restart the per-application tick counter
    end

  elseif sub == "SPELL_AURA_APPLIED_DOSE" or sub == "SPELL_AURA_REMOVED_DOSE" then
    local spellId, spellName, spellSchool, auraType, stacks = select(9, ...)
    if spellName and TRACKED[spellName] then
      recEv({ e = "stack", s = spellName, n = stacks or 0 })
      recNote(string.format("STACK %s -> %s", spellName, stacks or "?"))
      log(string.format("%s  =>  %s stacks   (+stack FIRING)", spellName, stacks or "?"), 0.4, 1.0, 0.6)
    end
  end
end)

--============================ slash / load ================================--
SLASH_SKILLTEST1 = "/stlog"
SlashCmdList["SKILLTEST"] = function(msg)
  msg = (msg or ""):lower():gsub("%s", "")
  if msg == "clear" then scroll:Clear(); return end
  if msg == "chat" then echoChat = not echoChat; log("echo to chat: " .. tostring(echoChat), 1, 1, 0.4); return end
  if win:IsShown() then win:Hide() else win:Show() end
end

SLASH_STMETER1 = "/stmeter"
SlashCmdList["STMETER"] = function() if meter:IsShown() then meter:Hide() else meter:Show() end end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, e, name)
  if name ~= "SkillTest" then return end
  SkillTestDB = { started = (date and date("%Y-%m-%d %H:%M:%S")) or "?", events = {}, notes = {}, summary = {} }
  DB = SkillTestDB
  local n = 0; for _ in pairs(TRACKED) do n = n + 1 end
  log(string.format("|cff33ff99SkillTest ready.|r tracking %d skills (all classes). Meter = per-skill totals; log = each event.", n))
  log("|cffffcc00Recording to SkillTestDB — type /reload after your test so it saves to disk.|r")
  log("Meter row: |cff999999Nh/Mc = hits vs casts (>casts = extras firing) · %cr crit · Nt ticks · +extra|r.")
  log("|cffffff00/stmeter|r bars · |cffffff00/stlog|r this log · |cffffff00/stlog chat|r echo · |cffffff00/stlog clear|r wipe.")
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SkillTest|r loaded — bar |cffffff00/stmeter|r · log |cffffff00/stlog|r.")
end)
