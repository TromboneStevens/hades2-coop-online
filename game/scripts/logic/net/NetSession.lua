--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

-- NetSession: the online-coop session controller. It owns the per-frame pump
-- over the FEAT-002 native transport (the Coop* net globals) and routes decoded
-- messages to handlers registered by HostSync / InputSync.
--
-- Everything here is inert unless Config.CoopMode == "Online"; IsOnline() is the
-- single gate the rest of the online layer branches on.

---@type CoopModConfig
local Config = ModRequire "../../config.lua"
---@type Events
local Events = ModRequire "../Events.lua"
---@type Observable
local Observable = ModRequire "../../utils/Observable.lua"
---@type NetProtocol
local NetProtocol = ModRequire "NetProtocol.lua"

---@class NetSession
local NetSession = {}

-- Message bus. Handlers register with messages:on("Hello"/"Welcome"/"InputEvent"
-- /"StateSnapshot"/"Heartbeat", fun(msg)) and Pump triggers the matching kind.
---@type Observable
NetSession.messages = Observable.new()

---@private
NetSession.started = false
---@private
NetSession.pumpRegistered = false

---@return boolean
function NetSession.IsOnline()
    return Config.CoopMode == "Online"
end

---@return "None" | "Host" | "Client"
function NetSession.GetRole()
    -- CoopNetGetRole reflects the live transport role; before Start() it is
    -- "None". Fall back to the configured role so callers can reason about
    -- intent even before the socket is up.
    local role = CoopNetGetRole()
    if role and role ~= "None" then
        return role
    end
    return "None"
end

---@return boolean
function NetSession.IsHost()
    return NetSession.IsOnline() and Config.Online.Role == "Host"
end

---@return boolean
function NetSession.IsClient()
    return NetSession.IsOnline() and Config.Online.Role == "Client"
end

---@return boolean
function NetSession.IsConnected()
    return NetSession.IsOnline() and CoopNetIsConnected()
end

---Start the transport according to config and register the per-frame pump.
---No-op (returns false) unless CoopMode == "Online". Safe to call once.
---@return boolean started whether a host/client transport was started
function NetSession.Start()
    if not NetSession.IsOnline() then
        return false
    end

    if NetSession.started then
        return true
    end

    local online = Config.Online
    local ok = false

    if online.Role == "Host" then
        ok = CoopNetStartHost(online.Port) and true or false
    elseif online.Role == "Client" then
        ok = CoopNetStartClient(online.HostAddress, online.Port) and true or false
    else
        DebugPrint { Text = "NetSession: unknown Online.Role " .. tostring(online.Role) }
        return false
    end

    NetSession.started = ok

    -- Drive Pump() each frame. Events.engine "tick" is already triggered every
    -- frame from hooks/EngineHooks.lua (EngineHooks.post.draw), so we hang the
    -- pump off that existing per-frame bus rather than adding a new driver.
    if ok and not NetSession.pumpRegistered then
        Events.engine:on("tick", NetSession.Pump)
        NetSession.pumpRegistered = true
    end

    -- The client announces itself; the host answers from its Hello handler.
    if ok and online.Role == "Client" then
        NetSession.Send(NetProtocol.EncodeHello("CoopClient"))
    end

    return ok
end

---Send an already-encoded protocol string over the transport.
---@param encoded string
---@return boolean
function NetSession.Send(encoded)
    if not NetSession.IsOnline() or not encoded then
        return false
    end
    return CoopNetSend(encoded) and true or false
end

---Pump the transport: poll the socket, then drain and dispatch every pending
---message. Registered as the "tick" handler, so it runs once per frame.
function NetSession.Pump()
    if not NetSession.IsOnline() then
        return
    end

    CoopNetPoll()

    while true do
        local raw = CoopNetReceive()
        if not raw then
            break
        end

        local msg = NetProtocol.Decode(raw)
        if msg then
            NetSession.messages:trigger(msg.kind, msg)
        end
    end
end

---Register a handler for a decoded message kind.
---@param kind "Hello" | "Welcome" | "InputEvent" | "StateSnapshot" | "Heartbeat"
---@param fun fun(msg: table)
function NetSession.On(kind, fun)
    NetSession.messages:on(kind, fun)
end

function NetSession.Close()
    if NetSession.started then
        CoopNetClose()
        NetSession.started = false
    end
end

---Start the session purely from config.lua (CoopMode / Online.Role /
---Online.HostAddress / Online.Port). This is the entry point referenced by the
---menu note in CoopMenu.lua: host/join selection is config-driven for now,
---so starting as host or client only requires editing config.lua and is
---identical to NetSession.Start().
---@return boolean
function NetSession.StartFromConfig()
    return NetSession.Start()
end

return NetSession
