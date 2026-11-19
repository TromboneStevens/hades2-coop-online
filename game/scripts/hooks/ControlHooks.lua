--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

---@type CoopPlayers
local CoopPlayers = ModRequire "../logic/CoopPlayers.lua"
---@type HeroContext
local HeroContext = ModRequire "../logic/HeroContext.lua"
---@type HeroContextNative
local HeroContextNative = ModRequire "../logic/HeroContextNative.lua"
---@type SimpleHook
local SimpleHook = ModRequire "../utils/SimpleHook.lua"
---@type NetSession
local NetSession = ModRequire "../logic/net/NetSession.lua"
---@type InputSync
local InputSync = ModRequire "../logic/net/InputSync.lua"

local ControlHooks = SimpleHook.New()

function ControlHooks.wrap.OnControlPressed(baseFun, args)
    local controlName = args[1]
    local handler = args[2]

    -- Online path: let InputSync know the gameplay handler for this control so
    -- the host can replay network InputEvents through the exact same handler.
    -- This only records a reference; it does not change local dispatch.
    if NetSession.IsOnline() then
        InputSync.RegisterHandler(controlName, handler)
    end

    baseFun {
        controlName,
        function(triggerArgs)
            local hero = CoopPlayers.GetHeroByUnit(triggerArgs.triggeredById)

            -- Online CLIENT: forward the local press to the host instead of
            -- resolving a local second hero, but ONLY for controls that map to a
            -- hero (the same `hero` resolution the offline path uses below).
            -- Non-hero controls (menus, UI, system inputs) are not part of the
            -- shared run, so they must fall through to normal local handling or
            -- the client could not drive its own menus. When offline this whole
            -- branch is never taken (IsClient() is false), so local splitscreen
            -- behavior is unchanged.
            if hero and NetSession.IsClient() then
                InputSync.SendLocalControl(controlName, triggerArgs)
                return
            end

            if hero then
                HeroContext.RunWithHeroContext(hero, handler, triggerArgs)
            else
                DebugAssert({ Condition = false, Text = "Controll was pressed without right hero context " .. controlName, Owner = "Uladzislau" })
                handler(triggerArgs)
            end
        end
    }
end

function ControlHooks.wrap.AddInputBlock(baseFun, argumenst)
    if argumenst.PlayerIndex then
        baseFun(argumenst)
    else
        for playerId = 1, CoopPlayers.GetPlayersCount() do
            argumenst.PlayerIndex = playerId
            baseFun(argumenst)
        end
    end
end

function ControlHooks.wrap.RemoveInputBlock(baseFun, argumenst)
    if argumenst.PlayerIndex then
        baseFun(argumenst)
    else
        for playerId = 1, CoopPlayers.GetPlayersCount() do
            argumenst.PlayerIndex = playerId
            baseFun(argumenst)
        end
    end
end

function ControlHooks.wrap.NotifyOnControlPressed(baseFun, argumenst)
    if argumenst.PlayerIndex then
        baseFun(argumenst)
    elseif argumenst.Notify == "FishingInput" then
        local playerId = CoopPlayers.GetPlayerByHero(CurrentRun.Hero) or 1
        argumenst.PlayerIndex = playerId
        baseFun(argumenst)
    else
        baseFun(argumenst)
    end
end

function ControlHooks.wrap.ToggleMove(ToggleMove, argumenst)
    -- Custom argument
    if argumenst.PlayerIndex then
        HeroContextNative.RunWithNativeHeroContext(argumenst.PlayerIndex, ToggleMove, argumenst)
    else
        for playerId = 1, CoopPlayers.GetPlayersCount() do
            HeroContextNative.RunWithNativeHeroContext(playerId, ToggleMove, argumenst)
        end
    end
end

return ControlHooks
