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
---@private
NetSession.handshakeRegistered = false

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

    -- Wire the Hello / Welcome handshake and protocol-version gate. Pure Lua
    -- over the existing transport: no engine internals are needed.
    if ok then
        NetSession.RegisterHandshake()
    end

    -- The client announces itself; the host answers from its Hello handler.
    if ok and online.Role == "Client" then
        NetSession.Send(NetProtocol.EncodeHello("CoopClient"))
    end

    return ok
end

-- True once a matching-version peer has completed the handshake. Callers can
-- read this to gate gameplay traffic on a confirmed, compatible peer.
---@type boolean
NetSession.handshakeComplete = false

-- Set true when the handshake rejected the peer on a protocol-version
-- mismatch, so the pump can stop and the session can be torn down.
---@type boolean
NetSession.versionRejected = false

---Register the Hello / Welcome handshake handlers for the active role and
---enforce NetProtocol.VERSION on both sides. On a version mismatch the session
---is closed and the peer is rejected rather than allowed to silently desync.
---@private
function NetSession.RegisterHandshake()
    if NetSession.handshakeRegistered then
        return
    end
    NetSession.handshakeRegistered = true

    if Config.Online.Role == "Host" then
        -- Host answers a client's Hello with a Welcome, but only if the client's
        -- protocol version matches. A mismatch is rejected.
        NetSession.On("Hello", function(msg)
            if msg.version ~= NetProtocol.VERSION then
                DebugPrint { Text = "NetSession: rejecting client, protocol version "
                    .. tostring(msg.version) .. " != host " .. tostring(NetProtocol.VERSION) }
                NetSession.versionRejected = true
                NetSession.Close()
                return
            end
            NetSession.handshakeComplete = true
            NetSession.Send(NetProtocol.EncodeWelcome(2))
        end)
    elseif Config.Online.Role == "Client" then
        -- Client validates the host's Welcome. A version mismatch aborts the
        -- join instead of letting the client desync against an incompatible host.
        NetSession.On("Welcome", function(msg)
            if msg.version ~= NetProtocol.VERSION then
                DebugPrint { Text = "NetSession: host protocol version "
                    .. tostring(msg.version) .. " != client " .. tostring(NetProtocol.VERSION)
                    .. ", aborting join" }
                NetSession.versionRejected = true
                NetSession.Close()
                return
            end
            NetSession.handshakeComplete = true
        end)
    end
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

-- Heartbeat / disconnect tuning. There is no Lua wall-clock time source in the
-- mod, so cadence is measured in pump ticks (one per frame off Events.engine
-- "tick"). At roughly 60 fps HEARTBEAT_INTERVAL_TICKS ~= 1s between keepalives.
local HEARTBEAT_INTERVAL_TICKS = 60

-- Frames since the last heartbeat we sent. Reset after each send.
---@private
NetSession.ticksSinceHeartbeat = 0

-- Tracks whether the previous pump saw a live connection, so a drop is detected
-- exactly once (connected -> not connected) and teardown fires a single time.
---@private
NetSession.wasConnected = false

-- Set true once a mid-session peer drop has been observed and handled.
---@type boolean
NetSession.peerDropped = false

---Handle a detected peer drop: tear the session down once. Separated so tests
---and callers can reason about the single teardown path.
---@private
function NetSession.OnPeerDropped()
    if NetSession.peerDropped then
        return
    end
    NetSession.peerDropped = true
    DebugPrint { Text = "NetSession: peer disconnected, closing session" }
    NetSession.messages:trigger("PeerDropped", {})
    NetSession.Close()
end

---Pump the transport: poll the socket, drain and dispatch every pending
---message, send periodic heartbeats, and detect a dropped peer. Registered as
---the "tick" handler, so it runs once per frame.
function NetSession.Pump()
    if not NetSession.IsOnline() or not NetSession.started then
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

    -- Disconnect detection: a transition from connected to not-connected while
    -- the session is still started means the peer dropped mid-session.
    local connected = CoopNetIsConnected()
    if NetSession.wasConnected and not connected then
        NetSession.OnPeerDropped()
        return
    end
    NetSession.wasConnected = connected

    -- Keepalive: send a heartbeat on a fixed tick cadence while connected so an
    -- otherwise-idle stream still surfaces a drop (a dead socket fails to send
    -- and flips IsConnected() false, caught above on the next pump).
    if connected then
        NetSession.ticksSinceHeartbeat = NetSession.ticksSinceHeartbeat + 1
        if NetSession.ticksSinceHeartbeat >= HEARTBEAT_INTERVAL_TICKS then
            NetSession.ticksSinceHeartbeat = 0
            NetSession.Send(NetProtocol.EncodeHeartbeat(0))
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
        NetSession.wasConnected = false
        NetSession.ticksSinceHeartbeat = 0
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
