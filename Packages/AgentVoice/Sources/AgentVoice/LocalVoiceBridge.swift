import Darwin
import Foundation

/// Private same-user Unix socket; audio and model data never cross this bridge.
public enum VoicePaths {
    public static func socketURL(appID: String) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(appID)-\(getuid())", isDirectory: true)
            .appendingPathComponent("agent-voice.sock")
    }
}

private enum SocketIO {
    static let maximumFrame = 128 * 1024

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VoiceError.unavailable("Bridge path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }

    static func wait(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw VoiceError.unavailable("DictaFlow request timed out; its outcome may be unknown.") }
        let milliseconds = remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let count = poll(&item, 1, Int32(min(milliseconds, 30_000)))
        guard count > 0, item.revents & events != 0 else { throw VoiceError.unavailable("DictaFlow bridge disconnected or timed out.") }
    }

    static func write(_ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant) throws {
        guard data.count < maximumFrame else { throw VoiceError.unavailable("Bridge request is too large.") }
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw VoiceError.unavailable("Could not write to DictaFlow.") }
                offset += count
            }
        }
    }

    static func read(from descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data {
        // One request at a time per connection. Reading bytes avoids consuming the next frame.
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumFrame {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            guard Darwin.read(descriptor, &byte, 1) == 1 else { throw VoiceError.unavailable("DictaFlow bridge closed.") }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw VoiceError.unavailable("Bridge frame exceeds the size limit.")
    }

    static func isSameUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    static func configure(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }
}

public protocol VoiceBridgeClientProtocol: Sendable {
    func send(_ request: VoiceRequest) async throws -> VoiceReply
}

public struct VoiceBridgeTransportError: Error, LocalizedError, Sendable {
    public let requestMayHaveBeenAccepted: Bool
    private let message: String

    public init(requestMayHaveBeenAccepted: Bool, message: String) {
        self.requestMayHaveBeenAccepted = requestMayHaveBeenAccepted
        self.message = message
    }

    public var errorDescription: String? { message }
}

public actor LocalVoiceClient: VoiceBridgeClientProtocol {
    private let url: URL
    private var descriptor: Int32 = -1
    public init(socketURL: URL) { url = socketURL }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    public func send(_ request: VoiceRequest) throws -> VoiceReply {
        try Task.checkCancellation()
        var sentCompleteRequest = false
        do {
            if descriptor < 0 {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw VoiceError.unavailable("Could not create the DictaFlow connection.") }
                descriptor = fd; SocketIO.configure(fd)
                var address = try SocketIO.address(url.path)
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                if connected != 0 {
                    guard errno == EINPROGRESS else { throw VoiceError.unavailable("Open DictaFlow and enable Agent Voice first.") }
                    try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: .now.advanced(by: .milliseconds(100)))
                    var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw VoiceError.unavailable("Could not connect to DictaFlow.") }
                }
                guard SocketIO.isSameUser(fd) else {
                    throw VoiceError.unavailable("Could not verify the local DictaFlow server's identity.")
                }
            }
            try Task.checkCancellation()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
            try SocketIO.write(JSONEncoder().encode(request), to: descriptor, deadline: deadline)
            sentCompleteRequest = true
            return try JSONDecoder().decode(VoiceReply.self, from: SocketIO.read(from: descriptor, deadline: deadline))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            throw VoiceBridgeTransportError(requestMayHaveBeenAccepted: sentCompleteRequest, message: error.localizedDescription)
        }
    }
}

/// Blocking descriptor operations run only on dedicated queues, never the app's main actor.
public final class LocalVoiceServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var clients: Set<Int32> = []
    private let url: URL
    private let handler: @Sendable (VoiceRequest, UUID) async -> VoiceReply
    private let onDisconnect: @Sendable (UUID) async -> Void

    public init(socketURL: URL, handler: @escaping @Sendable (VoiceRequest, UUID) async -> VoiceReply,
                onDisconnect: @escaping @Sendable (UUID) async -> Void) {
        url = socketURL; self.handler = handler; self.onDisconnect = onDisconnect
    }

    public func start() throws {
        try lock.withLock { try startListener() }
    }

    private func startListener() throws {
        guard listener == nil else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
            throw VoiceError.unavailable("The local bridge directory has an unexpected owner or type.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VoiceError.unavailable("Could not create the DictaFlow bridge.") }
        var started = false
        defer { if !started { Darwin.close(fd) } }
        // Never unlink an active app's listener. Dev/release use different paths.
        if FileManager.default.fileExists(atPath: url.path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw VoiceError.unavailable("Could not check the existing DictaFlow bridge.") }
            defer { Darwin.close(probe) }
            SocketIO.configure(probe)
            var address = try SocketIO.address(url.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let connectionError = errno
            guard result != 0, connectionError == ECONNREFUSED || connectionError == ENOENT else {
                throw VoiceError.unavailable("Another DictaFlow instance may own Agent Voice.")
            }
            try FileManager.default.removeItem(at: url)
        }
        var address = try SocketIO.address(url.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw VoiceError.unavailable("Could not bind the DictaFlow bridge.") }
        chmod(url.path, 0o600)
        SocketIO.configure(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.dictaflow.voice.accept"))
        source.setEventHandler { [weak self] in self?.acceptConnection(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        started = true
        source.resume()
    }

    public func stop() {
        lock.withLock {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            for client in clients { shutdown(client, SHUT_RDWR) }
            try? FileManager.default.removeItem(at: url)
        }
    }
    deinit { stop() }

    private func acceptConnection(_ fd: Int32) {
        lock.withLock {
            guard let listener, listener.handle == UInt(fd) else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard clients.count < 8, SocketIO.isSameUser(client) else { Darwin.close(client); return }
            clients.insert(client)
            SocketIO.configure(client)
            DispatchQueue(label: "com.dictaflow.voice.connection").async { [weak self, handler, onDisconnect] in
                Self.serve(client, handler: handler, onDisconnect: onDisconnect) {
                    if let self {
                        self.lock.withLock { self.clients.remove(client); Darwin.close(client) }
                    } else {
                        Darwin.close(client)
                    }
                }
            }
        }
    }

    private static func serve(_ fd: Int32, handler: @escaping @Sendable (VoiceRequest, UUID) async -> VoiceReply,
                              onDisconnect: @escaping @Sendable (UUID) async -> Void, close: () -> Void) {
        let connection = UUID()
        var pending: Task<Void, Never>?
        defer {
            close()
            let pending = pending
            Task {
                // A timed-out attach can still commit. Disconnect only after
                // that handler can no longer create a lease for this socket.
                await pending?.value
                await onDisconnect(connection)
            }
        }
        do {
            while true {
                let data = try SocketIO.read(from: fd, deadline: .now.advanced(by: .seconds(30)))
                let request = try JSONDecoder().decode(VoiceRequest.self, from: data)
                // The queue is private to this connection. A synchronous wait here cannot block UI.
                let semaphore = DispatchSemaphore(value: 0)
                let box = ReplyBox()
                pending = Task { box.set(await handler(request, connection)); semaphore.signal() }
                guard semaphore.wait(timeout: .now() + 0.7) == .success, let reply = box.get() else { return }
                pending = nil
                try SocketIO.write(JSONEncoder().encode(reply), to: fd, deadline: .now.advanced(by: .milliseconds(700)))
            }
        } catch { /* Disconnects are normal; do not log speech or request payloads. */ }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: VoiceReply?
    func set(_ value: VoiceReply) { lock.withLock { reply = value } }
    func get() -> VoiceReply? { lock.withLock { reply } }
}
