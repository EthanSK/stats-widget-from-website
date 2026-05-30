//
//  MCPClient.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Minimal local client for power-user CLI calls to the app socket.
//

import Darwin
import Foundation

final class MCPClient {
    private let socketURL: URL
    private let token: String?

    init(socketURL: URL = AppGroupPaths.mcpSocketURL(), token: String? = nil) {
        self.socketURL = socketURL
        self.token = token
    }

    // v0.21.74 — socket read budget. Before this, a remote MCP host that
    // accepted the connection but never replied would pin this thread FOREVER:
    // `readData(ofLength: 1)` blocks indefinitely with no deadline. We now set
    // SO_RCVTIMEO so each blocking read gives up after this many seconds and
    // surfaces as `ClientError.invalidResponse` instead of hanging the caller.
    // 30s is comfortably longer than any healthy tools/call round-trip on a
    // local UNIX-domain socket while still bounding a wedged host.
    private static let socketReadTimeoutSeconds: Int = 30

    func call(toolName: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.socketCreateFailed(errno)
        }

        // v0.21.74 — install a receive timeout on the socket BEFORE connect/IO.
        // SO_RCVTIMEO makes every subsequent blocking read (read(2) below)
        // return -1 with errno EAGAIN/EWOULDBLOCK once the timeout elapses with
        // no data, instead of blocking forever. This is the core "no socket
        // read timeout" fix — see `socketReadTimeoutSeconds` above and the
        // EAGAIN handling in `readLine(fromFD:)`.
        var timeout = timeval(tv_sec: Self.socketReadTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = socketURL.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            close(fd)
            throw ClientError.socketPathTooLong
        }

        _ = path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pointer, maxPathLength - 1)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw ClientError.socketConnectFailed(errno)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let token {
            try handle.write(contentsOf: Data("X-Auth: \(token)\n".utf8))
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        try handle.write(contentsOf: data + Data("\n".utf8))

        // v0.21.74 — read directly from the fd (not the FileHandle) so we can
        // observe the EAGAIN/EWOULDBLOCK errno that SO_RCVTIMEO raises on a
        // timed-out read. `handle` keeps owning the fd (closeOnDealloc) for the
        // write path above; we just bypass FileHandle for the read loop.
        let response = readLine(fromFD: fd)
        guard let response,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ClientError.invalidResponse
        }

        return object
    }

    // v0.21.74 — byte-wise line reader over the raw fd. Returns the line bytes
    // up to (not including) the first newline, or `nil` on EOF / timeout /
    // error. With SO_RCVTIMEO set on `fd`, a host that connects but goes silent
    // makes `read(2)` return -1 / EAGAIN after the timeout window; we map that
    // to `nil`, which the caller turns into `ClientError.invalidResponse`
    // rather than hanging forever. A genuine short read at EOF (0 bytes) before
    // any newline also returns `nil` so a truncated/partial response is treated
    // as invalid, not silently accepted.
    private func readLine(fromFD fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 10 { // newline terminates the line
                    return data
                }
                data.append(byte)
                continue
            }
            if n == 0 {
                // EOF: peer closed. Partial data before a newline is treated as
                // truncated → invalid (nil), matching the old behaviour where
                // an empty read returned nil.
                return data.isEmpty ? nil : data
            }
            // n < 0 — read error. EINTR: retry. EAGAIN/EWOULDBLOCK: the
            // SO_RCVTIMEO budget elapsed with no reply → give up (nil →
            // invalidResponse). Any other errno is also a hard failure → nil.
            if errno == EINTR {
                continue
            }
            return nil
        }
    }

    enum ClientError: LocalizedError {
        case socketCreateFailed(Int32)
        case socketConnectFailed(Int32)
        case socketPathTooLong
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .socketCreateFailed(let code):
                return "Could not create MCP socket: \(code)."
            case .socketConnectFailed(let code):
                return "Could not connect to MCP socket: \(code)."
            case .socketPathTooLong:
                return "MCP socket path is too long."
            case .invalidResponse:
                return "MCP server response was not valid JSON."
            }
        }
    }
}
