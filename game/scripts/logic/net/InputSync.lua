--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

-- InputSync: the input half of online coop.
--
--   Client: capture a local control press and send it to the host as an
--           InputEvent instead of driving a local second hero.
--   Host  : receive InputEvent messages and replay them as the remote player
--           (player 2) through the SAME per-hero dispatch the local build uses,
--           i.e. HeroContext.RunWithHeroContext(hero, handler, triggerArgs).
--
-- This module is a plain table and only runs on the online path. The offline
-- OnControlPressed behavior is untouched: hooks/ControlHooks.lua branches on
-- NetSession.IsOnline() and only calls into here when online.

---@type CoopPlayers
local CoopPlayers = ModRequire "../CoopPlayers.lua"
---@type HeroContext
local HeroContext = ModRequire "../HeroContext.lua"
---@type NetSession
local NetSession = ModRequire "NetSession.lua"
---@type NetProtocol
local NetProtocol = ModRequire "NetProtocol.lua"

---@class InputSync
local InputSync = {}

local REMOTE_PLAYER_ID = 2

-- Host side: control-name -> gameplay handler, populated by ControlHooks as it
-- registers each OnControlPressed so received InputEvents can be replayed
-- through the exact same handler the local build would have run.
---@type table<string, function>
InputSync.handlers = {}

---Host: remember the gameplay handler registered for a control name, so a
---network InputEvent for that control can be injected as player 2.
---@param controlName string
---@param handler function
function InputSync.RegisterHandler(controlName, handler)
    InputSync.handlers[controlName] = handler
end

---Client: forward a local control press to the host.
---@param controlName string
---@param triggerArgs table the engine OnControlPressed trigger args
function InputSync.SendLocalControl(controlName, triggerArgs)
    if not NetSession.IsClient() then
        return
    end

    -- Analog axes: the OnControlPressed trigger only reports a discrete press,
    -- so dx/dy are left at 0 here. Continuous analog movement needs a per-frame
    -- input poll hook that does not exist in the Lua layer yet; see the design
    -- doc stubbed section (TODO: analog movement sampling).
    NetSession.Send(NetProtocol.EncodeInput {
        playerId = REMOTE_PLAYER_ID,
        controlName = controlName,
        dx = 0,
        dy = 0,
        pressed = true,
    })
end

---Build a trigger-args table for an injected control. Mirrors the shape the
---local OnControlPressed path relies on: triggeredById is the remote hero's
---unit so downstream per-hero routing resolves the right hero.
---@param hero table
---@param msg table decoded InputEvent
---@return table
local function SynthesizeTriggerArgs(hero, msg)
    return {
        triggeredById = hero.ObjectId,
        PlayerIndex = msg.playerId,
        Name = msg.controlName,
        -- Analog values if/when the client samples them (currently 0).
        AnalogX = msg.dx,
        AnalogY = msg.dy,
    }
end

---Host: inject a received InputEvent as the remote player through the existing
---HeroContext dispatch.
---@param msg table decoded InputEvent
function InputSync.OnInputEvent(msg)
    if not NetSession.IsHost() then
        return
    end

    local handler = InputSync.handlers[msg.controlName]
    if not handler then
        -- No gameplay handler was registered for this control; nothing to run.
        return
    end

    local hero = CoopPlayers.GetHero(msg.playerId or REMOTE_PLAYER_ID)
    if not hero then
        return
    end

    local triggerArgs = SynthesizeTriggerArgs(hero, msg)
    HeroContext.RunWithHeroContext(hero, handler, triggerArgs)
end

---Register the host-side InputEvent handler. Called from GamemodeInit on the
---online path.
function InputSync.Init()
    if NetSession.IsHost() then
        NetSession.On("InputEvent", InputSync.OnInputEvent)
    end
end

return InputSync
