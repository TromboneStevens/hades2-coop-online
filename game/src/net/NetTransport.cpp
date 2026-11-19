//
// Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for details.
//

#include "net/NetTransport.h"

NetTransport::~NetTransport() {
    Close();
}

#ifdef _WIN32

bool NetTransport::EnsureWinsock() {
    if (wsaStarted)
        return true;

    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0)
        return false;

    wsaStarted = true;
    return true;
}

void NetTransport::SetNonBlocking(SOCKET sock) {
    u_long mode = 1;
    ioctlsocket(sock, FIONBIO, &mode);
}

void NetTransport::CloseSocket(SOCKET &sock) {
    if (sock != INVALID_SOCKET) {
        closesocket(sock);
        sock = INVALID_SOCKET;
    }
}

bool NetTransport::StartHost(uint16_t port) {
    Close();

    if (!EnsureWinsock())
        return false;

    listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSocket == INVALID_SOCKET)
        return false;

    BOOL reuse = TRUE;
    setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char *>(&reuse), sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(listenSocket, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == SOCKET_ERROR) {
        CloseSocket(listenSocket);
        return false;
    }

    if (listen(listenSocket, 1) == SOCKET_ERROR) {
        CloseSocket(listenSocket);
        return false;
    }

    SetNonBlocking(listenSocket);
    role = Host;
    connected = false;
    connecting = false;
    return true;
}

bool NetTransport::StartClient(const std::string &address, uint16_t port) {
    Close();

    if (!EnsureWinsock())
        return false;

    peerSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (peerSocket == INVALID_SOCKET)
        return false;

    SetNonBlocking(peerSocket);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, address.c_str(), &addr.sin_addr) != 1) {
        CloseSocket(peerSocket);
        return false;
    }

    role = Client;
    connected = false;
    connecting = true;

    int result = connect(peerSocket, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
    if (result == 0) {
        connecting = false;
        connected = true;
    } else {
        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK && err != WSAEINPROGRESS) {
            CloseSocket(peerSocket);
            role = None;
            connecting = false;
            return false;
        }
    }

    return true;
}

void NetTransport::Poll() {
    // Host: accept a single pending peer if we do not have one yet.
    if (role == Host && !connected && listenSocket != INVALID_SOCKET) {
        SOCKET accepted = accept(listenSocket, nullptr, nullptr);
        if (accepted != INVALID_SOCKET) {
            peerSocket = accepted;
            SetNonBlocking(peerSocket);
            connected = true;
            // One peer only; stop listening for further connections.
            CloseSocket(listenSocket);
        }
    }

    // Client: wait for the non-blocking connect to complete.
    if (role == Client && connecting && peerSocket != INVALID_SOCKET) {
        fd_set writeSet;
        fd_set exceptSet;
        FD_ZERO(&writeSet);
        FD_ZERO(&exceptSet);
        FD_SET(peerSocket, &writeSet);
        FD_SET(peerSocket, &exceptSet);

        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 0;

        int ready = select(0, nullptr, &writeSet, &exceptSet, &tv);
        if (ready > 0) {
            if (FD_ISSET(peerSocket, &exceptSet)) {
                CloseSocket(peerSocket);
                connecting = false;
                connected = false;
                role = None;
            } else if (FD_ISSET(peerSocket, &writeSet)) {
                connecting = false;
                connected = true;
            }
        }
    }

    if (!connected)
        return;

    FlushSend();
    DrainReceive();
    ExtractMessages();
}

void NetTransport::FlushSend() {
    if (sendBuffer.empty() || peerSocket == INVALID_SOCKET)
        return;

    size_t offset = 0;
    while (offset < sendBuffer.size()) {
        int sent = send(peerSocket, sendBuffer.data() + offset,
                        static_cast<int>(sendBuffer.size() - offset), 0);
        if (sent == SOCKET_ERROR) {
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK)
                break; // socket full; keep remaining bytes pending
            // Hard error: tear down the connection.
            CloseSocket(peerSocket);
            connected = false;
            sendBuffer.clear();
            return;
        }
        if (sent == 0)
            break;
        offset += static_cast<size_t>(sent);
    }

    if (offset > 0)
        sendBuffer.erase(sendBuffer.begin(), sendBuffer.begin() + offset);
}

void NetTransport::DrainReceive() {
    if (peerSocket == INVALID_SOCKET)
        return;

    char chunk[4096];
    for (;;) {
        int received = recv(peerSocket, chunk, sizeof(chunk), 0);
        if (received > 0) {
            recvBuffer.insert(recvBuffer.end(), chunk, chunk + received);
        } else if (received == 0) {
            // Peer closed the connection gracefully.
            CloseSocket(peerSocket);
            connected = false;
            return;
        } else {
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK)
                break; // no more data for now
            CloseSocket(peerSocket);
            connected = false;
            return;
        }
    }
}

void NetTransport::ExtractMessages() {
    // Split the raw receive buffer on the 4-byte little-endian length prefix.
    for (;;) {
        if (recvBuffer.size() < 4)
            return;

        uint32_t length = static_cast<uint32_t>(static_cast<uint8_t>(recvBuffer[0])) |
                          (static_cast<uint32_t>(static_cast<uint8_t>(recvBuffer[1])) << 8) |
                          (static_cast<uint32_t>(static_cast<uint8_t>(recvBuffer[2])) << 16) |
                          (static_cast<uint32_t>(static_cast<uint8_t>(recvBuffer[3])) << 24);

        if (recvBuffer.size() < 4 + static_cast<size_t>(length))
            return; // wait for the rest of the payload

        inbox.emplace_back(recvBuffer.begin() + 4, recvBuffer.begin() + 4 + length);
        recvBuffer.erase(recvBuffer.begin(), recvBuffer.begin() + 4 + length);
    }
}

bool NetTransport::Send(const std::string &message) {
    if (!connected || peerSocket == INVALID_SOCKET)
        return false;

    uint32_t length = static_cast<uint32_t>(message.size());
    char prefix[4];
    prefix[0] = static_cast<char>(length & 0xFF);
    prefix[1] = static_cast<char>((length >> 8) & 0xFF);
    prefix[2] = static_cast<char>((length >> 16) & 0xFF);
    prefix[3] = static_cast<char>((length >> 24) & 0xFF);

    sendBuffer.insert(sendBuffer.end(), prefix, prefix + 4);
    sendBuffer.insert(sendBuffer.end(), message.begin(), message.end());

    FlushSend();
    return true;
}

bool NetTransport::PollMessage(std::string &out) {
    if (inbox.empty())
        return false;

    out = std::move(inbox.front());
    inbox.pop_front();
    return true;
}

bool NetTransport::IsConnected() const {
    return connected;
}

void NetTransport::Close() {
    CloseSocket(peerSocket);
    CloseSocket(listenSocket);

    if (wsaStarted) {
        WSACleanup();
        wsaStarted = false;
    }

    connecting = false;
    connected = false;
    role = None;
    recvBuffer.clear();
    sendBuffer.clear();
    inbox.clear();
}

#else // !_WIN32

// Non-Windows fallback: the engine target is Windows/MSVC only, so networking
// is a no-op here. This keeps the translation unit conceptually portable and
// reviewable on other platforms.

bool NetTransport::StartHost(uint16_t) {
    return false;
}

bool NetTransport::StartClient(const std::string &, uint16_t) {
    return false;
}

void NetTransport::Poll() {
}

bool NetTransport::Send(const std::string &) {
    return false;
}

bool NetTransport::PollMessage(std::string &) {
    return false;
}

bool NetTransport::IsConnected() const {
    return false;
}

void NetTransport::Close() {
    connected = false;
    role = None;
    recvBuffer.clear();
    sendBuffer.clear();
    inbox.clear();
}

#endif // _WIN32
