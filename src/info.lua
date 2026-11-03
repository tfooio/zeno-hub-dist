-- Info tab: lifetime takedowns of every equipped unit against its evolve requirement (docs/features/info-tab.md).
-- Source: profile owned_units[uuid].total_takedowns (kept by the game) and Units[id].evolve.<normal|shiny>._takedown_requirement.
local Hub = ...
local Game = Hub.Game
local env = getgenv()
local Info = {}

local UI = Hub.UI
if not UI then return Info end
local defs = Game.data("Units")

local function collection()
    local col
    pcall(function() col = Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
    if not col then local pd = Game.profile() col = pd and pd.collection end
    return col
end

-- Takedowns of this unit id in the current match (placed copies), on top of the profile total.
local function matchTakedowns(id)
    local n, folder = 0, workspace:FindFirstChild("_UNITS")
    for _, m in folder and folder:GetChildren() or {} do
        local st = m:FindFirstChild("_stats")
        local uid, td = st and st:FindFirstChild("id"), st and st:FindFirstChild("takedown_count")
        if uid and td and uid.Value == id then n += td.Value end
    end
    return n
end

local box = UI.Tabs.Info:AddLeftGroupbox("Equipped Units: Takedowns", "swords")
local rows = {}
for slot = 1, 6 do rows[slot] = box:AddLabel(("%d: -"):format(slot), true) end

local function refresh()
    local col = collection()
    for slot = 1, 6 do
        local text = ("%d: -"):format(slot)
        local u = col and col.owned_units[col.equipped_units[tostring(slot)]]
        if u then
            local d = defs[u.unit_id]
            local name = d and d.name or u.unit_id
            local total = u.total_takedowns or 0
            local ev = d and d.evolve and (u.shiny and d.evolve.shiny or d.evolve.normal)
            local need = ev and ev._takedown_requirement
            local live = Hub.mode == "match" and matchTakedowns(u.unit_id) or 0
            local extra = live > 0 and (" | this match +%d"):format(live) or ""
            if need then
                text = ("%d: %s: %d / %d (%d left)%s"):format(slot, name, total, need, math.max(need - total, 0), extra)
            else
                text = ("%d: %s: %d takedowns (no takedown evolve)%s"):format(slot, name, total, extra)
            end
        end
        rows[slot]:SetText(text)
    end
end

task.spawn(function()
    while env.ZenoHub == Hub do
        pcall(refresh)
        task.wait(3)
    end
end)

return Info
