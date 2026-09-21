import Foundation

public protocol DiskSpaceProviding: Sendable {
    /// Bytes available for new data on the volume that holds `url` (the URL, or its nearest existing parent).
    func availableBytes(at url: URL) throws -> Int64
}

public struct SystemDiskSpaceProvider: DiskSpaceProviding {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        // "Important usage" counts space macOS can reclaim (purgeable caches), like Finder does, so it is
        // the larger figure on the startup volume. Some volumes (a mounted disk image, some external
        // drives) report 0 for it while plainly having space, so the plain figure is a floor.
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return max(0, values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
    }
}
