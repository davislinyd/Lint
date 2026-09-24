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
    /// How the model picker describes its memory use. Not a claim about quality.
    public var memoryClass: ModelMemoryClass
    /// The arguments this model needs from llama-server on top of the shared ones.
    public var runtimeProfile: ModelRuntimeProfile
    /// What llama-server's `-hf` would be given for the same model. Used to recognise the
    /// pre-existing default setting, and the copy in the Hugging Face cache.
    public var huggingFaceSpec: String

    public init(
        id: String, displayName: String, repository: String, revision: String, quantization: String,
        license: String, files: [ModelFile], recommended: Bool,
        memoryClass: ModelMemoryClass = .balanced,
        runtimeProfile: ModelRuntimeProfile = ModelRuntimeProfile(), huggingFaceSpec: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.quantization = quantization
        self.license = license
        self.files = files
        self.recommended = recommended
        self.memoryClass = memoryClass
        self.runtimeProfile = runtimeProfile
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
    /// Gemma 4 E4B, Google's quantization-aware-trained Q4_0: one 5.2 GB file, and what new installs
    /// get. Only the language model is downloaded, not the repository's vision projector (mmproj).
    /// Like the rest of Gemma 4 it thinks before answering unless started with `--reasoning off`.
    /// Size and SHA-256 are the `lfs` values from
    /// https://huggingface.co/api/models/google/gemma-4-E4B-it-qat-q4_0-gguf?blobs=true at the pinned
    /// revision, and were checked against a downloaded copy.
    public static let gemma4_e4bQATQ4_0: ModelDescriptor = {
        let repository = "google/gemma-4-E4B-it-qat-q4_0-gguf"
        let revision = "4b4a2c1d584be7264f87aac328a1bc739ce81b6c"
        let fileName = "gemma-4-E4B_q4_0-it.gguf"
        return ModelDescriptor(
            id: "gemma-4-e4b-it-qat-q4_0",
            displayName: "Gemma 4 E4B",
            repository: repository,
            revision: revision,
            quantization: "Q4_0 (QAT)",
            license: "Apache-2.0",
            files: [
                ModelFile(
                    fileName: fileName,
                    url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!,
                    sizeBytes: 5_154_941_280,
                    sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee"
                ),
            ],
            recommended: true,
            memoryClass: .balanced,
            runtimeProfile: ModelRuntimeProfile(reasoningArguments: ["--reasoning", "off"]),
            huggingFaceSpec: "google/gemma-4-E4B-it-qat-q4_0-gguf"
        )
    }()

    /// Qwen3-4B-Instruct-2507 at Q4_K_M: one 2.5 GB file, optional. A non-thinking instruct model, so
    /// it needs no `--reasoning` switch. Qwen publishes no GGUF of it; this is unsloth's conversion
    /// (its card declares the base model and Apache-2.0). Size and SHA-256 are the `lfs.oid` from
    /// https://huggingface.co/api/models/unsloth/Qwen3-4B-Instruct-2507-GGUF/paths-info/<revision>.
    public static let qwen3_4bInstruct2507Q4_K_M: ModelDescriptor = {
        let repository = "unsloth/Qwen3-4B-Instruct-2507-GGUF"
        let revision = "a06e946bb6b655725eafa393f4a9745d460374c9"
        let fileName = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        return ModelDescriptor(
            id: "qwen3-4b-instruct-2507-q4_k_m",
            displayName: "Qwen3 4B",
            repository: repository,
            revision: revision,
            quantization: "Q4_K_M",
            license: "Apache-2.0",
            files: [
                ModelFile(
                    fileName: fileName,
                    url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!,
                    sizeBytes: 2_497_281_120,
                    sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
                ),
            ],
            recommended: false,
            memoryClass: .balanced,
            runtimeProfile: ModelRuntimeProfile(reasoningArguments: []),
            huggingFaceSpec: "unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M"
        )
    }()

    /// Gemma 4 12B, Google's quantization-aware-trained Q4_0: one 7 GB file. Optional, and marked
    /// large: on a 16 GB Mac that is already swapping, loading it has taken free memory down to 6%.
    /// It was the default before Gemma 4 E4B, and whoever has it installed keeps it. It thinks before
    /// answering unless started with `--reasoning off`. Size and SHA-256 are from
    /// https://huggingface.co/api/models/google/gemma-4-12B-it-qat-q4_0-gguf at the pinned revision.
    public static let gemma4_12bQATQ4_0: ModelDescriptor = {
        let repository = "google/gemma-4-12B-it-qat-q4_0-gguf"
        let revision = "29d097773436b69ff9feafd636ab4cf873786537"
        let fileName = "gemma-4-12b-it-qat-q4_0.gguf"
        return ModelDescriptor(
            id: "gemma-4-12b-it-qat-q4_0",
            displayName: "Gemma 4 12B",
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
            recommended: false,
            memoryClass: .large,
            runtimeProfile: ModelRuntimeProfile(reasoningArguments: ["--reasoning", "off"]),
            huggingFaceSpec: "google/gemma-4-12B-it-qat-q4_0-gguf"
        )
    }()

    /// Recommended first: this is the order the model picker shows.
    public static let all: [ModelDescriptor] = [gemma4_e4bQATQ4_0, qwen3_4bInstruct2507Q4_K_M, gemma4_12bQATQ4_0]

    public static var recommended: ModelDescriptor {
        all.first(where: \.recommended) ?? all[0]
    }

    public static func descriptor(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// The managed model a stored setting selects. A model that is still in the catalog stays
    /// selected; a missing or unrecognised setting (for example one written by a build with other
    /// models) falls back to the recommended one.
    public static func resolveManagedModelID(_ stored: String?) -> String {
        let id = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return descriptor(id: id) == nil ? recommended.id : id
    }

    /// The catalog entry a `-hf user/model:quant` setting refers to, if any.
    public static func descriptor(matchingHuggingFaceSpec spec: String) -> ModelDescriptor? {
        let wanted = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.huggingFaceSpec.lowercased() == wanted }
    }
}
