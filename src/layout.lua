-- Section layout (user, 2026-11-20: small sections like Performance sat under huge lists and nobody found them).
-- Runs once after every module has added its boxes. One table says, per tab, which box goes in which column and in what order;
-- tall lists get a height cap (they scroll inside their box instead of pushing everything below them out of sight), setup-once
-- boxes start collapsed (their title stays visible). A box that is not named keeps its side and goes after the named ones; a
-- named box that does not exist in this mode (lobby / match) is skipped. Measured heights: docs/features/ui-layout.md.
local Hub = ...
local Core = Hub.Core
local UI = Hub.UI
if not UI then return {} end

-- left / right = box titles, top first. height = max height in px. collapsed = start closed.
local SPEC = {
    Game = {
        left = { "Gameplay", "Auto Skip Wave", "Abilities", "Auto Sell", "Auto Leave", "Placement (match only)" },
        right = { "Game Finished", "Performance", "Auto Modifier", "Modifier Priority" },
        height = { ["Modifier Priority"] = 300 },
    },
    Summer = {
        left = { "Summer Hunt", "Weather Teams" },
        right = { "Summer Shop", "Summer Merchant", "Summer Skins", "Custom Card Priority", "Custom Weather Card Priority" },
        height = { ["Custom Card Priority"] = 320, ["Custom Weather Card Priority"] = 320 },
    },
    Joiner = {
        left = { "Auto Join Setting", "World Joiner", "Legend Joiner", "Raid Joiner", "Challenge Joiner", "Daily Challenge Joiner", "Team Equipper" },
        right = { "Infinity Mansion Joiner", "Portal Joiner", "Artifact Joiner", "Party Farming", "Server", "Relic Farm" },
        height = { ["Auto Join Setting"] = 300 },
        collapsed = { ["Team Equipper"] = true },
    },
    Dungeon = {
        left = { "Dungeon Run", "Shrine", "Shop" },
        right = { "Room Priority" },
    },
    Macro = {
        left = { "Manage", "Macro", "Information" },
        right = { "Play Macro Config", "Stage Macros" },
    },
    Misc = {
        left = { "Secure" },
        right = { "Players", "Stall Watchdog" },
    },
    Settings = {
        left = { "Information", "UI Control", "Failsafe" },
        right = { "Script Config", "Themes" },
        height = { Themes = 380 },
    },
}

local function arrange(tab, spec)
    local sides = tab.Sides
    local named = {}
    for _, list in { spec.left or {}, spec.right or {} } do
        for _, n in list do
            local gb = tab.Groupboxes[n]
            if gb then named[gb.BoxHolder] = true end
        end
    end
    -- boxes nobody named (a tabbox, a new module's box) are collected before anything moves; they stay on their side, after the named ones
    local rest = { {}, {} }
    for i = 1, 2 do
        for _, c in sides[i]:GetChildren() do
            if c:IsA("Frame") and c.LayoutOrder == 0 and not named[c] then table.insert(rest[i], c) end
        end
    end
    for i, list in { spec.left or {}, spec.right or {} } do
        local order = {}
        for _, n in list do
            local gb = tab.Groupboxes[n]
            if gb then table.insert(order, gb.BoxHolder) end
        end
        for _, c in rest[i] do table.insert(order, c) end
        -- leaving and re-entering the parent puts a box last among equal LayoutOrders, so doing it in order sorts the column
        for _, holder in order do
            holder.Parent = nil
            holder.Parent = sides[i]
        end
    end
    for n, h in spec.height or {} do
        local gb = tab.Groupboxes[n]
        if gb then gb.MaxHeight = h gb:Resize() end
    end
    for n in spec.collapsed or {} do
        local gb = tab.Groupboxes[n]
        if gb then gb:SetCollapsed(true) end
    end
end

for key, spec in SPEC do
    local tab = UI.Tabs[key]
    if tab and tab.Groupboxes and tab.Sides then
        local ok, err = pcall(arrange, tab, spec)
        if not ok then Core.log("ERROR layout", key, err) end
    end
end

return {}
