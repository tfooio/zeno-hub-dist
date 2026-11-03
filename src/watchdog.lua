-- Stall watchdog (docs/features/summer-update.md): an unattended Auto Summer Hunt that stops moving is retried, then rejoined, and the webhook says so.
-- Lobby: no teleport into a Hunt within Lobby Stall minutes -> retry the join at once, at twice that -> rejoin the lobby. Match (autopilot Hunt): the wave
-- (or the end screen) has not changed for Match Stall minutes -> rejoin the lobby. The rejoin is remembered in the config so the next lobby reports it
-- recovered. A summary of the Hunt rounds goes out every Summary Every hours. Needs a valid URL in the Webhook tab; without one it only logs.
local Hub = ...
local Core = Hub.Core
local env = getgenv()
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer
local LOBBY = Hub.mode == "lobby"

local cfg = Core.config.watchdog or {}
Core.config.watchdog = cfg
local defaults = { enable = true, lobby_min = 5, match_min = 4, summary = true, summary_hours = 24, last_report = 0 }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
if cfg.last_report == 0 then cfg.last_report = os.time() end -- the first summary comes one interval after the first run

local Watchdog = {}
local function alive() return env.ZenoHub == Hub end
local function summerOn() return Core.config.summer and Core.config.summer.enable end

local function notify(title, text, color)
    Core.log("watchdog:", title, text)
    if not Hub.Webhook then return end
    local ok, sent = pcall(Hub.Webhook.send, {
        username = "Zeno Hub",
        embeds = { { title = title, description = ("%s\n%s"):format(LP.Name, text), color = color or 0xF08FB5 } },
    })
    if not ok then Core.log("ERROR watchdog webhook", sent) end
end

-- Summary of the Hunt rounds logged by src/summer.lua (Data/summer_runs.jsonl), newest `hours` hours.
function Watchdog.summary(hours)
    local path = Core.paths.data .. "/summer_runs.jsonl"
    if not isfile(path) then return nil end
    local since = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - hours * 3600)
    local rounds, wins, pearls, secs = 0, 0, 0, 0
    for line in readfile(path):gmatch("[^\n]+") do
        local ok, r = pcall(HttpService.JSONDecode, HttpService, line)
        if ok and type(r) == "table" and type(r.date) == "string" and r.date >= since then
            rounds += 1
            if r.victory then wins += 1 end
            pearls += tonumber(r.rewards and r.rewards.SummerPearls) or 0
            secs += tonumber(r.time) or 0
        end
    end
    if rounds == 0 then return nil end
    local st = LP:FindFirstChild("_stats")
    local have = st and st:FindFirstChild("_resourceSummerPearls")
    return ("Last %d h: %d rounds (%d won, %d lost), %d Summer Pearls from rounds, %.0f min per round%s"):format(
        hours, rounds, wins, rounds - wins, pearls, secs / rounds / 60, have and (", " .. tostring(have.Value) .. " pearls in hand") or "")
end

local function sendSummary()
    local text = Watchdog.summary(cfg.summary_hours)
    if text then notify("Summer Hunt summary", text, 0x57F287) end
    return text
end

-- A rejoin made by the watchdog is reported by the lobby that follows it.
if LOBBY and cfg.pending and type(cfg.pending) == "table" then
    local p = cfg.pending
    cfg.pending = nil
    Core.save_config()
    if os.time() - (p.time or 0) < 1800 then
        task.delay(10, function() if alive() then notify("Recovered", ("Back in the lobby after: %s"):format(tostring(p.text)), 0x57F287) end end)
    end
end

local loadedAt = os.clock()
local stage = 0 -- lobby: 0 none, 1 retried, 2 rejoined
local lastKey, lastChange, warned = nil, os.clock(), false

local function lobbyCheck()
    if not summerOn() or Core.config.summer.role == "Member" then loadedAt = os.clock() stage = 0 return end -- a member waits for the host by design
    local idle = (os.clock() - loadedAt) / 60
    if stage == 0 and idle >= cfg.lobby_min then
        stage = 1
        if Hub.Summer and Hub.Summer.nudge then Hub.Summer.nudge() end
        notify("Stalled in the lobby", ("No Hunt started in %d min, retrying the join."):format(cfg.lobby_min), 0xFEE75C)
    elseif stage == 1 and idle >= cfg.lobby_min * 2 then
        stage = 2
        cfg.pending = { time = os.time(), text = ("lobby stall, no Hunt in %d min"):format(cfg.lobby_min * 2) }
        notify("Stalled in the lobby", "Still no Hunt, rejoining.", 0xED4245)
        if Hub.Misc and Hub.Misc.rejoin then Hub.Misc.rejoin("watchdog: lobby stall") end
    end
end

local function matchCheck()
    if not (Hub.Summer and Hub.Summer.piloting()) then lastChange = os.clock() warned = false return end
    local wave = workspace:FindFirstChild("_wave_num")
    local data = workspace:FindFirstChild("_DATA")
    local fin = data and data:FindFirstChild("GameFinished")
    local key = tostring(wave and wave.Value) .. "/" .. tostring(fin and fin.Value)
    if key ~= lastKey then lastKey, lastChange, warned = key, os.clock(), false return end
    if not warned and (os.clock() - lastChange) / 60 >= cfg.match_min then
        warned = true
        local text = ("no wave change for %d min (wave %s%s)"):format(cfg.match_min, tostring(wave and wave.Value), fin and fin.Value and ", end screen" or "")
        cfg.pending = { time = os.time(), text = text }
        notify("Match stalled", text .. ", rejoining.", 0xED4245)
        if Hub.Misc and Hub.Misc.rejoin then Hub.Misc.rejoin("watchdog: match stall") end
    end
end

task.spawn(function()
    task.wait(15)
    local tick = 0
    while alive() do
        if cfg.enable then
            local ok, err = pcall(LOBBY and lobbyCheck or matchCheck)
            if not ok then Core.log("ERROR watchdog", err) end
        end
        tick += 1
        if tick % 12 == 0 and cfg.summary and os.time() - cfg.last_report >= cfg.summary_hours * 3600 then
            cfg.last_report = os.time()
            Core.save_config()
            pcall(sendSummary)
        end
        task.wait(5)
    end
end)

local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(key) return function(v) cfg[key] = v Core.save_config() end end
    local box = Tabs.Misc:AddLeftGroupbox("Stall Watchdog", "shield")
    box:AddToggle("WatchdogEnable", { Text = "Stall Watchdog", Tooltip = "While Auto Summer Hunt runs: retries a lobby that never starts a Hunt, rejoins a match whose wave stopped, and reports both to the webhook (Webhook tab). Reports 'recovered' after the rejoin.", Default = cfg.enable, Callback = set("enable") })
    box:AddSlider("WatchdogLobby", { Text = "Lobby Stall (minutes)", Tooltip = "No Hunt started after this long: retry. After twice as long: rejoin.", Default = cfg.lobby_min, Min = 2, Max = 30, Rounding = 0, Callback = set("lobby_min") })
    box:AddSlider("WatchdogMatch", { Text = "Match Stall (minutes)", Tooltip = "The wave (or end screen) has not changed this long: rejoin the lobby.", Default = cfg.match_min, Min = 2, Max = 30, Rounding = 0, Callback = set("match_min") })
    box:AddToggle("WatchdogSummary", { Text = "Hunt Summary Webhook", Tooltip = "Sends the rounds, wins and Summer Pearls of the last interval to the webhook.", Default = cfg.summary, Callback = set("summary") })
    box:AddSlider("WatchdogHours", { Text = "Summary Every (hours)", Default = cfg.summary_hours, Min = 1, Max = 48, Rounding = 0, Callback = set("summary_hours") })
    box:AddButton("Send Summary Now", function()
        local text = sendSummary()
        pcall(Hub.UI.Library.Notify, Hub.UI.Library, { Title = "Zeno Hub", Description = text or "No Hunt rounds logged in that time.", Time = 6 })
    end)
end

return Watchdog
