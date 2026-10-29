import Darwin
import Foundation
import PaletteCore

/// Unix socket listener for shell connections.
final class Server {
    let path: String
    var onConnect: ((Connection) -> Void)?
    private var listener: Int32 = -1

    init(path: String) {
        self.path = path
    }

    /// True when another Palette instance already answers on the socket.
    static func isRunning(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withAddress(path) { connect(fd, $0, $1) } == 0
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)  // shell snapshots are written here
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        guard Self.withAddress(path, { bind(listener, $0, $1) }) == 0, listen(listener, 16) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        let fd = listener
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let connection = Connection(fd: client)
                DispatchQueue.main.async { self?.onConnect?(connection) }
            }
        }
    }

    func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        unlink(path)
    }

    @discardableResult
    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// One shell. Reads on a background thread and delivers messages on main.
final class Connection {
    let fd: Int32
    var onMessage: ((ShellMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    static let maxPending = 1 << 20

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func start() {
        let fd = fd
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                // Messages are short lines; a shell sending more is broken.
                if pending.count > Self.maxPending, !pending.contains(0x0A) { break }
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let message = ShellMessage.parse(Substring(line)) {
                        DispatchQueue.main.async { self?.onMessage?(message) }
                    }
                }
            }
            DispatchQueue.main.async { self?.close() }
        }
    }

    func send(_ message: AppMessage) {
        guard !closed else { return }
        let bytes = Array(message.encoded.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                if n < 0, errno == EINTR { continue }
                Log.write("send failed on fd \(fd): errno \(errno)")
                return
            }
            offset += n
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        onClose?()
    }
}
