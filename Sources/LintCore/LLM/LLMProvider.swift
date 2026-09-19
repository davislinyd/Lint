import Foundation

public protocol LLMProvider: Sendable {
    var id: ProviderKind { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
