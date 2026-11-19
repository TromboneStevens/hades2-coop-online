//
// Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for details.
//

#pragma once

#include <cstdint>
#include <deque>
#include <string>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

// Self-contained, non-blocking TCP transport used by the online coop session
// layer. A single NetTransport instance acts either as a host (listens and
// accepts exactly one peer) or as a client (connects to a host). Messages are
// framed on the wire with a 4-byte little-endian length prefix followed by the
// payload bytes.
//
// This header intentionally depends only on the standard library and Winsock2;
// it does not include any hades2/* engine header so it stays reviewable without
// the engine-interface submodule.
class NetTransport {
  public:
    enum Role { None, Host, Client };

    NetTransport() = default;
    ~NetTransport();

    NetTransport(const NetTransport &) = delete;
    NetTransport &operator=(const NetTransport &) = delete;

    // Start listening for a single incoming peer on the given port. Returns
    // true if the listening socket was created successfully.
    bool StartHost(uint16_t port);

    // Begin connecting to the given host address and port. The connect
    // completes asynchronously; drive it with Poll(). Returns true if the
    // connect was initiated.
    bool StartClient(const std::string &address, uint16_t port);

    // Non-blocking progress: accept a pending peer (host), finish an in-flight
    // connect (client), flush any pending outbound bytes, and drain the socket
    // into the inbound message buffer. Never blocks the game thread.
    void Poll();

    // Queue a framed message for sending. Returns false if there is no active
    // connection. Partial sends are tolerated via the pending outbound buffer.
    bool Send(const std::string &message);

    // Pop one complete inbound message if one is available. Returns true and
    // fills out when a message was dequeued, false otherwise.
    bool PollMessage(std::string &out);

    // True once a peer connection is established.
    bool IsConnected() const;

    // Close all sockets and release Winsock. Resets the transport to None.
    void Close();

    Role GetRole() const { return role; }

  private:
#ifdef _WIN32
    bool EnsureWinsock();
    void SetNonBlocking(SOCKET sock);
    void DrainReceive();
    void FlushSend();
    void ExtractMessages();
    void CloseSocket(SOCKET &sock);

    bool wsaStarted = false;
    SOCKET listenSocket = INVALID_SOCKET;
    SOCKET peerSocket = INVALID_SOCKET;
    bool connecting = false;
#endif

    Role role = None;
    bool connected = false;

    std::vector<char> recvBuffer;      // raw bytes accumulated from the socket
    std::vector<char> sendBuffer;      // framed bytes waiting to be written
    std::deque<std::string> inbox;     // complete decoded messages
};
