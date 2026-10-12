--[[
    +1 DMG Per Revive
    Interface: WindUI (pinned version 1.6.66). If WindUI fails to load,
    a small native interface takes over (Right Ctrl to hide, configurable).

    One cycle (redone only after a rebirth):
      1. enterMainChallengeReq
      2. hit the enemies of workspace.Enemies in order (1, 2, 3…); move on
         to the next one as soon as the server's attackResult arrives (~0.2 s), without waiting
         for the model to disappear; done when MainLevelRootFolder's Locker disappears
      3. bosses set to Auto (teleport + challenge; Nightmare + setAfkResumeReq), relaunched on a loss
      4. time or level reached: quitTimeLimitChallengeReq + leaveChallengeReq,
         no more bosses relaunched, then rebirth, then a new cycle
]]

-- // Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local VirtualUser = game:GetService("VirtualUser")

local localPlayer = Players.LocalPlayer

-- // Clean relaunch: if the script is already running, stop the old instance
local env = (getgenv and getgenv()) or _G
if type(env.__FarmBossRebirthStop) == "function" then
    pcall(env.__FarmBossRebirthStop)
end

local running = true
local connections = {}

-- ========================================================
-- SETTINGS
-- ========================================================
local WINDUI_URL = "https://github.com/Footagesus/WindUI/releases/download/1.6.66/main.lua"

local WAVE_TIMEOUT = 600    -- max s for a wave (safety)
local FIGHT_TIMEOUT = 1.5   -- max s without attackResult before hitting again (normal reply: 0.1 to 0.25 s)
local MAX_TIMEOUTS = 3      -- no reply this many times: skip this enemy
-- Measured in game: an attack sent less than 0.2 s after the previous one is ignored
-- by the server (0/4 at 0.1 s, 4/4 at 0.2 s). Small extra margin.
local ATTACK_GAP = 0.22
local WAVE_IDLE_TIMEOUT = 20 -- s without any enemy to hit before giving up the wave

local LEVELS = { "+1", "+5", "+10", "+50" }  -- value sent = index - 1
local LEVEL_STEPS = { 1, 5, 10, 50 }
-- Nightmare only: "Custom" (index 4) = jump of N floors, N sent as 3rd argument.
-- The game restricts it to Ascension 10+ and accepts N from 1 to 500.
local NIGHTMARE_LEVELS = { "+1", "+5", "+10", "+50", "Custom" }
local CUSTOM_IDX = 4
local CUSTOM_MAX = 500
-- 1 = as soon as the Nightmare level required by the game is reached, 2 = every X s, 3 = whichever comes first
local REBIRTH_MODES = { "Required level (auto)", "Timer", "Timer OR required level" }
local MODE_LEVEL, MODE_TIMER = 1, 2

local BOSSES = {
    { id = 1, name = "Death King", path = { "lobby", "dynamic", "DeathKnight", "Part" } },
    { id = 2, name = "Cursed King", path = { "lobby", "dynamic", "CurseKing", "Part" } },
    { id = 3, name = "Nightmare", path = { "TowerBattle", "Enemy", "Part" } },
}

local states = {
    autoAttack = false,
    attackDelay = 0,    -- s pause after each enemy killed
    maxHits = 3,        -- max tries on an enemy before stopping the wave (too strong)

    bossAuto = { [1] = false, [2] = false, [3] = false },
    -- Nightmare at +50: this is the MAX jump, reduced automatically to land exactly on the required level
    bossLevel = { [1] = 0, [2] = 0, [3] = 3 },
    bossDelay = 1,      -- s wait after each boss
    tpDistance = 30,    -- studs: TP (boss or enemy) only if we are farther than this
    bossRetry = 45,     -- s: relaunch the boss at the latest after this time (fight ~37 s). 0 = never

    autoRebirth = false,
    rebirthMode = 1,
    rebirthInterval = 60,
    customStep = 50,    -- Nightmare in Custom: jump of N floors (1 to 500)
    rebirthMinLevel = 0, -- rebirth at the higher of this level and the game's required one (0 = the required one)

    antiAfk = true,
    walkSpeedOn = false, -- forced walk speed
    walkSpeed = 50,      -- Roblox default: 16
    toggleKey = Enum.KeyCode.RightControl, -- key to show / hide the menu
}

local status = { phase = "Paused", waves = 0, rebirths = 0, lastBoss = "-", lastFight = "-" }

-- One cycle = the wave (once) + each boss set to Auto (once), then wait for the rebirth.
-- gen changes on each new cycle: an action from an old cycle can no longer validate anything.
local cycle = { gen = 0, waveDone = false, bossDone = {}, leaving = false }
local lastRebirth = -math.huge -- last real rebirth (MIN_REBIRTH_GAP anti-spam)
local timerFrom = os.clock()    -- Timer start (Timer modes): separate, so it doesn't block the level rebirth
local MIN_REBIRTH_GAP = 10 -- min s between two rebirths (anti-spam)

-- Manual buttons: queued, the main loop runs them (never in parallel)
local pending = { rebirth = false, bosses = {} }

local function resetCycle()
    cycle.gen = cycle.gen + 1
    cycle.waveDone = false
    cycle.bossDone = {}
    cycle.leaving = false
end

-- ========================================================
-- REMOTES
-- ========================================================
local function getRemoContainer()
    local ok, res = pcall(function()
        return ReplicatedStorage.rbxts_include.node_modules["@rbxts"].remo.src.container
    end)
    if ok and res then return res end
    return ReplicatedStorage:FindFirstChild("container", true)
end

local remoteCache = {}
local function getRemote(name)
    local cached = remoteCache[name]
    if cached and cached.Parent then return cached end

    local remote
    local container = getRemoContainer()
    if container then remote = container:FindFirstChild(name) end
    if not remote then
        for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
            if d.Name == name and d:IsA("BaseRemoteEvent") then
                remote = d
                break
            end
        end
    end
    remoteCache[name] = remote
    return remote
end

-- Protected FireServer; keeps explicit nils (setAfkResumeReq(3, 0, nil))
local function fire(name, ...)
    local remote = getRemote(name)
    if not remote then return false end
    local args = table.pack(...)
    return (pcall(function()
        remote:FireServer(table.unpack(args, 1, args.n))
    end))
end

-- ========================================================
-- GAME: Nightmare level, rebirth, teleport
-- ========================================================
local battleStore
local function getNightmareLevel()
    local ok, lvl = pcall(function()
        battleStore = battleStore or require(ReplicatedStorage.common.store.battle)
        return battleStore.AtomTowerLevel()()
    end)
    if ok and type(lvl) == "number" then return lvl end
    return 0
end

-- Nightmare (Death Tower) level required by the game for the next rebirth.
-- Same calculation as the game's Rebirth panel: rebirthTowerLevelRatio × (rebirths + 1)
-- (measured in game: ratio 5, so 95 at the 19th rebirth). nil if unreadable.
local towerRatio, rebirthStore

-- Number of rebirths read from the game's store (nil if unreadable)
local function rebirthCount()
    local ok, n = pcall(function()
        rebirthStore = rebirthStore or require(ReplicatedStorage.common.store.rebirth)
        return rebirthStore.AtomRebirth()()
    end)
    if ok and type(n) == "number" then return n end
    return nil
end

local function requiredLevel()
    local ok, req = pcall(function()
        towerRatio = towerRatio or require(ReplicatedStorage.common.deps.config).SingleConfig
            :TbGlobalConfig():rebirthTowerLevelRatio()
        rebirthStore = rebirthStore or require(ReplicatedStorage.common.store.rebirth)
        return towerRatio * (rebirthStore.AtomRebirth()() + 1)
    end)
    if ok and type(req) == "number" and req > 0 then return req end
    return nil
end

-- Death Road progress read from the game's store: AtomMainLevel = number of enemies
-- beaten since the rebirth (0 to 15), so the next one to beat is mainLevel + 1.
-- It is also what spawns the Lockers (the game's MainLevel component).
-- Returns (level, total) or nil if unreadable.
local mainTotal
local function mainProgress()
    local ok, lvl, total = pcall(function()
        battleStore = battleStore or require(ReplicatedStorage.common.store.battle)
        mainTotal = mainTotal or #require(ReplicatedStorage.common.deps.config).SingleConfig
            :TbMainChallenge():getDataList()
        return battleStore.AtomMainLevel()(), mainTotal
    end)
    if ok and type(lvl) == "number" and type(total) == "number" and total > 0 then return lvl, total end
    return nil
end

-- true if a boss fight (time limit) is in progress; nil if unreadable
local battleUtil
local function inBossFight()
    local ok, res = pcall(function()
        battleStore = battleStore or require(ReplicatedStorage.common.store.battle)
        battleUtil = battleUtil or require(ReplicatedStorage.common.util["battle-util"])
        return battleUtil.IsTimeLimitChallengeMode(battleStore.AtomBattleState())
    end)
    if ok then return res == true end
    return nil
end

-- Level at which to rebirth: the higher of the chosen level and the game's required one.
-- E.g. chosen 250: required 35 -> 250; required 260 -> 260 (we climb to 250 then +10).
local function rebirthLevel()
    local req = requiredLevel()
    local min = states.rebirthMinLevel
    if not req then return min > 0 and min or nil end
    return math.max(req, min)
end

local function fireRebirth()
    if fire("rebirth") then return true end
    return (pcall(function()
        require(ReplicatedStorage.common.remotes.player).PlayerRemotes.rebirth:fire()
    end))
end

-- The game's BattleController (Flamework), found once in the client's memory
local battleController
local function getBattleController()
    if battleController then return battleController end
    if not getgc then return nil end
    local ok = pcall(function()
        for _, v in ipairs(getgc(true)) do
            if type(v) == "table" and rawget(v, "TeleportController") and rawget(v, "alterController")
                and type(v.enterTowerChallenge) == "function" then
                battleController = v
                break
            end
        end
    end)
    return ok and battleController or nil
end

-- Measured in game: the Nightmare scene (workspace.TowerBattle) only exists once the
-- game has entered it itself. After joining, it is missing: no TP, and the fight
-- starts on the server without us (lost). So we go through the game's function
-- (~1 s cutscene, scene creation, TP onto the player's tile).
local function enterTowerScene()
    if workspace:FindFirstChild("TowerBattle") then return false end
    local ctrl = getBattleController()
    if not ctrl then return false end
    local ok, res = pcall(ctrl.enterTowerChallenge, ctrl)
    return ok and res == true
end

local function teleportToBoss(boss)
    if boss.id == 3 and enterTowerScene() then return true end
    local node = workspace
    for _, name in ipairs(boss.path) do
        node = node:FindFirstChild(name)
        if not node then return false end
    end
    local char = localPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (hrp and node:IsA("PVInstance")) then return false end
    -- Already near the block: no need to teleport
    local target = node:GetPivot()
    if (hrp.Position - target.Position).Magnitude <= states.tpDistance then return false end
    hrp.CFrame = target + Vector3.new(0, 3, 0)
    return true
end

-- ========================================================
-- ENEMY TRACKING (re-read continuously, never an old snapshot)
-- ========================================================
local tracker = {
    alive = {},     -- [id] = true if alive at the last scan
    list = {},      -- sorted alive ids
    ids = {},       -- all numbered ids in the folder, sorted
    inFolder = 0,   -- numbered enemies present in workspace.Enemies
    lockers = -1,   -- Lockers remaining in MainLevelRootFolder (-1 = folder not found)
}
-- endedAt / blockedAt: when the last wave ended, and when it stopped on an enemy that is too strong
local wave = { kills = 0, endedAt = -math.huge, blockedAt = -math.huge }

local DEAD_FLAGS = { "Dead", "dead", "IsDead", "isDead" }
local HP_NAMES = { "Health", "health", "HP", "Hp", "hp", "CurrentHealth" }

local function isAliveModel(model)
    for _, key in ipairs(DEAD_FLAGS) do
        if model:GetAttribute(key) == true then return false end
    end
    for _, key in ipairs(HP_NAMES) do
        local attr = model:GetAttribute(key)
        if type(attr) == "number" and attr <= 0 then return false end
        local value = model:FindFirstChild(key)
        if value and (value:IsA("NumberValue") or value:IsA("IntValue")) and value.Value <= 0 then
            return false
        end
    end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return false end
    -- The health bar switches to "0/7.6K" as soon as the result arrives, ~1 s before the model disappears
    local bar = model:FindFirstChild("HealthBar")
    local hpText = bar and bar:FindFirstChild("hpText")
    if hpText and hpText:IsA("TextLabel") and hpText.Text:match("^0/") then return false end
    return true
end

local function scanEnemies()
    local nowAlive, list, ids, seen, inFolder = {}, {}, {}, {}, 0
    local folder = workspace:FindFirstChild("Enemies")
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            local id = tonumber(model.Name)
            if id then
                inFolder = inFolder + 1
                if not seen[id] then
                    seen[id] = true
                    table.insert(ids, id)
                end
                if not nowAlive[id] and isAliveModel(model) then
                    nowAlive[id] = true
                    table.insert(list, id)
                end
            end
        end
    end
    table.sort(list)
    table.sort(ids)
    tracker.alive, tracker.list, tracker.ids, tracker.inFolder = nowAlive, list, ids, inFolder
    return list
end

-- Each zone of MainLevelRootFolder keeps a "Locker" as long as its enemy isn't killed.
-- No Locker left = all enemies killed. Returns -1 if the folder is not found.
local function countLockers()
    local root = workspace:FindFirstChild("MainLevelRootFolder")
    if not root then
        tracker.lockers = -1
        return -1
    end
    local n = 0
    for _, child in ipairs(root:GetChildren()) do
        if child:FindFirstChild("Locker") then n = n + 1 end
    end
    tracker.lockers = n
    return n
end

-- // Fight results sent by the server (attackResult, incoming)
-- Measured in game: (damage, ?, ?, ?, 1, 1, won, 4, enemy). The enemy id is the 9th
-- argument (the 4th changes on every hit), the 7th = true when we win.
-- The server replies ~0.2 s after "attack"; the model only disappears ~1 s later
-- (animation), then the enemy respawns ~6 s after. So we trust the result, not the model.
local lastResult = { t = 0, enemy = nil, win = false }
local resultHooked = false
local resultWaiter -- { id, thread }: the current fight, woken up as soon as its result arrives

local function hookAttackResult()
    if resultHooked then return true end
    local remote = getRemote("attackResult")
    if not remote then return false end
    local ok, conn = pcall(function()
        return remote.OnClientEvent:Connect(function(...)
            local a = table.pack(...)
            local enemy = tonumber(a[9])
            local win = a[7] == true
            lastResult = { t = os.clock(), enemy = enemy, win = win }
            local w = resultWaiter
            if w and (enemy == nil or enemy == w.id) then
                resultWaiter = nil
                task.spawn(w.thread, win)
            end
        end)
    end)
    if ok and conn then
        table.insert(connections, conn)
        resultHooked = true
    end
    return resultHooked
end
hookAttackResult()

-- Waits for the result of the fight against `id`: true won, false lost, nil nothing received in time.
-- Woken up immediately by the event (no frame-by-frame wait loop).
local function waitResult(id, timeout)
    local thread = coroutine.running()
    local waiter = { id = id, thread = thread }
    resultWaiter = waiter
    task.delay(timeout, function()
        if resultWaiter == waiter then
            resultWaiter = nil
            task.spawn(thread, nil)
        end
    end)
    return coroutine.yield()
end

-- Copies the raw enemy state (send it to me if the "alive" count is wrong)
local function dumpEnemies()
    local lines = {}
    local folder = workspace:FindFirstChild("Enemies")
    if not folder then
        table.insert(lines, "workspace.Enemies not found")
    else
        local kids = folder:GetChildren()
        table.insert(lines, ("workspace.Enemies: %d children"):format(#kids))
        for i, model in ipairs(kids) do
            if i > 20 then
                table.insert(lines, "...")
                break
            end
            local attrs = {}
            for k, v in pairs(model:GetAttributes()) do
                table.insert(attrs, k .. "=" .. tostring(v))
            end
            table.sort(attrs)
            local children = {}
            for j, c in ipairs(model:GetChildren()) do
                if j > 12 then table.insert(children, "...") break end
                local extra = c:IsA("ValueBase") and ("=" .. tostring(c.Value)) or ""
                table.insert(children, c.Name .. ":" .. c.ClassName .. extra)
            end
            local hum = model:FindFirstChildOfClass("Humanoid")
            table.insert(lines, ("[%s] %s alive=%s hum=%s attrs={%s} children={%s}"):format(
                model.Name,
                model.ClassName,
                tostring(isAliveModel(model)),
                hum and (math.floor(hum.Health) .. "/" .. math.floor(hum.MaxHealth)) or "none",
                table.concat(attrs, ", "),
                table.concat(children, ", ")
            ))
        end
    end
    local text = table.concat(lines, "\n")
    print(text)
    if setclipboard then pcall(setclipboard, text) end
    return text
end

-- ========================================================
-- WAVE: enemies one by one
-- ========================================================
-- The wave stops immediately if Auto Attack is turned off, if a new cycle starts
-- or if a rebirth is requested manually.
local function canAttack(gen)
    return running and states.autoAttack and cycle.gen == gen and not pending.rebirth
end

local lastAttackAt = 0

local function runWave()
    local gen = cycle.gen
    if not getRemote("attack") then
        status.phase = "Remote \"attack\" not found"
        task.wait(1)
        return
    end

    hookAttackResult() -- without it, every fight would wait FIGHT_TIMEOUT
    wave.kills = 0

    -- Measured in game: during a boss fight (tower), the game removes all Death Road
    -- enemies (workspace.Enemies empty), and after the rebirth they don't come back on their own.
    -- So we leave the boss if there is one, then request the challenge and the enemies again.
    local function enterMain()
        if inBossFight() then
            fire("quitTimeLimitChallengeReq")
            local t = os.clock()
            while inBossFight() and os.clock() - t < 1.5 do task.wait() end
        end
        fire("enterMainChallengeReq")
        fire("getMainEnemiesHpReq")
    end
    status.phase = "Entering the challenge"
    enterMain()
    local lastEnter = os.clock()

    -- The server resolves each fight in one go (~0.2 s) and sends back attackResult:
    -- we move on to the next enemy as soon as this result arrives, without waiting for the model
    -- to disappear (~1 s of animation). Only one fight at a time: each "attack"
    -- cuts the previous fight.
    -- Progress read from the game (mainProgress): we hit mainLevel + 1, and the wave
    -- is done at mainLevel = 15. If it is unreadable: order of the alive ones + Lockers,
    -- `done` avoiding hitting a killed enemy again (they respawn ~6 s later).
    local waveStart = os.clock()
    local done = {}
    local current, losses, timeouts = nil, 0, 0
    local idleSince
    local passes = 1
    local beaten = 0 -- highest enemy beaten during this wave

    while canAttack(gen) do
        local lvl, total = mainProgress()
        if lvl and lvl >= total then
            status.lastFight = ("Death Road done (%d/%d) in %.1f s"):format(lvl, total, os.clock() - waveStart)
            break
        elseif not lvl and countLockers() == 0 then
            status.lastFight = ("All enemies killed in %.1f s (no Locker left)"):format(os.clock() - waveStart)
            break
        end

        scanEnemies()
        local target
        if lvl then
            -- Hit right away, even if its model isn't visible on our side: after a
            -- boss the game hides them, but the server accepts the attack (measured in game: waiting
            -- 3 s per enemy made a 27 s wave). `beaten` covers the small store delay
            -- after a win, so we don't hit the one we just beat again.
            target = math.max(lvl, beaten) + 1
        else
            -- Only the alive ones: a dying enemy (bar "0/…") ignores the attack
            for _, id in ipairs(tracker.list) do
                if not done[id] then
                    target = id
                    break
                end
            end
        end

        if not target then
            idleSince = idleSince or os.clock()
            if os.clock() - idleSince > WAVE_IDLE_TIMEOUT then
                status.lastFight = ("No Death Road enemy for %d s, wave stopped"):format(WAVE_IDLE_TIMEOUT)
                break
            end
            if not lvl and next(done) and #tracker.list > 0 then
                -- All killed but Locker still there: a 2nd pass on the respawned ones, no more
                passes = passes + 1
                if passes > 2 then break end
                done = {}
            end
            if os.clock() - lastEnter > 3 then
                enterMain()
                lastEnter = os.clock()
            end
            status.phase = "Waiting for Death Road enemies…"
            task.wait(0.1)
        else
            idleSince = nil
            if target ~= current then current, losses, timeouts = target, 0, 0 end
            status.phase = ("Fight -> Enemy %d"):format(target)

            -- Respect the server's minimum gap between two attacks
            local wait = ATTACK_GAP - (os.clock() - lastAttackAt)
            if wait > 0 then task.wait(wait) end
            if not canAttack(gen) then break end
            local sentAt = os.clock()
            lastAttackAt = sentAt
            fire("attack", target)
            local result = waitResult(target, FIGHT_TIMEOUT)
            if not canAttack(gen) then break end

            if result == true then
                done[target] = true
                if lvl then beaten = math.max(beaten, target) end
                wave.kills = wave.kills + 1
                status.lastFight = ("Enemy %d killed (%d ms)"):format(target, math.floor((os.clock() - sentAt) * 1000))
                if states.attackDelay > 0 then task.wait(states.attackDelay) end
            elseif result == false then
                -- Only REAL defeats count: too strong for now
                losses = losses + 1
                if losses >= states.maxHits then
                    status.lastFight = ("Enemy %d lost %d times: too strong, moving on to bosses"):format(target, losses)
                    wave.blockedAt = os.clock()
                    break
                end
                status.lastFight = ("Enemy %d lost, retrying"):format(target)
            else
                timeouts = timeouts + 1
                if lvl and timeouts >= MAX_TIMEOUTS * 3 then
                    -- It must be the next one: impossible to skip it
                    status.lastFight = ("Enemy %d no longer responds, wave stopped"):format(target)
                    break
                elseif not lvl and timeouts >= MAX_TIMEOUTS then
                    done[target] = true -- not responding: skip it
                    status.lastFight = ("Enemy %d no reply %d times, skipped"):format(target, timeouts)
                else
                    -- Often: still in a boss, or enemies not back -> enter again
                    status.lastFight = ("Enemy %d: no reply, back to the Death Road"):format(target)
                    enterMain()
                    lastEnter = os.clock()
                end
            end
        end

        if os.clock() - waveStart > WAVE_TIMEOUT then break end
    end

    wave.endedAt = os.clock()
    if canAttack(gen) then
        cycle.waveDone = true
        status.waves = status.waves + 1
    end
end

-- Continuous farm: once the Death Road is done (15/15), Auto Attack keeps killing every
-- living enemy in a loop (each kill still gives Exp; they respawn ~6 s later).
-- One pass over the living enemies, then back to the conductor (rebirth, bosses...).
local function farmPass()
    local gen = cycle.gen
    hookAttackResult()
    scanEnemies()
    local targets = table.clone(tracker.list)
    if #targets == 0 then
        status.phase = "Farm: waiting for enemies to respawn…"
        task.wait(0.2)
        return
    end
    for _, id in ipairs(targets) do
        -- A boss switched on in the meantime takes priority
        if not canAttack(gen) or states.bossAuto[1] or states.bossAuto[2] or states.bossAuto[3] then return end
        if tracker.alive[id] then
            local wait = ATTACK_GAP - (os.clock() - lastAttackAt)
            if wait > 0 then task.wait(wait) end
            if not canAttack(gen) then return end
            status.phase = ("Farm -> Enemy %d"):format(id)
            local sentAt = os.clock()
            lastAttackAt = sentAt
            fire("attack", id)
            local result = waitResult(id, FIGHT_TIMEOUT)
            if result == true then
                wave.kills = wave.kills + 1
                status.lastFight = ("Farm: enemy %d killed (%d ms)"):format(id, math.floor((os.clock() - sentAt) * 1000))
                if states.attackDelay > 0 then task.wait(states.attackDelay) end
            end
        end
        scanEnemies()
    end
end

-- ========================================================
-- BOSS & REBIRTH
-- ========================================================
local lastLaunch = {} -- [id] = os.clock() of the last launch

-- Nightmare level going up = the fight is running and we are winning
local levelWatch = { value = 0, changedAt = os.clock() }
-- Returns true if the level just dropped (sign of a rebirth)
local function trackLevel()
    local lvl = getNightmareLevel()
    local dropped = levelWatch.value > 0 and lvl < levelWatch.value
    if lvl > levelWatch.value then levelWatch.changedAt = os.clock() end
    levelWatch.value = lvl
    return dropped
end

-- Rebirth level to aim for, or nil if the rebirth isn't level-based (Auto Rebirth off, Timer mode)
local function levelTarget()
    if not states.autoRebirth or states.rebirthMode == MODE_TIMER then return nil end
    return rebirthLevel()
end

-- End of a boss fight sent by the server: timeLimitChallengeResult(won).
-- (The attackResults received during a boss are just its hits, every 0.3 s.)
local bossEnd = { t = 0, win = nil }

local function onBossEnd(win)
    bossEnd = { t = os.clock(), win = win == true }
end

local bossEndHooked = false
local function hookBossEnd()
    if bossEndHooked then return end
    local remote = getRemote("timeLimitChallengeResult")
    if not remote then return end
    local ok, conn = pcall(function()
        return remote.OnClientEvent:Connect(function(win) onBossEnd(win) end)
    end)
    if ok and conn then
        table.insert(connections, conn)
        bossEndHooked = true
    end
end
hookBossEnd()

-- Nightmare jump without exceeding the required level: the chosen level is the MAX jump,
-- we take the largest jump that fits in what remains.
-- E.g. level 25, required 95, max +50: +50 (75), +10 (85), +10 (95).
-- (Measured in game: at level 25, "+5" launches floor 30; the level only goes up on a win.)
-- In Custom, the jump is exactly what remains (capped at the chosen N): right on the level.
-- Returns the index sent to the server (0 = +1 … 3 = +50, 4 = Custom) and the Custom N,
-- or nil if the required level is reached.
local function nightmareStep(maxIdx)
    local level = getNightmareLevel()
    local target = levelTarget()
    local room = math.huge
    if target then
        room = target - level
        if room <= 0 then return nil end
    end
    if maxIdx == CUSTOM_IDX then
        local n = math.clamp(math.floor(states.customStep), 1, CUSTOM_MAX)
        return CUSTOM_IDX, math.min(n, room)
    end
    for i = maxIdx, 0, -1 do
        if LEVEL_STEPS[i + 1] <= room then return i end
    end
    return 0
end

local function runBoss(boss, relaunch)
    local lvl, custom = states.bossLevel[boss.id], nil
    if boss.id == 3 then
        lvl, custom = nightmareStep(lvl)
        if not lvl then
            -- Target level reached: no new fight, the rebirth goes right away
            lastLaunch[boss.id] = os.clock()
            status.lastBoss = ("Nightmare: level %d reached, rebirth pending"):format(levelTarget() or 0)
            return
        end
    end
    status.phase = (relaunch and "Relaunching boss: " or "Boss: ") .. boss.name
    if teleportToBoss(boss) then task.wait(0.2) end

    -- Same order as the game's button: setAfkResumeReq then startTimeLimitChallengeReq
    if boss.id == 3 then
        fire("setAfkResumeReq", boss.id, lvl, custom)
    end
    local ok = fire("startTimeLimitChallengeReq", boss.id, lvl, custom)
    lastLaunch[boss.id] = os.clock()
    status.lastBoss = boss.name .. " " .. (custom and ("+" .. custom .. " (Custom)") or LEVELS[lvl + 1])
        .. (relaunch and " (relaunched)" or "")
        .. (ok and "" or " (remote not found)")

    task.wait(states.bossDelay)
end

-- Like the game: after each fight (win OR loss), we make the call again.
-- End of fight detected by: timeLimitChallengeResult, Nightmare level going up,
-- or failing that bossRetry s elapsed (a fight lasts ~37 s; relaunching during it is useless,
-- the server ignores the request).
local function bossLooksLost(boss)
    local launchedAt = lastLaunch[boss.id] or 0
    local now = os.clock()
    if now - launchedAt < 0.5 then return false end -- let the fight start
    if bossEnd.t > launchedAt then return true end -- end of fight (won or lost)
    if boss.id == 3 and levelWatch.changedAt > launchedAt then return true end -- win
    return states.bossRetry > 0 and now - launchedAt >= states.bossRetry
end

-- The cycle is done when everything enabled has been done once
local function cycleComplete()
    if states.autoAttack and not cycle.waveDone then return false end
    for _, boss in ipairs(BOSSES) do
        if states.bossAuto[boss.id] and not cycle.bossDone[boss.id] then return false end
    end
    return true
end

local function rebirthReason()
    if not states.autoRebirth then return nil end
    if os.clock() - lastRebirth < MIN_REBIRTH_GAP then return nil end
    -- Required level reached: rebirth right away, without waiting for the other bosses
    -- (only the wave must be done)
    local target = levelTarget()
    if target and getNightmareLevel() >= target and (cycle.waveDone or not states.autoAttack) then
        return "level " .. target
    end
    if states.rebirthMode == MODE_LEVEL or not cycleComplete() then return nil end
    -- Timer modes: the game refuses the rebirth below the required level, no point trying
    local req = requiredLevel()
    if req and getNightmareLevel() < req then return nil end
    if os.clock() - timerFrom >= states.rebirthInterval then return "timer" end
    return nil
end

local notify -- defined with the interface

local REBIRTH_RETRY = 2 -- s before retrying a refused rebirth

local function doRebirth(reason)
    pending.rebirth = false
    cycle.leaving = true -- no more bosses relaunched before the rebirth
    -- The game's button only refuses during a boss fight ("Complete your challenge
    -- first"): we leave the boss and wait for the game to confirm it, with no fixed wait.
    -- (No more leaveChallengeReq + 1.5 s of fixed waits: the game doesn't require it.)
    local fighting = inBossFight()
    if fighting ~= false then
        status.phase = "Leaving the fight"
        fire("quitTimeLimitChallengeReq")
        local t = os.clock()
        if fighting == nil then
            task.wait(0.3)
        else
            while inBossFight() and os.clock() - t < 1.5 do task.wait() end
        end
    end

    status.phase = "Rebirth"
    local before = rebirthCount()
    if fireRebirth() then
        -- The game may refuse (level too low, fight not over) without sending anything back:
        -- we check that the rebirth counter really goes up (3 s max), frame by frame
        local t = os.clock()
        while before and rebirthCount() == before and os.clock() - t < 3 do task.wait() end
        if before and rebirthCount() == before then
            -- Refused: keep the current cycle (bosses included) and retry quickly
            lastRebirth = os.clock() - MIN_REBIRTH_GAP + REBIRTH_RETRY
            cycle.leaving = false
            cycle.bossDone = {}
            status.lastBoss = "Rebirth refused by the game (" .. reason .. ")"
            if notify then notify("Rebirth", "Refused by the game, retrying in " .. REBIRTH_RETRY .. " s") end
            return false
        end
        lastRebirth = os.clock()
        timerFrom = lastRebirth
        status.rebirths = status.rebirths + 1
        status.lastFight = ("Rebirth in %.2f s"):format(os.clock() - t)
        resetCycle() -- new cycle: the wave and the bosses start over from scratch
        if notify then notify("Rebirth", "Done (" .. reason .. ")") end
        return true
    end
    if notify then notify("Rebirth", "Rebirth remote not found") end
    lastRebirth = os.clock() -- avoids spamming if the remote is missing
    cycle.leaving = false
    return false
end

-- Rebirth done outside the script (game's button…) or badly detected: start over on a fresh cycle
local rebirthSeen = { count = nil, guiAt = 0 }

local function readRebirthCount()
    local stats = localPlayer:FindFirstChild("leaderstats")
    if stats then
        for _, v in ipairs(stats:GetChildren()) do
            if v:IsA("ValueBase") and v.Name:lower():find("rebirth") then
                return tonumber(v.Value)
            end
        end
    end
    -- Otherwise read the interface ("Rebirth 12"), at most once every 3 s
    if os.clock() - rebirthSeen.guiAt < 3 then return rebirthSeen.count end
    rebirthSeen.guiAt = os.clock()
    local gui = localPlayer:FindFirstChild("PlayerGui")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible then
            local n = d.Text:match("[Rr]ebirths?%s*:?%s*(%d+)")
            if n then return tonumber(n) end
        end
    end
    return nil
end

local function onRebirthDetected(source)
    if os.clock() - lastRebirth < 8 then return end -- it's ours, already handled
    lastRebirth = os.clock()
    timerFrom = lastRebirth
    status.rebirths = status.rebirths + 1
    resetCycle()
    if notify then notify("Rebirth detected", "New cycle (" .. source .. ")") end
end

local function checkExternalRebirth()
    local n = readRebirthCount()
    if n then
        if rebirthSeen.count and n > rebirthSeen.count then onRebirthDetected("counter") end
        rebirthSeen.count = n
    end
end

-- ========================================================
-- INTERFACE: WindUI / native adapter
-- ========================================================
local function buildWindUI(WindUI)
    local Window = WindUI:CreateWindow({
        Title = "+1 DMG Per Revive",
        Icon = "swords",
        Author = "Auto farm",
        Folder = "FarmBossRebirth",
        Size = UDim2.fromOffset(580, 460),
        Theme = "Dark",
        SideBarWidth = 170,
    })
    pcall(function() Window:SetToggleKey(states.toggleKey) end)

    local api = {}

    local function wrap(target)
        local g = {}
        local function safe(method, cfg)
            local ok, el = pcall(function() return target[method](target, cfg) end)
            if not ok then warn("[FarmBossRebirth] WindUI " .. method .. ": " .. tostring(el)) end
            return ok and el or nil
        end
        function g.section(title, icon)
            local sec = safe("Section", { Title = title, Icon = icon, Opened = true })
            return sec and wrap(sec) or g
        end
        -- set: changes the display then applies (callback only once)
        -- setSilent: only changes the display
        function g.toggle(o)
            local el = safe("Toggle", {
                Title = o.title, Desc = o.desc, Value = o.default == true,
                Callback = function(v) o.callback(v == true) end,
            })
            local function show(v)
                if el then pcall(function() el:Set(v, false) end) end
            end
            return {
                set = function(v)
                    show(v)
                    o.callback(v)
                end,
                setSilent = show,
            }
        end
        function g.slider(o)
            safe("Slider", {
                Title = o.title, Desc = o.desc, Step = o.step,
                Value = { Min = o.min, Max = o.max, Default = o.default },
                Callback = function(v) o.callback(tonumber(v) or o.default) end,
            })
        end
        function g.dropdown(o)
            safe("Dropdown", {
                Title = o.title, Desc = o.desc, Values = o.options, Value = o.default,
                Multi = false, AllowNone = false,
                Callback = function(v)
                    if type(v) == "table" then v = v[1] end
                    if v ~= nil then o.callback(v) end
                end,
            })
        end
        function g.input(o)
            local el = safe("Input", {
                Title = o.title, Desc = o.desc, Value = tostring(o.default),
                Placeholder = o.placeholder or "", Callback = o.callback,
            })
            return {
                setText = function(text)
                    if el then pcall(function() el:Set(text) end) end
                end,
            }
        end
        function g.button(o)
            safe("Button", { Title = o.title, Desc = o.desc, Callback = o.callback })
        end
        function g.paragraph(o)
            local el = safe("Paragraph", { Title = o.title, Desc = o.desc })
            return {
                setDesc = function(text)
                    if el then pcall(function() el:SetDesc(text) end) end
                end,
            }
        end
        return g
    end

    function api.tab(title, icon)
        return wrap(Window:Tab({ Title = title, Icon = icon }))
    end
    function api.notify(title, text)
        pcall(function() WindUI:Notify({ Title = title, Content = text, Duration = 4 }) end)
    end
    function api.selectFirst()
        pcall(function() Window:SelectTab(1) end)
    end
    function api.setToggleKey(key)
        pcall(function() Window:SetToggleKey(key) end)
    end
    function api.destroy()
        pcall(function() Window:Destroy() end)
    end
    return api
end

local function buildNativeUI()
    local C = {
        bg = Color3.fromRGB(22, 23, 29), bar = Color3.fromRGB(28, 30, 38),
        card = Color3.fromRGB(32, 34, 43), field = Color3.fromRGB(44, 47, 58),
        text = Color3.fromRGB(235, 235, 240), dim = Color3.fromRGB(160, 162, 175),
        on = Color3.fromRGB(46, 204, 113), off = Color3.fromRGB(231, 76, 60),
        accent = Color3.fromRGB(88, 101, 242),
    }
    local function make(class, props)
        local inst = Instance.new(class)
        for k, v in pairs(props) do
            if k ~= "Parent" then inst[k] = v end
        end
        inst.Parent = props.Parent
        return inst
    end
    local function round(inst, r)
        make("UICorner", { CornerRadius = UDim.new(0, r or 6), Parent = inst })
    end

    local gui = make("ScreenGui", { Name = "FarmBossRebirth", ResetOnSpawn = false })
    pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end)
    if not gui.Parent then gui.Parent = localPlayer:WaitForChild("PlayerGui") end

    local main = make("Frame", {
        Size = UDim2.fromOffset(340, 470), Position = UDim2.new(0.5, -170, 0.2, 0),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, Parent = gui,
    })
    round(main, 10)
    make("UIStroke", { Color = Color3.fromRGB(55, 58, 72), Thickness = 1.5, Parent = main })

    local top = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.bar, BorderSizePixel = 0,
        Text = "   +1 DMG Per Revive", TextColor3 = C.text,
        Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = main,
    })
    round(top, 10)

    local tabBar = make("Frame", {
        Size = UDim2.new(1, -16, 0, 26), Position = UDim2.fromOffset(8, 40),
        BackgroundTransparency = 1, Parent = main,
    })
    make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = tabBar })
    local pages = make("Frame", {
        Size = UDim2.new(1, -16, 1, -78), Position = UDim2.fromOffset(8, 72),
        BackgroundTransparency = 1, Parent = main,
    })

    -- Dragging + key to hide
    local dragging, dragStart, startPos
    top.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
        end
    end)
    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == states.toggleKey then
            main.Visible = not main.Visible
        end
    end))

    local tabs = {}
    local function selectTab(entry)
        for _, t in ipairs(tabs) do
            t.page.Visible = (t == entry)
            t.button.BackgroundColor3 = (t == entry) and C.accent or C.field
        end
    end

    local api = {}
    function api.tab(title)
        local button = make("TextButton", {
            Size = UDim2.new(0, 74, 1, 0), BackgroundColor3 = C.field, Text = title,
            TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 12, Parent = tabBar,
        })
        round(button, 6)
        local page = make("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
            ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false, Parent = pages,
        })
        make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
        local entry = { button = button, page = page }
        table.insert(tabs, entry)
        button.MouseButton1Click:Connect(function() selectTab(entry) end)

        local order = 0
        local function nextOrder()
            order = order + 1
            return order
        end
        local function row()
            local f = make("Frame", {
                Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = C.card, BorderSizePixel = 0,
                LayoutOrder = nextOrder(), Parent = page,
            })
            round(f, 6)
            return f
        end
        local function label(parent, text)
            make("TextLabel", {
                Size = UDim2.new(0.6, -10, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1,
                Text = text, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = parent,
            })
        end
        local function control(parent, class, props)
            props.Size = UDim2.new(0.4, -10, 0, 24)
            props.Position = UDim2.new(0.6, 0, 0.5, -12)
            props.BackgroundColor3 = props.BackgroundColor3 or C.field
            props.TextColor3 = C.text
            props.Font = Enum.Font.GothamBold
            props.TextSize = 12
            props.Parent = parent
            local inst = make(class, props)
            round(inst, 5)
            return inst
        end

        local g = {}
        function g.section(text)
            make("TextLabel", {
                Size = UDim2.new(1, -6, 0, 22), BackgroundTransparency = 1, Text = text,
                TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = nextOrder(), Parent = page,
            })
            return g
        end
        function g.toggle(o)
            local f = row()
            label(f, o.title)
            local value = o.default == true
            local b = control(f, "TextButton", {})
            local function render()
                b.Text = value and "ON" or "OFF"
                b.BackgroundColor3 = value and C.on or C.off
            end
            render()
            b.MouseButton1Click:Connect(function()
                value = not value
                render()
                o.callback(value)
            end)
            local function show(v)
                value = v == true
                render()
            end
            return {
                set = function(v)
                    show(v)
                    o.callback(value)
                end,
                setSilent = show,
            }
        end
        function g.slider(o)
            local f = row()
            label(f, ("%s (%s to %s)"):format(o.title, tostring(o.min), tostring(o.max)))
            local box = control(f, "TextBox", { Text = tostring(o.default), ClearTextOnFocus = false })
            box.FocusLost:Connect(function()
                local n = tonumber(box.Text)
                if not n then
                    box.Text = tostring(o.default)
                    return
                end
                n = math.clamp(n, o.min, o.max)
                box.Text = tostring(n)
                o.callback(n)
            end)
        end
        function g.dropdown(o)
            local f = row()
            label(f, o.title)
            local idx = table.find(o.options, o.default) or 1
            local b = control(f, "TextButton", { Text = o.options[idx] })
            b.MouseButton1Click:Connect(function()
                idx = idx % #o.options + 1
                b.Text = o.options[idx]
                o.callback(o.options[idx])
            end)
        end
        function g.input(o)
            local f = row()
            label(f, o.title)
            local box = control(f, "TextBox", { Text = tostring(o.default), ClearTextOnFocus = false })
            box.FocusLost:Connect(function() o.callback(box.Text) end)
            return {
                setText = function(text)
                    box.Text = text
                    o.callback(text)
                end,
            }
        end
        function g.button(o)
            local b = make("TextButton", {
                Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = C.accent, Text = o.title,
                TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 12,
                LayoutOrder = nextOrder(), Parent = page,
            })
            round(b, 6)
            b.MouseButton1Click:Connect(o.callback)
        end
        function g.paragraph(o)
            local f = make("Frame", {
                Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundColor3 = C.card, BorderSizePixel = 0, LayoutOrder = nextOrder(), Parent = page,
            })
            round(f, 6)
            make("UIPadding", {
                PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
                PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = f,
            })
            local body = make("TextLabel", {
                Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
                Text = o.desc, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Parent = f,
            })
            return { setDesc = function(text) body.Text = text end }
        end
        return g
    end
    function api.notify(title, text)
        pcall(function()
            StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 4 })
        end)
    end
    function api.selectFirst()
        if tabs[1] then selectTab(tabs[1]) end
    end
    function api.setToggleKey()
        -- nothing to do: the key is re-read from states.toggleKey on every press
    end
    function api.destroy()
        gui:Destroy()
    end
    return api
end

local UI
do
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet(WINDUI_URL))()
    end)
    if ok and type(lib) == "table" then
        local built, api = pcall(buildWindUI, lib)
        if built then
            UI = api
        else
            warn("[FarmBossRebirth] WindUI failed, native interface: " .. tostring(api))
        end
    else
        warn("[FarmBossRebirth] WindUI not loaded, native interface: " .. tostring(lib))
    end
    UI = UI or buildNativeUI()
end
notify = UI.notify

local function indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

-- Toggles linked to each other (filled in below)
local masterToggle, attackToggle, rebirthToggle
local bossToggles = {}

-- One of the three is turned off manually: Auto Farm Rebirth is no longer running "complete"
local function masterOffSilently()
    if masterToggle then masterToggle.setSilent(false) end
end

local function anyBossAuto()
    for _, boss in ipairs(BOSSES) do
        if states.bossAuto[boss.id] then return true end
    end
    return false
end

-- // Farm tab
local farmTab = UI.tab("Farm", "swords")
local statusPara = farmTab.paragraph({ title = "Status", desc = "Starting…" })

local masterSec = farmTab.section("Auto Farm Rebirth", "zap")
masterToggle = masterSec.toggle({
    title = "Auto Farm Rebirth",
    desc = "Enables Auto Attack + bosses + Auto Rebirth with the tabs' settings (Nightmare if no boss is chosen)",
    callback = function(v)
        if v then
            resetCycle() -- start over from a clean wave
            attackToggle.set(true)
            if not anyBossAuto() then bossToggles[3].set(true) end
            rebirthToggle.set(true)
            notify("Auto Farm Rebirth", "Wave -> bosses -> rebirth, on loop")
        else
            attackToggle.set(false)
            for _, boss in ipairs(BOSSES) do
                bossToggles[boss.id].set(false)
            end
            rebirthToggle.set(false)
        end
    end,
})

local atkSec = farmTab.section("Auto Attack", "crosshair")
attackToggle = atkSec.toggle({
    title = "Auto Attack",
    desc = "Kills the remaining enemies in order (2, 3… if 1 is already dead), once per rebirth",
    callback = function(v)
        states.autoAttack = v
        if v and not cycle.waveDone then
            -- Bosses launched before the wave: the wave will cut them, we'll relaunch them afterwards
            cycle.bossDone = {}
        end
        if not v then masterOffSilently() end
    end,
})
atkSec.slider({
    title = "Pause after each enemy killed (s)", min = 0, max = 1, step = 0.05, default = states.attackDelay,
    callback = function(v) states.attackDelay = math.max(0, v) end,
})
atkSec.slider({
    title = "Max defeats per enemy",
    desc = "Lost this many times (real in-game defeat): too strong, moving on to bosses",
    min = 1, max = 20, step = 1, default = states.maxHits,
    callback = function(v) states.maxHits = math.max(1, math.floor(v)) end,
})
atkSec.button({
    title = "New cycle",
    desc = "Redoes the wave and the bosses now, without waiting for the rebirth",
    callback = function()
        resetCycle()
        notify("Cycle", "The wave and the bosses will be redone")
    end,
})
atkSec.button({
    title = "Inspect enemies",
    desc = "Copies the enemy state to the clipboard (send it back if the count is wrong)",
    callback = function()
        dumpEnemies()
        notify("Enemies", "Copied to the clipboard (and to the F9 console)")
    end,
})

-- // Boss tab
local bossTab = UI.tab("Boss", "skull")
for _, boss in ipairs(BOSSES) do
    local sec = bossTab.section(boss.name, "skull")
    local options = boss.id == 3 and NIGHTMARE_LEVELS or LEVELS
    sec.dropdown({
        title = "Level",
        desc = boss.id == 3 and "Max jump. Custom = N floors (Ascension 10+ required by the game)" or nil,
        options = options, default = options[states.bossLevel[boss.id] + 1],
        callback = function(opt)
            local i = indexOf(options, opt)
            if i then states.bossLevel[boss.id] = i - 1 end
        end,
    })
    if boss.id == 3 then
        sec.input({
            title = "Custom jump (1 to " .. CUSTOM_MAX .. ")", default = states.customStep, placeholder = "50",
            callback = function(text)
                local n = tonumber(text)
                if n and n >= 1 then states.customStep = math.min(math.floor(n), CUSTOM_MAX) end
            end,
        })
    end
    bossToggles[boss.id] = sec.toggle({
        title = "Auto " .. boss.name,
        desc = "Launched after the wave, relaunched on a loss, until the rebirth",
        callback = function(v)
            states.bossAuto[boss.id] = v
            if not v and not anyBossAuto() then masterOffSilently() end
        end,
    })
    sec.button({
        title = "Launch " .. boss.name .. " (1x)",
        callback = function()
            table.insert(pending.bosses, boss)
            local later = states.autoAttack and not cycle.waveDone
            notify(boss.name, later and "Launched after the current wave" or "Launching…")
        end,
    })
end
local bossSettings = bossTab.section("Settings", "settings")
bossSettings.slider({
    title = "Wait after a boss (s)", min = 0.5, max = 30, step = 0.5, default = states.bossDelay,
    callback = function(v) states.bossDelay = math.max(0.5, v) end,
})
bossSettings.slider({
    title = "Distance before TP (studs)", desc = "TP to the boss only if we are farther away",
    min = 0, max = 200, step = 5, default = states.tpDistance,
    callback = function(v) states.tpDistance = math.max(0, v) end,
})
bossSettings.slider({
    title = "Relaunch the boss at the latest after (s)",
    desc = "Relaunched as soon as the fight ends (won or lost), otherwise after this time. 0 = never",
    min = 0, max = 120, step = 1, default = states.bossRetry,
    callback = function(v) states.bossRetry = math.max(0, v) end,
})

-- // Rebirth tab
local rebirthTab = UI.tab("Rebirth", "refresh-cw")
local rebSec = rebirthTab.section("Auto Rebirth", "refresh-cw")
local requiredPara = rebSec.paragraph({ title = "Nightmare level", desc = "…" })
rebirthToggle = rebSec.toggle({
    title = "Auto Rebirth",
    desc = "As soon as the Nightmare level is reached (game's requirement read automatically, or your custom level)",
    callback = function(v)
        states.autoRebirth = v
        if v then timerFrom = os.clock() end -- the Timer starts now (the level rebirth, however, doesn't wait)
        if not v then masterOffSilently() end
    end,
})
rebSec.dropdown({
    title = "Condition", options = REBIRTH_MODES, default = REBIRTH_MODES[1],
    callback = function(opt)
        local i = indexOf(REBIRTH_MODES, opt)
        if i then states.rebirthMode = i end
    end,
})
rebSec.input({
    title = "Custom level (0 = game's requirement)",
    desc = "Rebirth at the higher of the two. E.g. 250: required 35 -> 250; required 260 -> 260",
    default = states.rebirthMinLevel, placeholder = "0",
    callback = function(text)
        local n = tonumber(text)
        if n and n >= 0 then states.rebirthMinLevel = math.floor(n) end
    end,
})
rebSec.input({
    title = "Timer (s)", desc = "Only for the conditions with Timer",
    default = states.rebirthInterval, placeholder = "60",
    callback = function(text)
        local n = tonumber(text)
        if n and n > 0 then states.rebirthInterval = n end
    end,
})
rebSec.button({
    title = "Rebirth now",
    desc = "Leaves the challenge then does the rebirth (cuts the current wave)",
    callback = function()
        pending.rebirth = true
        notify("Rebirth", "Requested")
    end,
})

-- // Settings tab
local settingsTab = UI.tab("Settings", "settings")
settingsTab.toggle({
    title = "Anti-AFK", desc = "Prevents being kicked after 20 min without moving", default = true,
    callback = function(v) states.antiAfk = v end,
})
settingsTab.toggle({
    title = "Walk speed", desc = "Forces your walk speed (back to normal when turned off)",
    callback = function(v) states.walkSpeedOn = v end,
})
settingsTab.slider({
    title = "Speed (16 = normal)", min = 16, max = 200, step = 1, default = states.walkSpeed,
    callback = function(v) states.walkSpeed = math.clamp(v, 16, 200) end,
})
local MENU_KEYS = { "RightControl", "RightShift", "LeftControl", "Insert", "Home", "End" }
settingsTab.dropdown({
    title = "Menu key", desc = "Press it to show / hide the menu",
    options = MENU_KEYS, default = "RightControl",
    callback = function(name)
        local key = Enum.KeyCode[name]
        if key then
            states.toggleKey = key
            UI.setToggleKey(key)
        end
    end,
})
settingsTab.button({
    title = "Stop the script", desc = "Stops all loops and closes the interface",
    callback = function() env.__FarmBossRebirthStop() end,
})

UI.selectFirst()

-- ========================================================
-- SHUTDOWN
-- ========================================================
-- Debug access from the executor's console (state reading, toggles)
env.__FarmBossRebirth = {
    states = states, status = status, cycle = cycle,
    master = masterToggle, attack = attackToggle, rebirth = rebirthToggle, bosses = bossToggles,
    nightmareStep = function() return nightmareStep(states.bossLevel[3]) end,
    requiredLevel = requiredLevel,
}

env.__FarmBossRebirthStop = function()
    running = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    UI.destroy()
    env.__FarmBossRebirthStop = nil
    env.__FarmBossRebirth = nil
end

-- ========================================================
-- LOOPS
-- ========================================================

-- Walk speed: reapplied continuously (the game resets it on each respawn / teleport).
-- The original speed is saved to restore it when turned off or when the script stops.
local walk = { hum = nil, original = nil, forced = false }
local function restoreWalkSpeed()
    if walk.forced and walk.hum and walk.hum.Parent and walk.original then
        pcall(function() walk.hum.WalkSpeed = walk.original end)
    end
    walk.forced = false
end
task.spawn(function()
    while running do
        local char = localPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum ~= walk.hum then
            walk.hum, walk.original, walk.forced = hum, hum and hum.WalkSpeed, false
        end
        if hum then
            if states.walkSpeedOn then
                if not walk.forced then
                    walk.original = hum.WalkSpeed
                    walk.forced = true
                end
                if hum.WalkSpeed ~= states.walkSpeed then hum.WalkSpeed = states.walkSpeed end
            elseif walk.forced then
                restoreWalkSpeed()
            end
        end
        task.wait(0.1)
    end
    restoreWalkSpeed()
end)

-- Anti-AFK
table.insert(connections, localPlayer.Idled:Connect(function()
    if not states.antiAfk then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

local function idlePhase()
    if not (states.autoAttack or states.autoRebirth or anyBossAuto()) then
        return "Paused"
    end
    local fighting = anyBossAuto() and "Boss in progress, " or "Cycle done, "
    if states.autoRebirth then
        return fighting .. "waiting for the rebirth"
    end
    if anyBossAuto() then return "Boss in progress" end
    return "Cycle done (enable Auto Rebirth or \"New cycle\")"
end

-- Auto Attack also works outside a cycle: as long as the Death Road isn't finished
-- (game progress < 15), the wave is run again, even if this cycle's wave is marked done
-- (e.g. rebirth made by the game or another script). Not more than every 10 s, and
-- 60 s of rest after stopping on an enemy that is too strong (so bosses still run).
local WAVE_RETRY_GAP, WAVE_BLOCKED_GAP = 10, 60
local function waveNeededAgain()
    local lvl, total = mainProgress()
    if not lvl or lvl >= total then return false end
    local now = os.clock()
    return now - wave.endedAt >= WAVE_RETRY_GAP and now - wave.blockedAt >= WAVE_BLOCKED_GAP
end

-- Conductor: one thing at a time, always in the same order
--   0. rebirth requested manually
--   1. the wave (once per cycle, and again whenever the Death Road isn't finished)
--   2. the bosses: only once the wave is done (or if Auto Attack is off)
--   3. auto rebirth: cycle done + time or level reached
local function orchestrate()
    local busy = false

    if pending.rebirth then
        doRebirth("manual")
        busy = true
    end

    if running and states.autoAttack and (not cycle.waveDone or waveNeededAgain()) then
        runWave()
        busy = true
    end

    local waveOk = cycle.waveDone or not states.autoAttack
    if running and waveOk and not pending.rebirth then
        -- Bosses requested manually
        while running and #pending.bosses > 0 do
            runBoss(table.remove(pending.bosses, 1))
            busy = true
        end
        -- Bosses set to Auto: launched once the wave is done, then relaunched if we lost
        -- (no relaunch if the rebirth is already due: we are about to leave the challenge)
        local gen = cycle.gen
        for _, boss in ipairs(BOSSES) do
            if running and gen == cycle.gen and not cycle.leaving and states.bossAuto[boss.id] then
                local first = not cycle.bossDone[boss.id]
                if first or (bossLooksLost(boss) and not rebirthReason()) then
                    runBoss(boss, not first)
                    if gen == cycle.gen then cycle.bossDone[boss.id] = true end
                    busy = true
                end
            end
        end
    end

    local reason = running and not pending.rebirth and rebirthReason()
    if reason then
        doRebirth(reason)
        busy = true
    end

    -- Nothing else to do: Auto Attack keeps farming the Death Road enemies (no boss on)
    if not busy and running and states.autoAttack and cycle.waveDone and not pending.rebirth
        and not anyBossAuto() and #pending.bosses == 0 then
        local lvl, total = mainProgress()
        if not lvl or lvl >= total then
            farmPass()
            busy = true
        end
    end

    if not busy then
        status.phase = idlePhase()
        task.wait(0.1) -- short: the level rebirth fires as soon as the win happens
    end
end

-- An error must never kill the loop (otherwise nothing launches anymore, with no message)
task.spawn(function()
    while running do
        local ok, err = pcall(orchestrate)
        if not ok then
            status.phase = "Error: " .. tostring(err)
            warn("[FarmBossRebirth] " .. tostring(err))
            task.wait(1)
        end
    end
end)

-- Live status (enemies are re-read on every refresh)
local function cycleText()
    local parts = {}
    if states.autoAttack then
        table.insert(parts, cycle.waveDone and "wave done" or "wave to do")
    end
    for _, boss in ipairs(BOSSES) do
        if states.bossAuto[boss.id] then
            table.insert(parts, boss.name .. (cycle.bossDone[boss.id] and " launched" or " to launch"))
        end
    end
    return #parts > 0 and table.concat(parts, " · ") or "nothing enabled"
end

-- "Nightmare: 25 / 250 (required 95, custom 250)"
local function requiredText()
    local req = requiredLevel()
    local goal = rebirthLevel()
    local lvl = math.floor(getNightmareLevel())
    if not goal then return ("Nightmare: %d (required level unreadable)"):format(lvl) end
    return ("Nightmare: %d / %d (required %s, custom %s)%s"):format(
        lvl, goal, req and tostring(req) or "?",
        states.rebirthMinLevel > 0 and tostring(states.rebirthMinLevel) or "-",
        lvl >= goal and " ✓" or "")
end

local function statusText()
    local lines = {
        "Phase: " .. status.phase .. (pending.rebirth and " (rebirth requested)" or ""),
        "Cycle: " .. cycleText(),
        ("Enemies: %d alive / %d in the folder"):format(#tracker.list, tracker.inFolder),
        ("Waves: %d · killed this wave: %d"):format(status.waves, wave.kills),
        "Lockers remaining: " .. (tracker.lockers >= 0 and tostring(tracker.lockers) or "MainLevelRootFolder not found"),
        "Last fight: " .. status.lastFight .. (resultHooked and "" or " (attackResult not hooked)"),
        ("Nightmare Lv: %d · last boss: %s"):format(math.floor(levelWatch.value), status.lastBoss),
        ("Rebirths: %d"):format(status.rebirths),
    }
    table.insert(lines, requiredText())
    if states.autoRebirth and states.rebirthMode ~= MODE_LEVEL then
        local left = math.max(0, math.floor(states.rebirthInterval - (os.clock() - timerFrom)))
        table.insert(lines, ("Timer: %d s"):format(left))
    end
    if states.bossAuto[3] then
        local idx, custom = nightmareStep(states.bossLevel[3])
        table.insert(lines, "Next Nightmare jump: "
            .. (not idx and "none (required level reached)" or custom and ("+" .. custom) or LEVELS[idx + 1]))
    end
    return table.concat(lines, "\n")
end

task.spawn(function()
    while running do
        local ok, err = pcall(function()
            scanEnemies()
            if trackLevel() then onRebirthDetected("Nightmare level dropped") end
            checkExternalRebirth()
            hookAttackResult()
            hookBossEnd()
            countLockers() -- in case the remote appears after launch
            statusPara.setDesc(statusText())
            requiredPara.setDesc(requiredText())
        end)
        if not ok then warn("[FarmBossRebirth] status: " .. tostring(err)) end
        task.wait(0.3)
    end
end)

notify("+1 DMG Per Revive", "Loaded. Right Ctrl to show / hide the menu.")
