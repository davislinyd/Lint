import Foundation

/// One file of a model. Large GGUF models are often split into shards; llama-server loads the
/// first shard and finds the others next to it.
public struct ModelFile: Equatable, Sendable {
    public var fileName: String
    public var url: URL
    /// Expected size where known. Used for the disk-space check and to reject a truncated file.
    public var sizeBytes: Int64?
    /// Lowercase hex SHA-256 where known. A file with a hash is never installed unless it matches.
    public var sha256: String?

    public init(fileName: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil) {
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// A plain file name, never a path: it is joined onto Lint's own directories.
    public var hasSafeFileName: Bool {
        !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/") && !fileName.contains("\0")
    }
}

/// A model Lint can download and manage itself. Everything here was read from the Hugging Face
/// repository's API (sizes and LFS SHA-256) and is pinned to one commit; none of it is guessed.
public struct ModelDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var repository: String
    /// The repository commit the URLs and hashes were taken from.
    public var revision: String
    public var quantization: String
    public var license: String
    /// In load order: `-m` gets the first one.
    public var files: [ModelFile]
    public var recommended: Bool
    /// What llama-server's `-hf` would be given for the same model. Used to recognise the
    /// pre-existing default setting, and the copy in the Hugging Face cache.
    public var huggingFaceSpec: String

    public init(
        id: String, displayName: String, repository: String, revision: String, quantization: String,
        license: String, files: [ModelFile], recommended: Bool, huggingFaceSpec: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.quantization = quantization
        self.license = license
        self.files = files
        self.recommended = recommended
        self.huggingFaceSpec = huggingFaceSpec
    }

    public var primaryFile: ModelFile { files[0] }

    /// The total download size, when every file's size is known.
    public var totalBytes: Int64? {
        var total: Int64 = 0
        for file in files {
            guard let size = file.sizeBytes else { return nil }
            total += size
        }
        return total
    }
}

public enum ModelCatalog {
    /// Gemma 4 12B, Google's quantization-aware-trained Q4_0: one 7 GB file, small enough for a 16 GB
    /// Mac. It thinks before answering unless started with `--reasoning off`, which Lint's default
    /// server arguments do. Size and SHA-256 are from
    /// https://huggingface.co/api/models/google/gemma-4-12B-it-qat-q4_0-gguf at the pinned revision.
    public static let gemma4_12bQATQ4_0: ModelDescriptor = {
        let repository = "google/gemma-4-12B-it-qat-q4_0-gguf"
        let revision = "29d097773436b69ff9feafd636ab4cf873786537"
        let fileName = "gemma-4-12b-it-qat-q4_0.gguf"
        return ModelDescriptor(
            id: "gemma-4-12b-it-qat-q4_0",
            displayName: "Gemma 4 12B (QAT Q4_0)",
            repository: repository,
            revision: revision,
            quantization: "Q4_0 (QAT)",
            license: "Apache-2.0",
            files: [
                ModelFile(
                    fileName: fileName,
                    url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!,
                    sizeBytes: 6_975_879_296,
                    sha256: "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b"
                ),
            ],
            recommended: true,
            huggingFaceSpec: "google/gemma-4-12B-it-qat-q4_0-gguf"
        )
    }()

    public static let all: [ModelDescriptor] = [gemma4_12bQATQ4_0]

    public static var recommended: ModelDescriptor {
        all.first(where: \.recommended) ?? all[0]
    }

    public static func descriptor(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// The catalog entry a `-hf user/model:quant` setting refers to, if any.
    public static func descriptor(matchingHuggingFaceSpec spec: String) -> ModelDescriptor? {
        let wanted = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.huggingFaceSpec.lowercased() == wanted }
    }
}
