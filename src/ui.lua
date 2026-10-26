-- UI shell (Obsidian). Feature tabs are empty; Settings shows read-only state.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game

-- shortcut: tracks Obsidian main, pin a commit if an update breaks the UI.
local REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(REPO .. "Library.lua"))()
local SaveManager = loadstring(game:HttpGet(REPO .. "addons/SaveManager.lua"))()

local Window = Library:CreateWindow({
    Title = "Zeno Hub",
    Footer = "Anime Adventures | " .. Hub.mode .. (Hub.dev and " | dev" or ""),
    ToggleKeybind = Enum.KeyCode.RightControl,
    Center = true,
    AutoShow = true,
})

-- Same tabs and order as Nousigi (docs/roadmap.md); sections are added by the modules that own them.
local Tabs = {
    Lobby = Window:AddTab("Lobby", "house"),
    Joiner = Window:AddTab("Joiner", "door-open"),
    Dungeon = Window:AddTab("Dungeon", "skull"),
    DungeonInfo = Window:AddTab("Dungeon Info", "book-open"),
    Game = Window:AddTab("Game", "swords"),
    AutoPlay = Window:AddTab("Auto Play", "bot"),
    Macro = Window:AddTab("Macro", "play"),
    Webhook = Window:AddTab("Webhook", "webhook"),
    Misc = Window:AddTab("Misc", "ellipsis"),
    Settings = Window:AddTab("Settings", "settings"),
}

local Debug = Tabs.Settings:AddLeftGroupbox("Debug", "bug")
local labels = {}
for _, key in { "mode", "level", "money", "wave", "base hp", "gems", "gold" } do
    labels[key] = Debug:AddLabel(key .. ": -")
end
Debug:AddButton("Unload", function() Hub.unload() end)

SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder(Core.paths.config)
SaveManager:BuildConfigSection(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

local function refresh()
    local s = Game.state()
    labels.mode:SetText(("mode: %s (%d)"):format(Hub.mode, game.PlaceId))
    labels.level:SetText("level: " .. tostring(s.level or "-"))
    labels.money:SetText("money: " .. tostring(s.money or "-"))
    labels.wave:SetText("wave: " .. tostring(s.wave or "-"))
    labels["base hp"]:SetText(("base hp: %s / %s"):format(tostring(s.hp or "-"), tostring(s.max_hp or "-")))
    if Hub.mode == "lobby" then
        local pd = Game.profile()
        labels.gems:SetText("gems: " .. tostring(pd and pd.gem_amount or "-"))
        labels.gold:SetText("gold: " .. tostring(pd and pd.gold_amount or "-"))
    end
end

task.spawn(function()
    while not Library.Unloaded do
        local ok, err = pcall(refresh)
        if not ok then Core.log("ERROR ui refresh:", err) task.wait(10) end
        task.wait(1)
    end
end)

Library:OnUnload(function() Core.log("ui unloaded") end)

return { Library = Library, Window = Window, Tabs = Tabs }
