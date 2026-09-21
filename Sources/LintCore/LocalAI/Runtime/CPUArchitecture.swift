import Foundation

/// The CPU architectures a bundled llama.cpp runtime can be built for. Lint's own executable and
/// the runtime inside it must always agree, so this is what selects `LlamaRuntime/<arch>/`.
public enum CPUArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64

    /// The architecture this process was compiled for.
    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// Reads the CPU types out of a Mach-O header without running or loading the file.
public enum MachOInspector {
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007

    /// The supported architectures in the Mach-O (thin or fat) file at `url`; `nil` if the file is
    /// missing, unreadable or not a Mach-O file. Other CPU types are ignored, so a 32-bit-only file
    /// yields an empty array.
    public static func architectures(of url: URL) -> [CPUArchitecture]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return nil }
        let bytes = [UInt8](header)

        func be32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func architecture(forCPUType cpuType: UInt32) -> CPUArchitecture? {
            switch cpuType {
            case cpuTypeARM64: return .arm64
            case cpuTypeX86_64: return .x86_64
            default: return nil
            }
        }

        // Thin 64-bit Mach-O: MH_MAGIC_64, little-endian on every supported Mac.
        if le32(0) == 0xFEED_FACF, let cpuType = le32(4) {
            return architecture(forCPUType: cpuType).map { [$0] } ?? []
        }
        // Fat: FAT_MAGIC / FAT_MAGIC_64, big-endian. Java class files share 0xCAFEBABE, so a
        // sane architecture count is required as well.
        if let magic = be32(0), magic == 0xCAFE_BABE || magic == 0xCAFE_BABF,
           let count = be32(4), count > 0, count <= 16 {
            let entrySize = magic == 0xCAFE_BABE ? 20 : 32
            var found: [CPUArchitecture] = []
            for index in 0..<Int(count) {
                guard let cpuType = be32(8 + index * entrySize) else { return nil }
                if let arch = architecture(forCPUType: cpuType), !found.contains(arch) { found.append(arch) }
            }
            return found
        }
        return nil
    }
}
