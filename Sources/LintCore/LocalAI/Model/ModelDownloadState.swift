import Foundation

public enum ModelDownloadState: Equatable, Sendable {
    case idle
    /// Looking at disk space and at what a previous attempt left behind.
    case checking
    /// `totalBytes` is nil when no size is known; the UI then shows an indeterminate bar.
    case downloading(bytesReceived: Int64, totalBytes: Int64?)
    case verifying
    case installing
    case installed
    case failed(ModelInstallError)
    /// The partial download is kept, so the next attempt resumes.
    case cancelled

    public var isActive: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing: true
        case .idle, .installed, .failed, .cancelled: false
        }
    }
}

public enum ModelInstallError: Error, Equatable, Sendable, LocalizedError {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case network(String)
    case httpStatus(Int)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case checksumMismatch(file: String)
    case notAGGUFFile(file: String)
    case unsafeFileName(String)
    case filesystem(String)

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }

    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let need = Self.formatBytes(required)
            let have = Self.formatBytes(available)
            return String(localized: "此模型約需要 \(need) 的可用空間，這台 Mac 目前只有 \(have) 可用。請先釋出空間再試一次。")
        case .network(let message):
            return String(localized: "下載時發生網路問題：\(message)。已下載的部分會保留，重試會從中斷處繼續。")
        case .httpStatus(let code):
            return String(localized: "模型伺服器回應了錯誤（HTTP \(code)）。請稍後重試。")
        case .sizeMismatch, .checksumMismatch, .notAGGUFFile:
            return String(localized: "下載的模型檔案沒有通過驗證，已被刪除，不會被使用。請重試。")
        case .unsafeFileName:
            return String(localized: "模型設定不正確，無法安裝。")
        case .filesystem(let message):
            return String(localized: "無法寫入模型檔案：\(message)")
        }
    }
}
