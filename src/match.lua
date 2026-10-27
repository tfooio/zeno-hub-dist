-- Match flow (Auto tab): auto vote start, auto wave skip, next / replay / lobby after game_finished, anti-AFK.
-- Options live in Core.config.auto (hub.json) so they survive every teleport without a SaveManager config.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local LP = game:GetService("Players").LocalPlayer
local VirtualUser = game:GetService("VirtualUser")
local env = getgenv()

local cfg = Core.config.auto or {}
Core.config.auto = cfg
cfg.finish = nil -- replaced by the next/replay/lobby toggles
local defaults = { vote_start = false, wave_skip = false, skip_stop = 0, skip_types = {}, next = false, replay = false, lobby = false, finish_delay = 3, anti_afk = true, load_failsafe = true, load_timeout = 60 }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local function alive() return env.ZenoHub == Hub end
local function call(name, ...)
    local ok, res = pcall(Game.invoke, name, ...)
    if not ok then Core.log("ERROR", name, res) end
    return ok, res
end

local Match = {}

-- UI
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(key) return function(v) cfg[key] = v Core.save_config() end end
    local play = Tabs.Game:AddLeftGroupbox("Gameplay", "gamepad-2")
    play:AddToggle("AutoVoteStart", { Text = "Auto Vote Start", Default = cfg.vote_start, Callback = set("vote_start") })
    local skip = Tabs.Game:AddLeftGroupbox("Auto Skip Wave", "fast-forward")
    skip:AddToggle("AutoWaveSkip", { Text = "Auto Skip Wave", Tooltip = "Turns on the game's own Auto Skip Wave setting and votes skip.", Default = cfg.wave_skip, Callback = set("wave_skip") })
    skip:AddSlider("AutoSkipStop", { Text = "Stop Skip at Wave", Tooltip = "Turn Auto Skip off from this wave on. 0 = never stop. Only in the stage types below.", Default = cfg.skip_stop, Min = 0, Max = 100, Rounding = 0, Callback = set("skip_stop") })
    skip:AddDropdown("AutoSkipTypes", { Text = "Select Stage Type", Tooltip = "Where Stop Skip at Wave applies; other types keep skipping.", Values = Game.STAGE_TYPES, Multi = true, Default = Core.keys(cfg.skip_types), Callback = set("skip_types") })
    local fin = Tabs.Game:AddRightGroupbox("Game Finished", "flag")
    fin:AddLabel("Tries the first available of Next, Replay, Lobby.", true)
    fin:AddToggle("AutoNext", { Text = "Auto Next", Default = cfg.next, Callback = set("next") })
    fin:AddToggle("AutoReplay", { Text = "Auto Replay", Default = cfg.replay, Callback = set("replay") })
    fin:AddToggle("AutoLobby", { Text = "Auto Return Lobby", Default = cfg.lobby, Callback = set("lobby") })
    fin:AddSlider("AutoFinishDelay", { Text = "Delay (s)", Default = cfg.finish_delay, Min = 0, Max = 30, Rounding = 0, Callback = set("finish_delay") })
    local secure = Tabs.Misc:AddLeftGroupbox("Secure", "shield")
    Hub.SecureBox = secure -- src/misc.lua adds Walk Around here
    secure:AddToggle("AntiAfk", { Text = "Anti-AFK", Default = cfg.anti_afk, Callback = set("anti_afk") })
    secure:AddToggle("LoadFailsafe", { Text = "Loading Failsafe", Tooltip = "If the game's loading screen stays up for the time below, teleport to the lobby.", Default = cfg.load_failsafe, Callback = set("load_failsafe") })
    secure:AddSlider("LoadTimeout", { Text = "Loading Timeout (s)", Default = cfg.load_timeout, Min = 30, Max = 300, Rounding = 0, Callback = set("load_timeout") })
end

-- Loading failsafe: the game's own PlayerGui.Loading screen stuck up means the teleport or spawn hung (seen
-- 2026-10-26: dungeon room loaded, no character, screen never closed). TeleportService works whatever the
-- server is doing, unlike the teleport_back_to_lobby remote. Retries after another full timeout.
local LOBBY_PLACE = 8304191830
local TeleportService = game:GetService("TeleportService")
task.spawn(function()
    local pg = LP:WaitForChild("PlayerGui")
    local since
    while alive() do
        task.wait(1)
        local gui = pg:FindFirstChild("Loading")
        if cfg.load_failsafe and gui and gui.Enabled then
            since = since or os.clock()
            if os.clock() - since >= cfg.load_timeout then
                since = os.clock()
                Core.log("loading failsafe: loading screen up for", cfg.load_timeout, "s, teleporting to the lobby")
                Core.save_config() -- before the teleport (OnTeleport does not fire)
                local ok, err = pcall(TeleportService.Teleport, TeleportService, LOBBY_PLACE)
                if not ok then Core.log("ERROR loading failsafe:", err) end
            end
        else
            since = nil
        end
    end
end)

table.insert(Hub.connections, LP.Idled:Connect(function()
    if not cfg.anti_afk then return end
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end))

if Hub.mode ~= "match" then return Match end

-- Same checks the game's end screen uses to show its Next / Replay buttons.
local function can_next(victory)
    local L = Game.loader()
    local ld = L.LevelData
    return ld._is_actual_storymode and victory
        and L.load_core_service(script, "ProgressionServiceCore").get_next_story_level(ld.id) ~= nil
end
local function can_replay(victory)
    local L = Game.loader()
    local ld = L.LevelData
    -- shortcut: portals, contracts, dungeons and infinite tower need a pick UI; skipped until their own chats.
    if ld._is_map_or_portal_level or ld._event_contract or ld._dungeon or ld._gamemode == "infinite_tower" then return false end
    if ld._is_actual_storymode and victory then return true end
    return Game.data("GameplaySettings").REPLAY_GAMEMODES[ld._gamemode]
        or L.load_core_service(script, "LevelServiceCore").level_can_replay(ld, victory)
end

-- Ordered list of finish calls that are enabled and available; each is a fallback for the one before.
function Match.finish_chain(victory)
    -- Lobby tab: a selected summon target just became featured, so skip replay / next and go summon.
    if Hub.Lobby then
        local ok, want = pcall(Hub.Lobby.want_lobby)
        if ok and want then return { { "teleport_back_to_lobby" } } end
    end
    local chain = {}
    local function check(fn)
        local ok, res = pcall(fn, victory)
        if not ok then Core.log("ERROR finish check:", res) end
        return ok and res
    end
    if cfg.next and check(can_next) then table.insert(chain, { "set_game_finished_vote", "next_story" }) end
    if cfg.replay and check(can_replay) then table.insert(chain, { "set_game_finished_vote", "replay" }) end
    if cfg.lobby then table.insert(chain, { "teleport_back_to_lobby" }) end
    return chain
end

local s2c = game:GetService("ReplicatedStorage"):WaitForChild("endpoints"):WaitForChild("server_to_client")

table.insert(Hub.connections, s2c:WaitForChild("game_finished").OnClientEvent:Connect(function(result)
    local victory = type(result) == "table" and result.victory
    Core.emit("game_finished", result)
    -- A dungeon run ends its own matches (src/dungeon.lua): shop / shrine / chest first, then the next room.
    if Hub.Dungeon and Hub.Dungeon.owns_finish() then return Core.log("game_finished: dungeon module takes over") end
    local chain = Match.finish_chain(victory)
    Core.log("game_finished victory:", victory, "chain:", #chain)
    if #chain == 0 then return end
    task.delay(cfg.finish_delay, function()
        -- Teleports happen from here: persist state first (OnTeleport does not fire).
        cfg.runs = (cfg.runs or 0) + 1
        Core.save_config()
        -- A call that does not teleport within 15 s falls through to the next one.
        for _, a in chain do
            if not alive() then return end
            Core.log("finish", a[1], a[2] or "", "run", cfg.runs)
            call(table.unpack(a))
            task.wait(15)
        end
    end)
end))

-- Auto Skip: the game's own setting does the voting (it kept voting with our votes off), so the stop wave
-- turns that setting off for the rest of the match; it is turned back on at the next match load.
local stageType = Game.stage(Game.loader().LevelData)
local function skipStopped()
    return cfg.skip_stop > 0 and stageType and cfg.skip_types[stageType] and workspace._wave_num.Value >= cfg.skip_stop
end
-- The profile is not readable in a match, so remember what this match already sent.
local sentSkip
local function setGameSkip(on)
    if sentSkip == on then return end
    sentSkip = on
    -- Right after the match loads the server has no profile yet and errors; retry for up to 30 s.
    for _ = 1, 15 do
        if not alive() or sentSkip ~= on then return end
        if pcall(Game.invoke, "toggle_setting", "autoskip_waves", on) then
            return Core.log("auto skip setting", on, "wave", workspace._wave_num.Value)
        end
        task.wait(2)
    end
    Core.log("ERROR auto skip setting not accepted", on)
end
if cfg.wave_skip and not skipStopped() then task.spawn(setGameSkip, true) end
table.insert(Hub.connections, workspace:WaitForChild("_wave_num").Changed:Connect(function()
    if cfg.wave_skip and skipStopped() then setGameSkip(false) end
end))
table.insert(Hub.connections, s2c:WaitForChild("start_vote_wave_skip").OnClientEvent:Connect(function()
    if cfg.wave_skip and not skipStopped() then call("vote_wave_skip") end
end))

-- Vote start: story auto-starts; other modes wait in "Vote start" until someone votes.
-- The server errors on votes sent in the first seconds after load, so keep retrying until voting ends.
task.spawn(function()
    local data = workspace:WaitForChild("_DATA", 30)
    local vf = data and data:WaitForChild("VoteStart", 10)
    vf = vf and vf:WaitForChild("VotingFinished", 10)
    while alive() and vf and not vf.Value do
        if cfg.vote_start then pcall(Game.invoke, "vote_start") end
        task.wait(2)
    end
end)

return Match
