import Foundation

public enum FanControlXPC {
    public static let serviceName = "local.Mac-TaskManager.FanHelper.v2"
    public static let legacyServiceName = "local.Mac-TaskManager.FanHelper"
    public static let protocolVersion = "2"
    public static let mainApplicationIdentifier = "local.Mac-TaskManager"
    public static let launchDaemonPlistName = "\(serviceName).plist"

    public enum ConnectionError: LocalizedError {
        case failed(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .failed(let reason): return "无法连接风扇控制服务：\(reason)"
            case .timeout: return "风扇控制服务没有及时响应，请重新尝试或修复服务。"
            }
        }
    }

    public static func perform(
        timeout: TimeInterval = 15,
        _ operation: @escaping (FanControlXPCProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Result<Void, Error>?
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard response == nil else { return }
            response = result
            semaphore.signal()
        }

        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
        connection.interruptionHandler = { finish(.failure(ConnectionError.failed("连接被中断"))) }
        connection.invalidationHandler = { finish(.failure(ConnectionError.failed("连接已失效"))) }
        connection.resume()
        defer {
            connection.interruptionHandler = nil
            connection.invalidationHandler = nil
            connection.invalidate()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(ConnectionError.failed(error.localizedDescription)))
        }) as? FanControlXPCProtocol else {
            throw ConnectionError.failed("无法创建服务代理")
        }
        proxy.ping { success, version in
            lock.lock()
            let finished = response != nil
            lock.unlock()
            guard !finished else { return }
            guard success, version == protocolVersion, connection.effectiveUserIdentifier == 0 else {
                finish(.failure(ConnectionError.failed("服务身份或版本不匹配，请更新服务")))
                return
            }
            operation(proxy) { success, message in
                finish(success ? .success(()) : .failure(ConnectionError.failed(message ?? "操作失败")))
            }
        }
        if semaphore.wait(timeout: .now() + timeout) != .success {
            finish(.failure(ConnectionError.timeout))
        }
        lock.lock()
        let result = response
        lock.unlock()
        try result?.get()
    }

    public static func checkConnection() throws {
        try perform(timeout: 3) { _, reply in reply(true, nil) }
    }
}

@objc public protocol FanControlXPCProtocol {
    func ping(withReply reply: @escaping (Bool, String?) -> Void)
    func heartbeat(withReply reply: @escaping (Bool, String?) -> Void)
    func restoreAll(withReply reply: @escaping (Bool, String?) -> Void)
    func setFanRPM(
        index: Int,
        rpm: Double,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func setFanAutomatic(
        index: Int,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func updateCoolModeTargets(
        indexes: [NSNumber],
        rpms: [NSNumber],
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func stopCoolMode(withReply reply: @escaping (Bool, String?) -> Void)
}
