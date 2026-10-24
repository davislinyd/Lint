import XCTest

@testable import LintCore

final class LlamaServerEnvironmentTests: XCTestCase {
    func testNothingInLintsEnvironmentCanSetLlamaServersOptions() {
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/alice",
            "LLAMA_API_KEY": "another key",
            "LLAMA_ARG_API_KEY_FILE": "/tmp/keys",
            "LLAMA_ARG_HOST": "0.0.0.0",
            "LLAMA_ARG_CORS_ORIGINS": "*",
            "LLAMA_ARG_TOOLS": "all",
            "LLAMA_ARG_N_PARALLEL": "4",
            "LLAMA_CACHE": "/Users/alice/Library/Caches/llama.cpp",
        ]
        let environment = LlamaServerEnvironment.make(inherited: inherited)
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["HOME"], "/Users/alice")
        XCTAssertEqual(environment["LLAMA_CACHE"], "/Users/alice/Library/Caches/llama.cpp", "where -hf models are cached stays")
        XCTAssertNil(environment["LLAMA_API_KEY"], "a second key would open the server")
        XCTAssertTrue(environment.keys.filter { $0.hasPrefix("LLAMA_ARG_") }.isEmpty, "\(environment.keys.sorted())")
    }
}
