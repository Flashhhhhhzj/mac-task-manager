import AppKit
import Darwin

final class ProcessMetadataCollector {
    private var cache: [ProcessIdentity: ProcessMetadata] = [:]
    private let appleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    func read(pid: Int32, uid: UInt32, state: String, cpuNanoseconds: UInt64?, app: NSRunningApplication?) -> ProcessMetadata {
        let identity = ProcessIdentity.read(pid)
        var metadata = identity.flatMap { cache[$0] } ?? ProcessMetadata()
        if metadata.identity == nil {
            metadata.identity = identity
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { metadata.executablePath = String(cString: path) }
            // Older SDKs omit PROC_PIDARCHINFO (19); its ABI is two 32-bit CPU fields.
            var architecture: [Int32] = [0, 0]
            let architectureSize = architecture.count * MemoryLayout<Int32>.stride
            let architectureBytes = architecture.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, 19, 0, buffer.baseAddress, Int32(buffer.count))
            }
            if architectureBytes == architectureSize {
                switch architecture[0] {
                case CPU_TYPE_ARM64: metadata.architecture = "ARM64"
                case CPU_TYPE_X86_64:
                    metadata.architecture = appleSilicon ? "x86_64（Rosetta）" : "x86_64"
                default: metadata.architecture = "—"
                }
            }
        }
        metadata.uid = uid
        metadata.bundlePath = app?.bundleURL?.path ?? metadata.bundlePath
        metadata.bundleIdentifier = app?.bundleIdentifier ?? metadata.bundleIdentifier
        switch state.first {
        case "R": metadata.state = "正在运行"
        case "S", "I", "U": metadata.state = "睡眠"
        case "T": metadata.state = "已停止"
        case "Z": metadata.state = "僵尸"
        default: metadata.state = "未知"
        }
        metadata.cpuNanoseconds = cpuNanoseconds
        if let identity { cache[identity] = metadata }
        return metadata
    }

    func retain(_ processes: [AppProcess]) {
        let live = Set(processes.compactMap(\.metadata.identity))
        cache = cache.filter { live.contains($0.key) }
    }
}
