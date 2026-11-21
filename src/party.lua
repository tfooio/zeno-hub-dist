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
local defaults = { follow = false, host = false, names = "", wait = 45, accept = false, server_id = "", server_join = false, server_make = false }
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
            -- Portal pads come ready from use_portal (PortalReady) and may never show Locked = false (UNVERIFIED live).
            if flag(pad, "Owner") == host and (flag(pad, "Locked") == false or flag(pad, "PortalReady") == true) and not flag(pad, "Teleporting") then
                local ret = Game.invoke("request_join_lobby", pad.Name)
                Core.log("party: join", host.Name, pad.Name, tostring(ret))
                if ret ~= true then retryAt = os.clock() + 5 end
                return
            end
        end
    end
end

function Party.following() return cfg.follow end

-- The game's own party system (2026-11-03, read from its client code): party_invite(player), party_respond_invite(inviter, accept),
-- party_leave, party_kick(player); players carry the PartyId attribute. The invite prompt of the game calls GUIService.party_ui:respond_invite(inviter, true, true).
-- UNVERIFIED live: needs a second account in the same lobby server (the argument formats come from the game's UI code).
local function partyId(p) return p:GetAttribute("PartyId") end
function Party.size() -- players in this server in my party, me included
    local id = partyId(LP)
    if not id then return 1 end
    local n = 0
    for _, p in Players:GetPlayers() do if partyId(p) == id then n += 1 end end
    return n
end
local function missing() -- listed players in this server that are not in my party
    local out, id = {}, partyId(LP)
    for _, p in listed() do if not id or partyId(p) ~= id then table.insert(out, p) end end
    return out
end
local invitedAt = {}
local function invite()
    for _, p in missing() do
        if os.clock() - (invitedAt[p] or -99) > 20 then
            invitedAt[p] = os.clock()
            Core.log("party: invite", p.Name, tostring(Game.invoke("party_invite", p)))
        end
    end
end

-- How many listed names are not in this server yet (the other account is still loading into the lobby).
function Party.absent()
    local n = 0
    for _ in cfg.names:gmatch("[^,;%s]+") do n += 1 end
    return math.max(0, n - #listed())
end

-- Host side: invite the listed players and wait until every one of them in the server is in the party (or the time runs out).
function Party.fill(limit)
    local want = listed()
    if #want == 0 then return false end
    local t = os.clock()
    while alive() and os.clock() - t < limit do
        if #missing() == 0 then Core.log("party: everyone is in the party,", Party.size(), "players") return true end
        invite()
        task.wait(1)
    end
    Core.log("party: not everyone joined, going with", Party.size())
    return false
end

-- Host Mode: the joiner calls this before it opens a pad, so the members are in the party (and get pulled onto the pad). Instant when they already are.
-- It also waits (up to 40 s) for the listed player to be in this lobby: the other account loads a few seconds later, and the host used to open the portal alone (20:51).
function Party.prepare()
    if not cfg.host then return end
    local t = os.clock()
    while alive() and Party.absent() > 0 and os.clock() - t < 40 do task.wait(1) end
    if Party.absent() > 0 then Core.log("party: listed player not in the lobby after 40 s, going without") end
    Party.fill(cfg.wait)
end

-- Member side: accept an invite that comes from a listed player.
local function acceptInvites()
    local ok, ui = pcall(function() return Game.loader().load_client_service(script, "GUIService").party_ui end)
    if not (ok and ui and ui.incoming_invites) then return end
    local ok_to = {}
    for _, p in listed() do ok_to[p] = true end
    for p in ui.incoming_invites do
        if ok_to[p] then
            Core.log("party: accepting the invite of", p.Name)
            local done = pcall(function() ui:respond_invite(p, true, true) end)
            if not done then Game.invoke("party_respond_invite", p, true) end
        end
    end
end

-- Called by the joiner after it picked a level and before request_start_game: with Host Mode on, wait until every
-- listed player in the server is on the pad (or Host Wait runs out, always before the pad's own timer), then go.
function Party.wait_for_party(pad)
    if not cfg.host then return end
    local want = listed()
    if #want == 0 then return end
    local limit = math.min(cfg.wait, math.max(0, (flag(pad, "Timer") or 0) - 3))
    local t = os.clock()
    while alive() and os.clock() - t < limit do
        invite() -- a broken party re-forms here (throttled to one invite per player per 20 s); the member accepts with Auto Accept Party Invite
        local m, all = members(pad), true
        for _, p in want do if not m[p] then all = false end end
        if all then Core.log("party: everyone is on the pad, starting", pad.Name) return true end
        task.wait(0.25)
    end
    Core.log("party: wait over, starting without everyone", pad.Name)
end

-- Servers (competitor parity, 2026-11-10): the game's own player servers (HubGUI), read from its client code.
-- hub_get_state -> { current = { locked, type [, id] }, mine = { id, locked, inside }, saved = {...} } (shape checked live, lobby);
-- hub_join_id(id) and hub_my_server() teleport, hub_create() makes the server, hub_set_locked(bool). UNVERIFIED live: the three teleporting calls.
-- shortcut: three tries (15 s apart) per ID, then the joiners go ahead; there is no way to look an ID up first.
-- Pending from the start when a server option is on, so a joiner cannot slip in before the first check.
local srvPending, srvTried, srvFails, srvLast = ((cfg.server_join and cfg.server_id ~= "") or cfg.server_make) and "server check" or nil, -99, 0, ""
local function hubState()
    local ok, res = pcall(Game.invoke, "hub_get_state")
    if ok and type(res) == "table" then return res end
end
local function srvCall(name, ...)
    srvTried = os.clock()
    Core.save_config() -- a teleport may follow (OnTeleport does not fire)
    local ok, ret = pcall(Game.invoke, name, ...)
    Core.log("server:", name, ok, tostring(ret))
end
local function serverStep()
    local st = hubState()
    srvPending = nil
    if not st then return end
    local want = cfg.server_id:match("^%s*(.-)%s*$")
    if want ~= srvLast then srvLast, srvFails = want, 0 end
    local cur = st.current and st.current.id
    if cfg.server_join and want ~= "" and cur ~= want and srvFails < 3 then
        srvPending = "server " .. want
        if os.clock() - srvTried > 15 then
            srvFails += 1
            srvCall("hub_join_id", want)
        end
        return
    end
    if cfg.server_make then
        local mine = st.mine
        if not mine then
            srvPending = "own server"
            if os.clock() - srvTried > 15 then srvCall("hub_create") end
        elseif not mine.inside then
            srvPending = "own server"
            if os.clock() - srvTried > 15 then srvCall("hub_my_server") end
        elseif mine.locked and os.clock() - srvTried > 5 then
            srvCall("hub_set_locked", false)
        end
    end
end
-- Lobby.hold (src/lobby.lua): the joiners wait while this names a server we are still on our way to.
function Party.server_pending() return srvPending end

if Hub.mode == "lobby" then
    task.spawn(function()
        while alive() do
            if (cfg.server_join and cfg.server_id ~= "") or cfg.server_make then
                local ok, err = xpcall(serverStep, debug.traceback)
                if not ok then Core.log("ERROR party server", err) end
            else
                srvPending = nil
            end
            task.wait(5)
        end
    end)
    task.spawn(function()
        task.wait(5)
        while alive() do
            -- Host Mode keeps the party formed in the lobby by itself (user, 2026-11-20: the invite was only sent while a joiner or the Hunt was opening a pad).
            if cfg.host and cfg.names ~= "" and #missing() > 0 then invite() end
            if cfg.follow then
                local ok, err = xpcall(follow, debug.traceback)
                if not ok then Core.log("ERROR party", err) end
            end
            if cfg.accept and not partyId(LP) then
                local ok, err = xpcall(acceptInvites, debug.traceback)
                if not ok then Core.log("ERROR party accept", err) end
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
    box:AddToggle("PartyAccept", { Text = "Auto Accept Party Invite", Tooltip = "Accepts a game party invite from a listed player (lobby). The host account invites with Summer > Multi Farm Role = Host.", Default = cfg.accept, Callback = set("accept") })
    box:AddToggle("PartyHost", { Text = "Host Mode", Tooltip = "The joiners wait for the listed players to be on the pad before starting the teleport.", Default = cfg.host, Callback = set("host") })
    box:AddSlider("PartyWait", { Text = "Host Wait (second)", Tooltip = "Longest the host waits for the party; it starts without them after that.", Default = cfg.wait, Min = 5, Max = 65, Rounding = 0, Callback = set("wait") })

    local srv = Tabs.Joiner:AddRightGroupbox("Server", "server")
    srv:AddInput("ServerId", { Text = "Server ID", Tooltip = "The ID of a player server (like XXXX-XXXX, from the game's Servers menu or the host's Copy My Server ID button).", Default = cfg.server_id, Placeholder = "XXXX-XXXX", Finished = true, Callback = function(v)
        cfg.server_id = (v or ""):match("^%s*(.-)%s*$")
        Core.save_config()
    end })
    srv:AddToggle("ServerJoin", { Text = "Auto Join Server", Tooltip = "Goes to that server whenever you are in another lobby. The joiners wait until you are there; after 3 failed tries (wrong ID, locked or full server) they go ahead.", Default = cfg.server_join, Callback = set("server_join") })
    srv:AddToggle("ServerMake", { Text = "Host My Server", Tooltip = "Makes your player server if you have none, goes into it and unlocks it so your other accounts can join. The joiners wait until you are in it.", Default = cfg.server_make, Callback = set("server_make") })
    srv:AddButton({ Text = "Copy My Server ID", Tooltip = "Copies your player server's ID, to paste into Server ID on your other accounts.", Func = function()
        local st = hubState()
        local id = st and st.mine and st.mine.id
        if not id then return pcall(Hub.UI.Library.Notify, Hub.UI.Library, { Title = "Zeno Hub", Description = "You have no player server yet (turn on Host My Server).", Time = 5 }) end
        if setclipboard then setclipboard(id) end
        pcall(Hub.UI.Library.Notify, Hub.UI.Library, { Title = "Zeno Hub", Description = "Server ID copied.", Time = 5 })
    end })
end

return Party
