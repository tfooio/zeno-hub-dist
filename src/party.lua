-- Party farming (Joiner tab, docs/features/lobby-tab.md): Follow joins the pad of a listed player, Host Mode makes the
-- joiners (src/joiner.lua) wait for the listed players to be on the pad before starting.
-- Options live in Core.config.party (hub.json).
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()
local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local cfg = Core.config.party or {}
Core.config.party = cfg
local defaults = { follow = false, host = false, names = "", wait = 45 }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local Party = {}
local function alive() return env.ZenoHub == Hub end

-- Listed names -> players in this server now (exact name or display name first, then a prefix; any case).
local function listed()
    local out, seen = {}, {}
    for token in cfg.names:gmatch("[^,;%s]+") do
        local t, hit = token:lower(), nil
        for _, p in Players:GetPlayers() do
            if p ~= LP and (p.Name:lower() == t or p.DisplayName:lower() == t) then hit = p break end
        end
        if not hit then
            for _, p in Players:GetPlayers() do
                if p ~= LP and (p.Name:lower():find(t, 1, true) == 1 or p.DisplayName:lower():find(t, 1, true) == 1) then hit = p break end
            end
        end
        if hit and not seen[hit] then seen[hit] = true table.insert(out, hit) end
    end
    return out
end

-- Pad folders (docs/remotes.md); each pad lists its members as ObjectValues in pad.Players.
local PAD_FOLDERS = { { "_LOBBIES", "Story" }, { "_RAID", "Raid" }, { "_CHALLENGES", "Challenges" }, { "_CHALLENGES", "DailyChallenge" },
    { "_EVENT_CHALLENGES", "Lobbies" }, { "_DUNGEONS", "Lobbies" }, { "_PORTALS", "Lobbies" }, { "_MAPS", "Maps" } }
local function pads()
    local out = {}
    for _, path in PAD_FOLDERS do
        local f = workspace:FindFirstChild(path[1])
        f = f and f:FindFirstChild(path[2])
        for _, pad in f and f:GetChildren() or {} do table.insert(out, pad) end
    end
    return out
end
local function members(pad)
    local set, f = {}, pad:FindFirstChild("Players")
    for _, v in f and f:GetChildren() or {} do if v:IsA("ObjectValue") and v.Value then set[v.Value] = true end end
    return set
end
local function flag(pad, name) local v = pad:FindFirstChild(name) return v and v.Value end

-- Follow: join the first open pad owned by a listed player. Open = the owner has locked a level in (Locked is
-- false) and the pad is not teleporting. A refused join (not a Roblox friend of the host with Friends Only, pad
-- full) is retried after a pause.
local retryAt = 0
local function follow()
    if os.clock() < retryAt then return end
    local all = pads()
    for _, pad in all do if members(pad)[LP] then return end end -- already on a pad
    for _, host in listed() do
        for _, pad in all do
            if flag(pad, "Owner") == host and flag(pad, "Locked") == false and not flag(pad, "Teleporting") then
                local ret = Game.invoke("request_join_lobby", pad.Name)
                Core.log("party: join", host.Name, pad.Name, tostring(ret))
                if ret ~= true then retryAt = os.clock() + 5 end
                return
            end
        end
    end
end

function Party.following() return cfg.follow end

-- Called by the joiner after it picked a level and before request_start_game: with Host Mode on, wait until every
-- listed player in the server is on the pad (or Host Wait runs out, always before the pad's own timer), then go.
function Party.wait_for_party(pad)
    if not cfg.host then return end
    local want = listed()
    if #want == 0 then return end
    local limit = math.min(cfg.wait, math.max(0, (flag(pad, "Timer") or 0) - 3))
    local t = os.clock()
    while alive() and os.clock() - t < limit do
        local m, all = members(pad), true
        for _, p in want do if not m[p] then all = false end end
        if all then Core.log("party: everyone is on the pad, starting", pad.Name) return true end
        task.wait(0.25)
    end
    Core.log("party: wait over, starting without everyone", pad.Name)
end

if Hub.mode == "lobby" then
    task.spawn(function()
        task.wait(5)
        while alive() do
            if cfg.follow then
                local ok, err = xpcall(follow, debug.traceback)
                if not ok then Core.log("ERROR party", err) end
            end
            task.wait(1.5)
        end
    end)
end

local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(key) return function(v) cfg[key] = v Core.save_config() end end
    local box = Tabs.Joiner:AddRightGroupbox("Party Farming", "users")
    box:AddInput("PartyNames", { Text = "Party Player", Tooltip = "Username (or display name) of who to follow, or who the host waits for. Several: separate with commas.", Default = cfg.names, Placeholder = "username, then Enter", Finished = true, Callback = function(v)
        cfg.names = (v or ""):match("^%s*(.-)%s*$")
        Core.save_config()
    end })
    box:AddToggle("PartyFollow", { Text = "Follow Host", Tooltip = "Joins the pad of a listed player as soon as they have picked a level. Turn the joiners off on this account.", Default = cfg.follow, Callback = set("follow") })
    box:AddToggle("PartyHost", { Text = "Host Mode", Tooltip = "The joiners wait for the listed players to be on the pad before starting the teleport.", Default = cfg.host, Callback = set("host") })
    box:AddSlider("PartyWait", { Text = "Host Wait (second)", Tooltip = "Longest the host waits for the party; it starts without them after that.", Default = cfg.wait, Min = 5, Max = 65, Rounding = 0, Callback = set("wait") })
end

return Party
