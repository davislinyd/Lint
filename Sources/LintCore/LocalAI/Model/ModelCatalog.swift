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
    /// Qwen2.5 7B Instruct, Q4_K_M: the model Lint has always defaulted to, now installed by Lint
    /// instead of by llama-server's `-hf`. Two shards; sizes and hashes from
    /// https://huggingface.co/api/models/Qwen/Qwen2.5-7B-Instruct-GGUF/tree/main at the pinned
    /// revision, which also matches the blobs of an existing `-hf` cache.
    public static let qwen25_7bInstructQ4KM: ModelDescriptor = {
        let repository = "Qwen/Qwen2.5-7B-Instruct-GGUF"
        let revision = "bb5d59e06d9551d752d08b292a50eb208b07ab1f"
        func file(_ name: String, size: Int64, sha256: String) -> ModelFile {
            ModelFile(
                fileName: name,
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!,
                sizeBytes: size,
                sha256: sha256
            )
        }
        return ModelDescriptor(
            id: "qwen2.5-7b-instruct-q4_k_m",
            displayName: "Qwen2.5 7B Instruct (Q4_K_M)",
            repository: repository,
            revision: revision,
            quantization: "Q4_K_M",
            license: "Apache-2.0",
            files: [
                file(
                    "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf", size: 3_993_201_344,
                    sha256: "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"
                ),
                file(
                    "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf", size: 689_872_288,
                    sha256: "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a"
                ),
            ],
            recommended: true,
            huggingFaceSpec: "Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m"
        )
    }()

    public static let all: [ModelDescriptor] = [qwen25_7bInstructQ4KM]

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
