-- UI shell (Obsidian). Feature tabs are empty; Settings shows read-only state.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game

-- shortcut: tracks Obsidian main, pin a commit if an update breaks the UI.
local REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
-- Three tries, then the copy saved by the first good fetch (Zeno Hub/Cache): a network blip or a GitHub outage used to mean no UI
-- (3 failed loads in the logs: 2026-10-23, 10-31, 11-01). shortcut: the copy is written once and not refreshed; delete the Cache folder to renew it.
local CACHE = Core.paths.root .. "/Cache"
if not isfolder(CACHE) then makefolder(CACHE) end
local function fetch(file) -- returns the compiled chunk
    local cache = CACHE .. "/obsidian_" .. (file:gsub("/", "_"))
    for try = 1, 3 do
        local ok, src = pcall(game.HttpGet, game, REPO .. file)
        local fn = ok and type(src) == "string" and loadstring(src)
        if fn then
            if not isfile(cache) then pcall(writefile, cache, src) end
            return fn
        end
        if try < 3 then task.wait(try * 2) end
    end
    Core.log("ui: could not fetch", file, isfile(cache) and "(using the saved copy)" or "(no saved copy)")
    return assert(loadstring(readfile(cache)))
end
local Library = fetch("Library.lua")()
local SaveManager = fetch("addons/SaveManager.lua")()
local okTM, ThemeManager = pcall(function() return fetch("addons/ThemeManager.lua")() end)

-- Soft dark + pink look. A theme the user saved as default (Settings > Themes) still overrides these.
Library.Scheme.BackgroundColor = Color3.fromRGB(16, 16, 24)
Library.Scheme.MainColor = Color3.fromRGB(26, 26, 38)
Library.Scheme.OutlineColor = Color3.fromRGB(46, 46, 64)
Library.Scheme.AccentColor = Color3.fromRGB(240, 143, 181)

local Window = Library:CreateWindow({
    Title = "Zeno Hub",
    Footer = "Anime Adventures | " .. Hub.mode .. (Hub.dev and " | dev" or ""),
    ToggleKeybind = Enum.KeyCode.RightControl,
    Center = true,
    AutoShow = true,
    Size = UDim2.fromOffset(820, 560),
    CornerRadius = 12,
    Font = Enum.Font.GothamMedium,
    TabButtonsStyle = { Gap = 2, Padding = 6, CornerRadius = 8, Indicator = false, IndicatorWidth = 2, IndicatorHeight = 20 },
    Animations = { ToggleWindow = false, TabSwitch = true, Groupbox = false, Dropdown = true, KeyPicker = false },
})

-- The tabs of Nousigi (docs/roadmap.md), ordered by what you do (docs/review/findings.md, UI proposal B):
-- set up (Lobby, Joiner, Macro, Webhook), run unattended (Summer, Dungeon, Game, Auto Play, Misc), inspect (Info, Dungeon Info, Settings).
-- Obsidian has no sidebar headers, so the order is the only grouping. Sections are added by the modules that own them.
local Tabs = {
    Lobby = Window:AddTab("Lobby", "house"),
    Joiner = Window:AddTab("Joiner", "door-open"),
    Macro = Window:AddTab("Macro", "play"),
    Webhook = Window:AddTab("Webhook", "webhook"),
    Summer = Window:AddTab("Summer", "sun"),
    Dungeon = Window:AddTab("Dungeon", "skull"),
    Game = Window:AddTab("Game", "swords"),
    AutoPlay = Window:AddTab("Auto Play", "bot"),
    Misc = Window:AddTab("Misc", "ellipsis"),
    Info = Window:AddTab("Info", "info"),
    DungeonInfo = Window:AddTab("Dungeon Info", "book-open"),
    Settings = Window:AddTab("Settings", "settings"),
}

SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder(Core.paths.config)
SaveManager:LoadAutoloadConfig()

Library:OnUnload(function() Core.log("ui unloaded") end)

return { Library = Library, Window = Window, Tabs = Tabs, ThemeManager = okTM and ThemeManager or nil }
