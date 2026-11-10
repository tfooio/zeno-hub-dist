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
            if need and total >= need and Hub.Webhook then Hub.Webhook.evolveReady(u.uuid, name, total, need) end
            if need then
                text = ("%d: %s: %d / %d (%d left)%s"):format(slot, name, total, need, math.max(need - total, 0), extra)
            else
                text = ("%d: %s: %d takedowns (no takedown evolve)%s"):format(slot, name, total, extra)
            end
        end
        rows[slot]:SetText(text)
    end
end

-- Lifetime counters (docs/features/info-tab.md). The game keeps no "currency spent" total: remnants only pay trait rerolls,
-- so total_trait_rerolls is the remnant spend; pulls = sum of _hatched_unit_stats; per-banner opens come from pity_data / capsule_pity_data.
local life = UI.Tabs.Info:AddRightGroupbox("Lifetime", "history")
local lifeLabel = life:AddLabel("Loading...", true)

local function profile()
    local pd = Game.profile()
    if pd then return pd end
    local ok, svc = pcall(Game.loader().load_client_service, script, "UnitServiceClient")
    return ok and svc and svc.session and svc.session.profile_data or nil
end
local function commas(n) return (tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) end
local function readable(id)
    id = tostring(id):gsub("^capsule_", ""):gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
    return (id:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function refreshLife()
    local pd = profile()
    if not pd then return end
    local normal, shiny = 0, 0
    for _, s in pd._hatched_unit_stats or {} do normal += s.normal or 0 shiny += s.shiny or 0 end
    local lines = {
        ("Total trait rerolls: %s"):format(commas(pd.total_trait_rerolls or 0)),
        ("Units summoned: %s (%s shiny)"):format(commas(normal + shiny), commas(shiny)),
    }
    local rows = {}
    for id, p in pd.pity_data or {} do
        if (p.opens or 0) > 0 then rows[#rows + 1] = { readable(id), p.opens } end
    end
    for id, p in pd.capsule_pity_data or {} do
        if (p.total_opens or 0) > 0 then rows[#rows + 1] = { readable(id), p.total_opens } end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    if #rows > 0 then lines[#lines + 1] = "Opens per banner:" end
    for _, r in rows do lines[#lines + 1] = ("  %s: %s"):format(r[1], commas(r[2])) end
    lifeLabel:SetText(table.concat(lines, "\n"))
end

task.spawn(function()
    while env.ZenoHub == Hub do
        pcall(refresh)
        pcall(refreshLife)
        task.wait(3)
    end
end)

return Info
