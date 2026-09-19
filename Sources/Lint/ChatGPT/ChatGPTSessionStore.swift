import Foundation
import LintCore
import Observation

@MainActor
@Observable
final class ChatGPTSessionStore {
    static let shared = ChatGPTSessionStore()

    private enum DefaultsKey {
        static let email = "app.lint.chatgpt.email"
    }

    private let keychain = KeychainStore()
    private let account = ProviderKind.chatgptAccount.keychainAccount

    var email: String = UserDefaults.standard.string(forKey: DefaultsKey.email) ?? ""
    var isLoggedIn: Bool = false
    var statusText: String = String(localized: "未登入")

    private init() {
        refresh()
    }

    func refresh() {
        let token = (try? keychain.get(account: account)) ?? ""
        isLoggedIn = !token.isEmpty
        if isLoggedIn {
            statusText = email.isEmpty ? String(localized: "已登入") : String(localized: "已登入：\(email)")
        } else {
            statusText = String(localized: "未登入")
        }
    }

    func accessToken() throws -> String {
        let token = (try keychain.get(account: account)) ?? ""
        if token.isEmpty { throw LLMError.notLoggedInToChatGPT }
        return token
    }

    func save(accessToken: String, email: String?) throws {
        try keychain.set(accessToken, account: account)
        if let email, !email.isEmpty {
            self.email = email
            UserDefaults.standard.set(email, forKey: DefaultsKey.email)
        }
        refresh()
    }

    func logout() throws {
        try keychain.delete(account: account)
        email = ""
        UserDefaults.standard.removeObject(forKey: DefaultsKey.email)
        refresh()
    }
}
