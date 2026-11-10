-- Webhook tab: Discord embed per match from run_finished. URL lives in Core.config.webhook (hub.json, per account).
local Hub = ...
local Core = Hub.Core
local HttpService = game:GetService("HttpService")

local cfg = Core.config.webhook or {}
Core.config.webhook = cfg
if cfg.enabled == nil then cfg.enabled = false end
cfg.url = cfg.url or ""
if cfg.chest == nil then cfg.chest = true end

cfg.emoji = cfg.emoji or {}
if cfg.evolve == nil then cfg.evolve = false end
cfg.evolve_sent = cfg.evolve_sent or {} -- unit uuids already pinged
if cfg.rare == nil then cfg.rare = true end

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

-- Ping the configured Discord id once per unit (uuid) when its takedowns reach the evolve requirement.
function Webhook.evolveReady(uuid, name, total, need)
    if not cfg.evolve or cfg.evolve_sent[uuid] or not (cfg.discord_id or ""):match("^%d+$") then return end
    cfg.evolve_sent[uuid] = true
    Core.save_config()
    task.spawn(function()
        local ok, code = Webhook.send({
            username = "Zeno Hub",
            content = ("<@%s>"):format(cfg.discord_id),
            allowed_mentions = { users = { cfg.discord_id } },
            embeds = { { title = name .. " is ready to evolve", description = ("%d / %d takedowns"):format(total, need), color = 0xF1C40F,
                footer = { text = game:GetService("Players").LocalPlayer.Name } } },
        })
        if not ok then cfg.evolve_sent[uuid] = nil end -- try again next refresh
        Core.log("webhook: evolve ready", name, ok and "sent" or "failed", tostring(code))
    end)
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
local TRACK = { star_remnant = true, star_remnant_limited = true, SummerPearls = true, gems = true, gold = true, xp = true, trait = true }
local RESOURCE = { SummerPearls = true } -- kept in profile_data.resources (user, 2026-11-02), not inventory.normal_items
local TOP = { gems = "gem_amount", gold = "gold_amount", xp = "player_xp", trait = "trait_reroll_tokens" } -- profile_data top-level fields (seen live 2026-11-10)
local totalsFile = Core.paths.data .. "/totals_" .. game:GetService("Players").LocalPlayer.Name .. ".json"
local totals = {}
do
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(totalsFile)) end)
    if ok and type(d) == "table" then for id in TRACK do if type(d[id]) == "number" then totals[id] = d[id] end end end
end
local function saveTotals() pcall(writefile, totalsFile, HttpService:JSONEncode(totals)) end
-- The lobby profile; in a match the unit service holds the same profile_data (seen live 2026-11-02).
local function profileData()
    local pd = Game.profile()
    if pd then return pd end
    local ok, svc = pcall(Game.loader().load_client_service, script, "UnitServiceClient")
    return ok and svc and svc.session and svc.session.profile_data or nil
end
local function readProfileTotals()
    local pd = profileData()
    local items = pd and pd.inventory and pd.inventory.normal_items
    local res = pd and pd.resources
    if type(items) ~= "table" and type(res) ~= "table" then return false end
    local changed = false
    for id in TRACK do
        local src = TOP[id] and pd or RESOURCE[id] and res or items
        if type(src) ~= "table" then continue end
        local key = TOP[id] or id
        local n = type(src[key]) == "number" and src[key] or 0
        if totals[id] ~= n then totals[id] = n changed = true end
    end
    if changed then saveTotals() end
    return true
end
local function addGain(id, n)
    if TRACK[id] and totals[id] and tonumber(n) then totals[id] += tonumber(n) saveTotals() end
end
local function commas(n) return (tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) end
local function totalOf(id) return TRACK[id] and totals[id] and (" · %s total"):format(commas(totals[id])) or "" end

-- Custom emoji for currencies: cfg.emoji["gems"] = "<:zh_gems:123...>" (pasted from Discord, see the Webhook tab).
local ICON_ALIAS = { star_remnant_limited = "star_remnant" } -- the game uses one icon for both
local function icon(key)
    key = ICON_ALIAS[key] or key
    local e = cfg.emoji[tostring(key):lower()]
    return e and (e .. " ") or ""
end

-- "Level 401 · 2,053 / 2,900 XP" from the tracked XP total and the game's own level formula.
local function levelText()
    if not totals.xp then return nil end
    local ok, text = pcall(function()
        local core = Game.loader().load_core_service(script, "LevelServiceCore")
        local p = game:GetService("Players").LocalPlayer
        local lv = core.calculate_level(p, totals.xp)
        local base = core.calculate_xp(p, lv)
        return ("Level %d · %s / %s XP"):format(lv, commas(totals.xp - base), commas(core.calculate_xp(p, lv + 1) - base))
    end)
    return ok and text or nil
end
if Hub.mode == "lobby" then
    task.spawn(function()
        while getgenv().ZenoHub == Hub do
            pcall(readProfileTotals)
            task.wait(15)
        end
    end)
else
    task.spawn(function() -- the profile appears a few seconds after the match loads
        for _ = 1, 30 do
            task.wait(1)
            if getgenv().ZenoHub ~= Hub or select(2, pcall(readProfileTotals)) == true then return end
        end
    end)
end

-- Drop entries: {item_id, amount} (verified) or units; the same drop seen twice is added up.
-- new_units entries are unit uuids (seen in the game's end-screen code); unit_ids[i] is the unit id the run log stored
-- for entry i, else the collection is asked. A uuid is never shown.
local function drop_lines(list, out, unit_ids)
    if type(list) ~= "table" then return end
    local sum, order, ids = {}, {}, {}
    local function add(name, n, id)
        if not sum[name] then sum[name] = 0 table.insert(order, name) end
        sum[name] += n
        ids[name] = id
    end
    for i, d in list do
        if type(d) == "table" then
            local id = d.item_id or d.unit_id or d.id or d.name
            if id then add(d.unit_id and unitName(id) or itemName(id), tonumber(d.amount) or 1, not d.unit_id and id or nil)
            else table.insert(out, HttpService:JSONEncode(d)) end
        elseif unit_ids then
            local id = unit_ids[i] or type(d) == "string" and Game.unit_id(d) or nil
            add(id and unitName(id) or "New unit", 1)
        else
            table.insert(out, tostring(d))
        end
    end
    for _, name in order do table.insert(out, ("%s **x%s**"):format(name, num(sum[name]))) end
end

-- Drops that ping (user, 2026-11-10): the secret units and their portals. Ids checked live 2026-11-10 (Items / Units data):
-- Sky God = enel, Explosion Mage = megumin, Phoenix = marco (the evolved ids are listed too).
local PING_UNITS = { enel = true, enel_evolved = true, megumin = true, megumin_evolved = true, marco = true, marco_evolved = true }
local PING_ITEMS = { portal_item__enel = true, portal_summer2_secret = true }
-- Names of the pinging drops in a run record, "" when none.
local function pingDrops(rec)
    local out = {}
    for i, d in type(rec.new_units) == "table" and rec.new_units or {} do
        local id = type(d) == "table" and (d.unit_id or d.id) or (rec.new_unit_ids or {})[i]
        if PING_UNITS[id] then table.insert(out, unitName(id)) end
    end
    for _, d in type(rec.new_items) == "table" and rec.new_items or {} do
        if type(d) == "table" and PING_ITEMS[d.item_id] then table.insert(out, itemName(d.item_id)) end
    end
    return table.concat(out, ", ")
end

-- Embed header: the game's own icon (public thumbnail of its universe) and name. Fetched once; a failed fetch is not cached.
-- shortcut: the name is fixed per game script, set it when this module is reused for another game.
local GAME_NAME = "Anime Adventures"
local gameAuthor
local function author()
    if gameAuthor then return gameAuthor end
    local a = { name = GAME_NAME }
    local ok, res = pcall(request, { Url = ("https://thumbnails.roblox.com/v1/games/icons?universeIds=%d&returnPolicy=PlaceHolder&size=150x150&format=Png&isCircular=false"):format(game.GameId), Method = "GET" })
    local ok2, body = pcall(HttpService.JSONDecode, HttpService, ok and res and res.StatusCode == 200 and res.Body or "")
    local url = ok2 and type(body) == "table" and body.data and body.data[1] and body.data[1].imageUrl
    if type(url) == "string" then a.icon_url = url gameAuthor = a end
    return a
end

-- One gain line: icon, name, bold gain. Zero gains are left out by the caller; the totals are in the Balances fields.
local function gainLine(key, name, n)
    return ("%s%s **+%s**"):format(icon(key), name, commas(n))
end

-- Always shown on a match embed (user, 2026-11-10): {tracked id, label}, three per column. "-" = balance not read yet.
local BALANCES = {
    { "gems", "Gems" }, { "gold", "Gold" }, { "SummerPearls", "Summer Pearls" },
    { "star_remnant", "Star Remnant" }, { "star_remnant_limited", "Star Remnant (Limited)" }, { "trait", "Trait Rerolls" },
}
local function balanceFields()
    local cols = { {}, {} }
    for i, b in BALANCES do
        local n = totals[b[1]]
        table.insert(cols[i <= 3 and 1 or 2], ("%s%s **%s**"):format(icon(b[1]), b[2], n and commas(n) or "-"))
    end
    return { name = "Balances", value = table.concat(cols[1], "\n"), inline = true },
        { name = "\u{200b}", value = table.concat(cols[2], "\n"), inline = true }
end

function Webhook.embed(rec)
    local rewards = {}
    if (rec.gems or 0) > 0 then table.insert(rewards, gainLine("gems", "Gems", rec.gems)) end
    if (rec.gold or 0) > 0 then table.insert(rewards, gainLine("gold", "Gold", rec.gold)) end
    for k, v in rec.resources or {} do
        if type(v) == "number" and v > 0 then table.insert(rewards, gainLine(k, itemName(k), v)) end
    end
    if (rec.xp or 0) > 0 then table.insert(rewards, ("XP **+%s**"):format(commas(rec.xp))) end
    local drops = {}
    drop_lines(rec.new_units, drops, rec.new_unit_ids or {})
    drop_lines(rec.new_items, drops)
    local stage = rec.stage or STAGE[rec.mode] or (rec.mode and readable(rec.mode)) or "-"
    if tostring(rec.name or ""):find("^Dungeon Room") then stage = "Dungeon Run" end
    local map = rec.map and data("Maps")[rec.map]
    local place = (map and map.name) or (rec.map and readable(rec.map)) or nil
    local summary = { ("**%s** · %s"):format(stage, tostring(rec.difficulty or "-")),
        ("Wave %s/%s"):format(num(rec.waves), num(rec.num_waves)), duration(rec.time) }
    if (rec.kills or 0) > 0 then table.insert(summary, num(rec.kills) .. " kills") end
    if (rec.damage or 0) > 0 then table.insert(summary, short(rec.damage) .. " damage") end
    local description = table.concat(summary, "  ·  ") .. (rec.first_completion and "\n**First clear**" or "")
    local fields = {}
    if #rewards > 0 then table.insert(fields, { name = "Rewards", value = table.concat(rewards, "\n"), inline = false }) end
    if #drops > 0 then table.insert(fields, { name = "Drops", value = table.concat(drops, "\n"):sub(1, 1000), inline = false }) end
    local b1, b2 = balanceFields()
    table.insert(fields, b1)
    table.insert(fields, b2)
    local footer = { tostring(rec.user or ""), levelText() }
    local new_unit = type(rec.new_units) == "table" and #rec.new_units > 0
    return {
        username = "Zeno Hub",
        embeds = { {
            author = author(),
            title = (rec.victory and "Victory - " or "Defeat - ") .. (place and place ~= rec.name and place .. " - " or "") .. tostring(rec.name or stage),
            description = description,
            color = not rec.victory and 0xE74C3C or new_unit and 0x9B59B6 or rec.first_completion and 0xF1C40F or 0x2ECC71,
            fields = fields,
            footer = { text = table.concat(footer, "  ·  ") },
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
    if not u then return line end
    local uid = data("Units")[u] and u or Game.unit_id(u) -- the chest event sends uuids; never show one
    return "Unit: " .. (uid and unitName(uid) or "New unit")
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
        author = author(),
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

local function lastRecord()
    local file = Hub.RunLog and Hub.RunLog.file
    if not file or not isfile(file) then return nil end
    local last
    for line in readfile(file):gmatch("[^\n]+") do last = line end
    local ok, rec = pcall(HttpService.JSONDecode, HttpService, last or "")
    return ok and type(rec) == "table" and rec or nil
end

if Tabs then
    local box = Tabs.Webhook:AddLeftGroupbox("Setting", "webhook")
    box:AddInput("WebhookUrl", {
        Text = "Webhook URL",
        Tooltip = "Discord: Server Settings > Integrations > Webhooks > New Webhook > Copy Webhook URL.",
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
            -- Resends the latest logged run in the current layout; a plain message when nothing is logged yet.
            local rec = lastRecord()
            local payload = rec and Webhook.embed(rec)
                or { username = "Zeno Hub", embeds = { { title = "Test", description = "Webhook works.", color = 0x5865F2, footer = { text = game:GetService("Players").LocalPlayer.Name } } } }
            if rec then payload.content = "Test: the latest logged run, sent again." end
            local ok, code = Webhook.send(payload)
            notify(ok and "test sent" or ("test failed: " .. tostring(code)))
        end)
    end)
    box:AddButton("Export currency icons", function()
        task.spawn(function()
            local ok, done, _, dir = pcall(function() return Hub.require("icons").export() end)
            notify(ok and ("%d icons saved to workspace/%s"):format(#done, dir) or ("export failed: " .. tostring(done)))
        end)
    end)
    local emojiCount = 0
    for _ in cfg.emoji do emojiCount += 1 end
    box:AddInput("WebhookEmoji", {
        Text = ("Currency emoji (%d set)"):format(emojiCount),
        Tooltip = "Optional. Press Export currency icons, upload the PNGs to your Discord server as emoji, send them in a message with a backslash (\\:zh_gems:), then paste the <:zh_gems:123> text here.",
        Default = "",
        Placeholder = "paste <:zh_gems:123...> <:zh_gold:456...>",
        Finished = true,
        Callback = function(v)
            local n = 0
            for name, id in (v or ""):gmatch("<a?:zh_([%w_]+):(%d+)>") do
                cfg.emoji[name] = ("<:zh_%s:%s>"):format(name, id)
                n += 1
            end
            if n > 0 then Core.save_config() end
            notify(n > 0 and (n .. " emoji saved") or "no <:zh_name:id> emoji found")
        end,
    })
    box:AddInput("WebhookDiscordId", {
        Text = "Discord User ID (pings)",
        Tooltip = "Discord: Settings > Advanced > Developer Mode on, then right-click yourself > Copy User ID.",
        Default = cfg.discord_id or "",
        Placeholder = "numeric id, for the ping options",
        Finished = true,
        Callback = function(v)
            v = (v or ""):gsub("%s", "")
            if v ~= "" and not v:match("^%d+$") then return notify("Discord ID must be digits only") end
            cfg.discord_id = v
            Core.save_config()
        end,
    })
    local note = Tabs.Webhook:AddRightGroupbox("Notification", "bell")
    note:AddToggle("WebhookRare", { Text = "Sky God / Explosion Mage / Phoenix Drop", Tooltip = "Pings the Discord User ID when a match drops Sky God, Explosion Mage or Phoenix, or Sky God's or Explosion Mage's Portal. Sent even if Game Finished is off.", Default = cfg.rare, Callback = function(v) cfg.rare = v Core.save_config() end })
    note:AddToggle("WebhookEvolve", { Text = "Unit Ready to Evolve", Tooltip = "Pings the Discord User ID once when an equipped unit's lifetime takedowns reach its evolve requirement (checked in the Info tab loop; the game updates the total after a match).", Default = cfg.evolve, Callback = function(v) cfg.evolve = v Core.save_config() end })
    note:AddToggle("WebhookEnabled", { Text = "Game Finished", Default = cfg.enabled, Callback = function(v) cfg.enabled = v Core.save_config() end })
    note:AddToggle("WebhookChest", { Text = "Dungeon Chest Opened", Tooltip = "After the last dungeon room: the chests opened, your luck, and what the inventory gained.", Default = cfg.chest, Callback = function(v) cfg.chest = v Core.save_config() end })
end

-- Spawned so the HTTP call does not delay match.lua's next/replay on the same game_finished.
local unsub = Core.on("run_finished", function(rec)
    -- Totals first, even with the notification off, so the next report is right.
    for _, d in rec.new_items or {} do if type(d) == "table" and d.item_id then addGain(d.item_id, d.amount) end end
    for k, v in rec.resources or {} do addGain(k, v) end
    addGain("gems", rec.gems) addGain("gold", rec.gold) addGain("xp", rec.xp)
    local hit = cfg.rare and pingDrops(rec) or ""
    local pinged = hit ~= "" and (cfg.discord_id or ""):match("^%d+$")
    if not cfg.enabled and not pinged then return end
    task.spawn(function()
        local payload = Webhook.embed(rec)
        if pinged then
            payload.content = ("<@%s> **%s dropped!**"):format(cfg.discord_id, hit)
            payload.allowed_mentions = { users = { cfg.discord_id } }
        end
        local ok, code = Webhook.send(payload)
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
