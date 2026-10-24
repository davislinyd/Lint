import Foundation

/// The environment llama-server is started with: Lint's own, minus anything that sets one of its
/// options. llama-server reads `LLAMA_ARG_*` for every option and `LLAMA_API_KEY` as a second key,
/// so a variable left in Lint's environment could open the server, bind it elsewhere or turn on
/// its tools. The arguments Lint passes, and the advanced field, are the only way to set options.
public enum LlamaServerEnvironment {
    public static func make(inherited: [String: String]) -> [String: String] {
        inherited.filter { name, _ in name != "LLAMA_API_KEY" && !name.hasPrefix("LLAMA_ARG_") }
    }
}
