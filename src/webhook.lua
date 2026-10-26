-- Webhook tab: Discord embed per match from run_finished. URL lives in Core.config.webhook (hub.json, per account).
local Hub = ...
local Core = Hub.Core
local HttpService = game:GetService("HttpService")

local cfg = Core.config.webhook or {}
Core.config.webhook = cfg
if cfg.enabled == nil then cfg.enabled = false end
cfg.url = cfg.url or ""
if cfg.chest == nil then cfg.chest = true end

local request = request or http_request or (syn and syn.request) or (http and http.request)
local Webhook = {}

local function valid(url) return type(url) == "string" and url:match("^https://[%w%.]*discord[%w]*%.com/api/webhooks/") ~= nil end

-- Returns ok, status. Never logs the URL.
function Webhook.send(payload)
    if not request then return false, "no request function" end
    if not valid(cfg.url) then return false, "no valid webhook URL" end
    local ok, res = pcall(request, {
        Url = cfg.url,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode(payload),
    })
    if not ok then return false, tostring(res) end
    local code = res and res.StatusCode
    return code == 200 or code == 204, code
end

local function num(v)
    if type(v) ~= "number" then return tostring(v or "-") end
    local r = math.round(v)
    return (math.abs(v - r) < 0.05 or v >= 1000) and tostring(r) or ("%.1f"):format(v)
end

local function duration(s)
    if type(s) ~= "number" then return "-" end
    return ("%d:%02d"):format(s // 60, s % 60)
end

-- Large numbers as 20.5M / 3.2K (damage reaches eight digits).
local function short(v)
    if type(v) ~= "number" then return tostring(v or "-") end
    for _, u in { { 1e9, "B" }, { 1e6, "M" }, { 1e4, "K" } } do
        if math.abs(v) >= u[1] then return ("%.1f%s"):format(v / u[1], u[2]) end
    end
    return num(v)
end

-- Proper names for ids, from the game's own data; unknown ids are made readable (star_remnant -> Star Remnant).
local Game = Hub.Game
local cache = {}
local function data(name)
    if cache[name] == nil then
        local ok, d = pcall(Game.data, name)
        cache[name] = ok and type(d) == "table" and d or false
    end
    return cache[name] or {}
end
local CURRENCY = { gems = "Gems", gold = "Gold", units = "Units", GemsLegacy = "Legacy Gems", AprilCoins = "April Coins" } -- not in the Items data
local function readable(id)
    id = tostring(id):gsub("^_+", ""):gsub("__.*$", ""):gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
    return (id:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
local function itemName(id)
    id = tostring(id)
    local d = not CURRENCY[id] and data("Items")[id]
    return CURRENCY[id] or (d and d.name) or readable(id)
end
local function unitName(id)
    local d = data("Units")[tostring(id)]
    return d and d.name or readable(id)
end
local STAGE = { story = "Story", raid = "Raid", challenge = "Challenge", infinite = "Infinite", legend = "Legend" }

-- Remnant totals (user, 2026-10-26): "(Total: N)" next to what a match or chest run gave. The lobby reads the real count
-- from the profile (profile_data.inventory.normal_items); a match has no profile, so the last lobby reading is kept in
-- Data/totals_<user>.json and each match's drops are added to it. Unknown total = no suffix, never a guess.
local TRACK = { star_remnant = true, star_remnant_limited = true }
local totalsFile = Core.paths.data .. "/totals_" .. game:GetService("Players").LocalPlayer.Name .. ".json"
local totals = {}
do
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(totalsFile)) end)
    if ok and type(d) == "table" then for id in TRACK do if type(d[id]) == "number" then totals[id] = d[id] end end end
end
local function saveTotals() pcall(writefile, totalsFile, HttpService:JSONEncode(totals)) end
local function readProfileTotals()
    local pd = Game.profile()
    local items = pd and pd.inventory and pd.inventory.normal_items
    if type(items) ~= "table" then return false end
    local changed = false
    for id in TRACK do
        local n = type(items[id]) == "number" and items[id] or 0
        if totals[id] ~= n then totals[id] = n changed = true end
    end
    if changed then saveTotals() end
    return true
end
local function addGain(id, n)
    if TRACK[id] and totals[id] and tonumber(n) then totals[id] += tonumber(n) saveTotals() end
end
local function commas(n) return (tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) end
local function totalOf(id) return TRACK[id] and totals[id] and (" (Total: %s)"):format(commas(totals[id])) or "" end
if Hub.mode == "lobby" then
    task.spawn(function()
        while getgenv().ZenoHub == Hub do
            pcall(readProfileTotals)
            task.wait(15)
        end
    end)
end

-- Drop entries: {item_id, amount} (verified) or units; the same drop seen twice is added up.
local function drop_lines(list, out)
    if type(list) ~= "table" then return end
    local sum, order, ids = {}, {}, {}
    local function add(name, n, id)
        if not sum[name] then sum[name] = 0 table.insert(order, name) end
        sum[name] += n
        ids[name] = id
    end
    for _, d in list do
        if type(d) == "table" then
            local id = d.item_id or d.unit_id or d.id or d.name
            if id then add(d.unit_id and unitName(id) or itemName(id), tonumber(d.amount) or 1, not d.unit_id and id or nil)
            else table.insert(out, HttpService:JSONEncode(d)) end
        else
            table.insert(out, tostring(d))
        end
    end
    for _, name in order do table.insert(out, ("%s x%s%s"):format(name, num(sum[name]), totalOf(ids[name]))) end
end

function Webhook.embed(rec)
    local rewards = { ("Gems: %s"):format(num(rec.gems)), ("Gold: %s"):format(num(rec.gold)), ("XP: %s"):format(num(rec.xp)) }
    if type(rec.resources) == "table" then
        for k, v in rec.resources do
            if type(v) ~= "number" or v ~= 0 then table.insert(rewards, ("%s: %s"):format(itemName(k), num(v))) end
        end
    end
    local drops = {}
    drop_lines(rec.new_units, drops)
    drop_lines(rec.new_items, drops)
    local stage = rec.stage or STAGE[rec.mode] or (rec.mode and readable(rec.mode)) or "-"
    if tostring(rec.name or ""):find("^Dungeon Room") then stage = "Dungeon Run" end
    local map = rec.map and data("Maps")[rec.map]
    local place = (map and map.name) or (rec.map and readable(rec.map)) or nil
    local fields = {
        { name = "Mode", value = ("%s / %s"):format(stage, tostring(rec.difficulty or "-")), inline = true },
        { name = "Waves", value = ("%s / %s"):format(num(rec.waves), num(rec.num_waves)), inline = true },
        { name = "Time", value = duration(rec.time), inline = true },
        { name = "Kills", value = num(rec.kills), inline = true },
        { name = "Damage", value = short(rec.damage), inline = true },
        { name = "First clear", value = rec.first_completion and "yes" or "no", inline = true },
        { name = "Rewards", value = table.concat(rewards, "\n"), inline = false },
        { name = "Drops", value = #drops > 0 and table.concat(drops, "\n"):sub(1, 1000) or "none", inline = false },
    }
    return {
        username = "Zeno Hub",
        embeds = { {
            title = rec.victory and "Victory - " .. (place and place .. " - " or "") .. tostring(rec.name or stage)
                or "Defeat - " .. (place and place .. " - " or "") .. tostring(rec.name or stage),
            color = rec.victory and 0x2ECC71 or 0xE74C3C,
            fields = fields,
            footer = { text = tostring(rec.user or "") },
            timestamp = rec.date,
        } },
    }
end

-- Dungeon chests (src/dungeon.lua): "opened" = right after the last room, "rewards" = the inventory change seen in the lobby.
-- Chest lines come as "<id> x<n>", "unit <id>" (rewards) and "<id> +<n>" (inventory change).
local function rewardLine(line)
    local id, n = line:match("^(%S+) x(%d+)$")
    if id then return ("%s x%s%s"):format(itemName(id), n, totalOf(id)) end
    local u = line:match("^unit (%S+)$")
    return u and ("Unit: " .. unitName(u)) or line
end
local function gainedLine(line)
    local id, d = line:match("^(%S+) ([+-]?%d+)$")
    return id and ("%s %s%s"):format(itemName(id), d, totalOf(id)) or line
end
function Webhook.chestEmbed(rec)
    local opened = rec.kind == "opened"
    if rec.kind == "stuck" then
        return { username = "Zeno Hub", embeds = { {
            title = "Dungeon chests NOT opened yet",
            description = "The last room is done but the chests will not open. The hub keeps trying and stays out of the lobby until they are open.",
            color = 0xE74C3C,
            fields = { { name = "Chests left", value = ("%s normal, %s rare"):format(num(rec.normal), num(rec.rare)), inline = true } },
            footer = { text = tostring(rec.user or "") },
            timestamp = rec.date,
        } } }
    end
    local fields = {
        { name = "Depth", value = tostring(rec.depth or "-"), inline = true },
        { name = "Chests", value = ("%s normal, %s rare"):format(num(rec.normal), num(rec.rare)), inline = true },
        { name = "Luck", value = rec.luck and ("x%.1f"):format(rec.luck) or "-", inline = true },
    }
    if opened then
        table.insert(fields, { name = "Dungeon keys", value = ("%s -> %s"):format(tostring(rec.keys_before or "?"), tostring(rec.keys_after or "?")), inline = true })
        local r = {}
        for _, l in rec.rewards or {} do table.insert(r, rewardLine(l)) end
        table.insert(fields, { name = "Rewards from the chests", value = #r > 0 and table.concat(r, "\n"):sub(1, 1000) or "none seen", inline = false })
        local m, seen = {}, {}
        for _, t in rec.messages or {} do if not seen[t] then seen[t] = true table.insert(m, t) end end
        if #m > 0 then table.insert(fields, { name = "Messages", value = table.concat(m, "\n"):sub(1, 1000), inline = false }) end
    else
        local g = {}
        for _, l in rec.gained or {} do table.insert(g, gainedLine(l)) end
        table.insert(fields, { name = "Inventory change since the last lobby visit", value = #g > 0 and table.concat(g, "\n"):sub(1, 1000) or "nothing changed", inline = false })
    end
    return { username = "Zeno Hub", embeds = { {
        title = opened and "Dungeon chests opened" or "Dungeon rewards",
        color = opened and 0xF1C40F or 0x9B59B6,
        fields = fields,
        footer = { text = tostring(rec.user or "") },
        timestamp = rec.date,
    } } }
end

local Tabs = Hub.UI and Hub.UI.Tabs
local Library = Hub.UI and Hub.UI.Library
local function notify(msg) Core.log("webhook:", msg) if Library then Library:Notify(msg, 4) end end

if Tabs then
    local box = Tabs.Webhook:AddLeftGroupbox("Setting", "webhook")
    box:AddInput("WebhookUrl", {
        Text = "Webhook URL",
        Default = cfg.url,
        Placeholder = "https://discord.com/api/webhooks/...",
        Finished = true,
        Callback = function(v)
            v = (v or ""):gsub("%s", "")
            if v ~= "" and not valid(v) then return notify("not a Discord webhook URL") end
            cfg.url = v
            Core.save_config()
        end,
    })
    box:AddButton("Test Webhook", function()
        task.spawn(function()
            local ok, code = Webhook.send({ username = "Zeno Hub", embeds = { { title = "Test", description = "Webhook works.", color = 0x5865F2, footer = { text = game:GetService("Players").LocalPlayer.Name } } } })
            notify(ok and "test sent" or ("test failed: " .. tostring(code)))
        end)
    end)
    local note = Tabs.Webhook:AddRightGroupbox("Notification", "bell")
    note:AddToggle("WebhookEnabled", { Text = "Game Finished", Default = cfg.enabled, Callback = function(v) cfg.enabled = v Core.save_config() end })
    note:AddToggle("WebhookChest", { Text = "Dungeon Chest Opened", Tooltip = "After the last dungeon room: the chests opened, your luck, and what the inventory gained.", Default = cfg.chest, Callback = function(v) cfg.chest = v Core.save_config() end })
end

-- Spawned so the HTTP call does not delay match.lua's next/replay on the same game_finished.
local unsub = Core.on("run_finished", function(rec)
    -- Totals first, even with the notification off, so the next report is right.
    for _, d in rec.new_items or {} do if type(d) == "table" and d.item_id then addGain(d.item_id, d.amount) end end
    if not cfg.enabled then return end
    task.spawn(function()
        local ok, code = Webhook.send(Webhook.embed(rec))
        Core.log("webhook:", ok and "sent" or "failed", tostring(code))
    end)
end)
table.insert(Hub.connections, { Disconnect = unsub })
local unsubChest = Core.on("dungeon_chests", function(rec)
    if rec.kind == "opened" then
        for _, l in rec.rewards or {} do local id, n = l:match("^(%S+) x(%d+)$") if id then addGain(id, n) end end
    elseif rec.kind == "rewards" then
        readProfileTotals() -- in the lobby: the real count
    end
    if not cfg.chest then return end
    task.spawn(function()
        local ok, code = Webhook.send(Webhook.chestEmbed(rec))
        Core.log("webhook: dungeon chests", rec.kind, ok and "sent" or "failed", tostring(code))
    end)
end)
table.insert(Hub.connections, { Disconnect = unsubChest })

return Webhook
