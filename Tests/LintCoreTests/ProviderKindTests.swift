import XCTest
@testable import LintCore

final class ProviderKindTests: XCTestCase {
    func testLocalLlamaNeedsNoAPIKey() throws {
        XCTAssertFalse(ProviderKind.localLlama.requiresAPIKey)
        let config = LLMRuntimeConfig(
            kind: .localLlama,
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            model: ProviderKind.localLlama.defaultModel,
            apiKey: ""
        )
        XCTAssertEqual(try LLMService().provider(for: config).id, .localLlama)
    }

    func testChatGPTWebRequestsStayOff() {
        XCTAssertFalse(ProviderKind.chatgptAccount.isEnabled)
        XCTAssertFalse(ChatGPTWebAccess.requestsAllowed)
    }
}
