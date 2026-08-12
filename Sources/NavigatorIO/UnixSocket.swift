import Darwin
import Foundation

public enum SocketError: Error, Equatable {
    case pathTooLong
    case systemCall(String, Int32)
    case closed
    case timedOut
}

/// A thin blocking wrapper over an `AF_UNIX` stream socket.
///
/// Deliberately blocking with explicit deadlines rather than async: the hook is
/// a short-lived process that does exactly one exchange and exits, and the
/// daemon's accept loop runs on its own thread. Introducing async here would add
/// an executor to a process whose whole job is to start, talk, and die.
public final class UnixSocket: @unchecked Sendable {
    public let fileDescriptor: Int32
    private var buffer = Data()
    private var isClosed = false

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit { close() }

    // MARK: - Address

    private static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }

        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func withSockAddr<R>(
        _ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Lifecycle

    public static func listen(at path: String) throws -> UnixSocket {
        var addr = try address(for: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.systemCall("socket", errno) }

        // A socket file left by a killed daemon would make bind fail with
        // EADDRINUSE forever. Removing it is safe: a live daemon holds the
        // socket, not the directory entry.
        unlink(path)

        let bound = withSockAddr(&addr) { sa, len in Darwin.bind(fd, sa, len) }
        guard bound == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw SocketError.systemCall("bind", saved)
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw SocketError.systemCall("listen", saved)
        }
        return UnixSocket(fileDescriptor: fd)
    }

    public static func connect(to path: String, timeout: TimeInterval) throws -> UnixSocket {
        var addr = try address(for: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.systemCall("socket", errno) }

        var tv = timeval(seconds: timeout)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withSockAddr(&addr) { sa, len in Darwin.connect(fd, sa, len) }
        guard connected == 0 else {
            let saved = errno
            Darwin.close(fd)
            // ENOENT / ECONNREFUSED here is the ordinary "daemon not running"
            // case. The caller treats it as success, not as an error.
            throw SocketError.systemCall("connect", saved)
        }
        return UnixSocket(fileDescriptor: fd)
    }

    public func accept() throws -> UnixSocket {
        let fd = Darwin.accept(fileDescriptor, nil, nil)
        guard fd >= 0 else { throw SocketError.systemCall("accept", errno) }
        return UnixSocket(fileDescriptor: fd)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
    }

    // MARK: - I/O

    public func write(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                Darwin.write(fileDescriptor, raw.baseAddress, raw.count)
            }
            if written > 0 {
                remaining = Data(remaining.dropFirst(written))
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw SocketError.systemCall("write", errno)
            }
        }
    }

    /// Reads until the first newline, inclusive.
    ///
    /// Enforces its own deadline instead of relying on `SO_RCVTIMEO` alone,
    /// because a socket that dribbles one byte at a time would reset that
    /// timeout on every byte and never actually expire.
    public func readLine(deadline: TimeInterval) throws -> Data {
        let expiry = Date().addingTimeInterval(deadline)

        while true {
            if let index = buffer.firstIndex(of: 0x0a) {
                // Re-base both slices with `Data(...)`. Slicing a Data preserves
                // the parent's indices, so a sliced buffer whose startIndex is
                // no longer 0 will break the next `firstIndex` comparison.
                let line = Data(buffer[buffer.startIndex...index])
                buffer = Data(buffer[buffer.index(after: index)...])
                return line
            }

            let remaining = expiry.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketError.timedOut }

            var tv = timeval(seconds: remaining)
            setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO,
                       &tv, socklen_t(MemoryLayout<timeval>.size))

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)

            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw SocketError.closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw SocketError.timedOut
            } else {
                throw SocketError.systemCall("read", errno)
            }
        }
    }
}

extension timeval {
    init(seconds: TimeInterval) {
        let whole = max(0, seconds)
        self.init(
            tv_sec: Int(whole),
            tv_usec: Int32((whole - Double(Int(whole))) * 1_000_000))
    }
}
