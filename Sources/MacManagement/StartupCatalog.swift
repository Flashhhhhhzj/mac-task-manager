import AppKit
import CoreServices
import Security

public struct StartupItem: Identifiable, Codable {
    public let id: String
    public var name: String
    public var publisher: String
    public var path: String?
    public var enabled: Bool?
    public var source: String
    public var service: ServiceIdentifier?
    public var legacyURL: URL?
    public var requiresSettings = false
    public var protectionReason: String?
    public var backgroundIdentifier: String?
    public var state: String { requiresSettings && protectionReason != nil ? "等待系统允许" : enabled.map { $0 ? "已启用" : "已禁用" } ?? "未知" }
    public var impact: String { enabled.map { $0 ? "未计量" : "无" } ?? "—" }
}

public struct StartupCatalogRequest: Codable {
    public let services: [ServiceRecord]
    public let backgroundOutput: String?
    public init(services: [ServiceRecord], backgroundOutput: String?) {
        self.services = services; self.backgroundOutput = backgroundOutput
    }
}

public struct StartupCatalogResult: Codable {
    public let items: [StartupItem]
    public let warnings: [String]
    public init(items: [StartupItem], warnings: [String]) { self.items = items; self.warnings = warnings }
}

public enum StartupCatalog {
    // The read-only subprocess must use the application's existing login-item preferences.
    private static let preferences = UserDefaults(suiteName: "local.Mac-TaskManager") ?? .standard
    static let disabledLoginKey = "DisabledLegacyLoginItems"
    static let hiddenLoginKey = "DisabledLegacyLoginItemHidden"

    public static func load(services: [ServiceRecord], backgroundOutput: String? = nil) -> (items: [StartupItem], warnings: [String]) {
        var warnings: [String] = []
        var items = serviceItems(services, enrichMetadata: true)
        do { items += try legacyLoginItems() } catch { warnings.append(error.localizedDescription) }
        var background: [StartupItem] = []
        if let backgroundOutput {
            if backgroundOutput.contains("Records for UID ") { background = parseBTM(backgroundOutput, uid: getuid()) }
            else { warnings.append("无法识别 macOS 后台项目列表。") }
        }
        for index in items.indices {
            if let label = items[index].service?.label,
               let metadata = background.first(where: { $0.backgroundIdentifier == label }) {
                if items[index].enabled == nil { items[index].enabled = metadata.enabled }
                if items[index].publisher == "—" { items[index].publisher = metadata.publisher }
                if items[index].name == label { items[index].name = metadata.name }
            }
        }
        let knownPaths = Set(items.compactMap { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let knownLabels = Set(items.compactMap(\.service?.label))
        items += background.filter { item in
            !knownLabels.contains(item.backgroundIdentifier ?? "")
                && !(item.path.map { knownPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? false)
        }
        // The legacy list can contain multiple bookmarks for the same application.
        var seen = Set<String>()
        return (items.filter { seen.insert($0.id).inserted }, warnings)
    }

    public static func serviceItems(_ services: [ServiceRecord], enrichMetadata: Bool = false) -> [StartupItem] {
        services.filter {
            $0.startsAutomatically && $0.plistPath?.hasPrefix("/System/") == false && !$0.identifier.label.hasPrefix("com.apple.")
                && !$0.identifier.label.hasPrefix("local.Mac-TaskManager.")
        }.map { service in
            let path = service.programPath
            return StartupItem(id: service.id, name: enrichMetadata ? applicationName(path) ?? service.name : service.name,
                publisher: enrichMetadata ? publisher(path) : "—", path: path ?? service.plistPath, enabled: service.enabled,
                source: service.identifier.domain == "system" ? "系统 LaunchDaemon" : "登录 LaunchAgent",
                service: service.identifier, protectionReason: service.protectionReason)
        }
    }

    public static func parseBTM(_ text: String, uid: UInt32) -> [StartupItem] {
        var currentUID: Int64?
        var fields: [String: String] = [:]
        var records: [(uid: Int64, fields: [String: String])] = []
        func appendRecord() {
            if let currentUID, currentUID == Int64(uid) || currentUID == -2, fields["Identifier"] != nil {
                records.append((currentUID, fields))
            }
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Records for UID ") {
                appendRecord(); fields = [:]
                currentUID = Int64(trimmed.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber })
            } else if trimmed.hasPrefix("#"), trimmed.hasSuffix(":"), Int(trimmed.dropFirst().dropLast()) != nil {
                appendRecord(); fields = [:]
            } else if let colon = trimmed.firstIndex(of: ":") {
                fields[String(trimmed[..<colon])] = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        appendRecord()
        let parents = Set(records.compactMap { $0.fields["Parent Identifier"] }.filter { $0 != "(null)" })
        func absolutePath(_ value: String?) -> String? {
            value.flatMap { $0.hasPrefix("file:") ? URL(string: $0)?.path : ($0.hasPrefix("/") ? $0 : nil) }
        }
        var result: [StartupItem] = []
        for record in records {
            let fields = record.fields
            guard let type = fields["Type"], let identifier = fields["Identifier"], !identifier.isEmpty else { continue }
            let disposition = fields["Disposition"] ?? ""
            let flags = Set(disposition.components(separatedBy: CharacterSet(charactersIn: "[],()")).map { $0.trimmingCharacters(in: .whitespaces) })
            let mainApp = record.uid == Int64(uid) && type.hasPrefix("app (") && (flags.contains("enabled") || (flags.contains("notified") && !parents.contains(identifier)))
            guard mainApp || type.contains("login item") || type.contains("agent") || type.contains("daemon") || type.hasPrefix("background tasks") else { continue }
            var path = absolutePath(fields["URL"]) ?? absolutePath(fields["Executable Path"])
            let parent = records.first { $0.fields["Identifier"] == fields["Parent Identifier"] }
            if path == nil, let base = absolutePath(parent?.fields["URL"]),
               let relative = fields["URL"], relative.hasPrefix("Contents/"), !relative.split(separator: "/").contains("..") {
                path = URL(fileURLWithPath: base).appendingPathComponent(relative).path
            }
            if path == nil, type.hasPrefix("background tasks") { path = absolutePath(parent?.fields["URL"]) }
            let enabled: Bool? = flags.contains("disabled") ? false : (flags.contains("enabled") ? !flags.contains("disallowed") : nil)
            func developerName(_ value: String?) -> String? { value.flatMap { $0.isEmpty || $0 == "(null)" ? nil : $0 } }
            let developer = developerName(fields["Developer Name"]) ?? developerName(parent?.fields["Developer Name"])
            let parts = identifier.split(separator: ".", maxSplits: 1)
            let serviceLabel = parts.count == 2 && UInt32(parts[0]) != nil ? String(parts[1]) : identifier
            let ownHelper = serviceLabel.hasPrefix("local.Mac-TaskManager.FanHelper") || serviceLabel.hasPrefix("local.Mac-TaskManager.SystemHelper")
            result.append(StartupItem(id: "btm:\(record.uid):\(identifier)", name: fields["Name"] ?? identifier,
                publisher: developer ?? "—", path: path, enabled: enabled,
                source: mainApp ? "macOS 登录应用" : "macOS 后台项目（\(type.components(separatedBy: " (")[0])）",
                requiresSettings: !ownHelper, protectionReason: ownHelper ? "请在设置中管理本软件的控制助手。" : flags.contains("disallowed") ? "需要在 macOS 登录项设置中允许。" : nil,
                backgroundIdentifier: serviceLabel))
        }
        return Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).map(\.value)
    }

    public static func legacyLoginItems() throws -> [StartupItem] {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue(),
              let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] else {
            throw ManagementFailure("无法读取传统登录项。")
        }
        var items: [StartupItem] = []
        for item in snapshot {
            guard let url = LSSharedFileListItemCopyResolvedURL(item, UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes), nil)?.takeRetainedValue() as URL? else { continue }
            items.append(StartupItem(id: "login:\(url.path)", name: applicationName(url.path) ?? url.deletingPathExtension().lastPathComponent,
                publisher: publisher(url.path), path: url.path, enabled: true, source: "登录时打开", legacyURL: url))
        }
        let disabled = preferences.stringArray(forKey: disabledLoginKey) ?? []
        let live = Set(items.map(\.id))
        for path in disabled where !live.contains("login:\(path)") {
            let url = URL(fileURLWithPath: path)
            items.append(StartupItem(id: "login:\(path)", name: applicationName(path) ?? url.deletingPathExtension().lastPathComponent,
                publisher: publisher(path), path: path, enabled: false, source: "登录时打开（由本软件禁用）", legacyURL: url))
        }
        return items
    }

    public static func setLegacy(_ url: URL, enabled: Bool) throws {
        guard !enabled || FileManager.default.fileExists(atPath: url.path) else { throw ManagementFailure("登录项目标已不存在，请重新安装相关应用。") }
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue() else {
            throw ManagementFailure("无法访问登录项列表。")
        }
        let originalDisabled = preferences.stringArray(forKey: disabledLoginKey) ?? []
        let originalHidden = preferences.dictionary(forKey: hiddenLoginKey) as? [String: Bool] ?? [:]
        guard let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] else {
            throw ManagementFailure("无法读取登录项，未更改启动设置。")
        }
        let current = snapshot.first { item in
            (LSSharedFileListItemCopyResolvedURL(item, UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes), nil)?.takeRetainedValue() as URL?) == url
        }
        guard enabled || current != nil else { throw ManagementFailure("登录项已经移除，请刷新后重试。") }
        var hidden = originalHidden
        if let current, let value = LSSharedFileListItemCopyProperty(current, kLSSharedFileListLoginItemHidden.takeUnretainedValue())?.takeRetainedValue() as? Bool {
            hidden[url.path] = value
        }
        let properties = [kLSSharedFileListLoginItemHidden.takeUnretainedValue() as String: hidden[url.path] ?? false] as CFDictionary
        var inserted: LSSharedFileListItem?
        if enabled {
            if current == nil {
                inserted = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeUnretainedValue(), nil, nil, url as CFURL, properties, nil)
                guard inserted != nil else { throw ManagementFailure("无法启用登录项。") }
            }
        } else if let current, LSSharedFileListItemRemove(list, current) != noErr {
            throw ManagementFailure("无法禁用登录项。")
        }
        var disabled = Set(originalDisabled)
        if enabled { disabled.remove(url.path) } else { disabled.insert(url.path) }
        preferences.set(Array(disabled), forKey: disabledLoginKey)
        preferences.set(hidden, forKey: hiddenLoginKey)
        do {
            let confirmed = try legacyLoginItems().first { $0.id == "login:\(url.path)" }
            guard confirmed?.enabled == enabled else { throw ManagementFailure("系统未确认登录项状态，请在系统设置中检查。") }
        } catch {
            if let inserted { _ = LSSharedFileListItemRemove(list, inserted) }
            if !enabled { _ = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeUnretainedValue(), nil, nil, url as CFURL, properties, nil) }
            preferences.set(originalDisabled, forKey: disabledLoginKey)
            preferences.set(originalHidden, forKey: hiddenLoginKey)
            throw error
        }
    }

    public static func enclosingApplication(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        // URL parent traversal can keep growing relative '..' paths on older Foundation versions.
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else { components.append(part) }
        }
        guard let index = components.lastIndex(where: { $0.hasSuffix(".app") && $0 != ".app" }) else { return nil }
        return URL(fileURLWithPath: "/" + components[...index].joined(separator: "/"))
    }

    public static func applicationName(_ path: String?) -> String? {
        guard let app = enclosingApplication(path), let bundle = Bundle(url: app) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? app.deletingPathExtension().lastPathComponent
    }

    private static var publisherCache: [String: String] = [:]
    private static let publisherLock = NSLock()
    public static func publisher(_ path: String?) -> String {
        guard let path else { return "—" }
        let url = enclosingApplication(path) ?? URL(fileURLWithPath: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path):\(modified)"
        publisherLock.lock()
        let cached = publisherCache[key]
        publisherLock.unlock()
        if let cached { return cached }
        var code: SecStaticCode?
        var info: CFDictionary?
        var result = "—"
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first {
            result = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "—"
        }
        publisherLock.lock(); publisherCache[key] = result; publisherLock.unlock()
        return result
    }
}
