-- RareRadar: client half of the Apex proximity radar.
-- The server (lua_scripts/rare_radar.lua) scans around real players and pushes
-- "PING|<name>|<dist>|<dir>" on addon prefix RARERADAR when a silver-dragon
-- Apex rare is within ~150yd. This addon turns that into a raid-warning
-- banner, a sound, and a chat line. /rr for options.

local PREFIX = "RARERADAR"

local function EnsureDB()
    if type(RareRadarDB) ~= "table" then RareRadarDB = {} end
    if RareRadarDB.enabled == nil then RareRadarDB.enabled = true end
    if RareRadarDB.sound   == nil then RareRadarDB.sound   = true end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == "RareRadar" then EnsureDB() end
        return
    end
    if arg1 ~= PREFIX then return end
    EnsureDB()
    if not RareRadarDB.enabled then return end

    local cmd, name, dist, dir = strsplit("|", arg2 or "")
    if cmd ~= "PING" or not name or name == "" then return end

    local where = (dist or "?") .. " yd " .. (dir or "")
    RaidNotice_AddMessage(RaidWarningFrame,
        "|cffc0c0c0Apex nearby:|r " .. name .. "  |cffffff00" .. where .. "|r",
        ChatTypeInfo["RAID_WARNING"])
    DEFAULT_CHAT_FRAME:AddMessage("|cffc0c0c0[RareRadar]|r " .. name .. " \226\128\148 " .. where)
    if RareRadarDB.sound then PlaySound("RaidWarning") end
end)

SLASH_RARERADAR1 = "/rareradar"
SLASH_RARERADAR2 = "/rr"
SlashCmdList["RARERADAR"] = function(msg)
    EnsureDB()
    msg = (msg or ""):lower()
    if msg == "toggle" or msg == "off" or msg == "on" then
        if msg == "toggle" then RareRadarDB.enabled = not RareRadarDB.enabled
        else RareRadarDB.enabled = (msg == "on") end
        DEFAULT_CHAT_FRAME:AddMessage("|cffc0c0c0[RareRadar]|r alerts "
            .. (RareRadarDB.enabled and "|cff33ff99ON|r" or "|cffff5555OFF|r"))
    elseif msg == "sound" then
        RareRadarDB.sound = not RareRadarDB.sound
        DEFAULT_CHAT_FRAME:AddMessage("|cffc0c0c0[RareRadar]|r sound "
            .. (RareRadarDB.sound and "|cff33ff99ON|r" or "|cffff5555OFF|r"))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffc0c0c0[RareRadar]|r /rr on|off|toggle \194\183 /rr sound. Alerts when an Apex rare is within ~150yd.")
    end
end
