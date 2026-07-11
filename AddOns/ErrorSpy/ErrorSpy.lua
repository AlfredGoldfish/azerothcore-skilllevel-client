-- ErrorSpy: temporary diagnostics addon.
-- Captures (1) Lua errors with stack traces -- even when "Display Lua Errors"
-- is off -- and (2) red UIErrorsFrame text (server rejections, addon blocks).
-- Everything is printed to chat and appended to ErrorSpyDB (account-wide),
-- so the log can be read from the SavedVariables file after logout.
-- Remove the addon (or disable it) once the bug hunt is over.

ErrorSpyDB = type(ErrorSpyDB) == "table" and ErrorSpyDB or {}

local MAX_ENTRIES = 200

local function log(kind, msg)
    msg = tostring(msg)
    if #ErrorSpyDB >= MAX_ENTRIES then
        table.remove(ErrorSpyDB, 1)
    end
    ErrorSpyDB[#ErrorSpyDB + 1] = date("%m-%d %H:%M:%S") .. " [" .. kind .. "] " .. msg
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555ErrorSpy [" .. kind .. "]|r " .. msg)
end

-- (1) Lua errors: hook the error handler; keep prior behavior intact.
local prevHandler = geterrorhandler()
seterrorhandler(function(err)
    log("LUA", tostring(err) .. "\n" .. debugstack(3, 8, 2))
    if prevHandler then pcall(prevHandler, err) end
end)

-- (2) Red UI errors + blocked/forbidden addon actions.
local f = CreateFrame("Frame")
f:RegisterEvent("UI_ERROR_MESSAGE")
f:RegisterEvent("ADDON_ACTION_BLOCKED")
f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
f:RegisterEvent("MACRO_ACTION_BLOCKED")
f:RegisterEvent("MACRO_ACTION_FORBIDDEN")
f:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "UI_ERROR_MESSAGE" then
        log("UIERR", a1)
    else
        log(event, tostring(a1) .. " called " .. tostring(a2))
    end
end)

-- /espy       -> dump the captured log to chat
-- /espy clear -> wipe it
SLASH_ERRORSPY1 = "/espy"
SlashCmdList["ERRORSPY"] = function(msg)
    if (msg or ""):lower() == "clear" then
        for i = #ErrorSpyDB, 1, -1 do ErrorSpyDB[i] = nil end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555ErrorSpy|r log cleared.")
        return
    end
    if #ErrorSpyDB == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555ErrorSpy|r nothing captured yet.")
        return
    end
    for _, line in ipairs(ErrorSpyDB) do
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9999" .. line .. "|r")
    end
end

DEFAULT_CHAT_FRAME:AddMessage("|cffff5555ErrorSpy|r loaded -- reproduce the bag error, then /espy (or just log out so the file saves).")
