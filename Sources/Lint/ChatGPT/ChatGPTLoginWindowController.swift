import AppKit
import LintCore
import WebKit

@MainActor
final class ChatGPTLoginWindowController: NSWindowController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var onFinished: ((Result<Void, Error>) -> Void)?
    private var isCapturing = false
    private var statusLabel: NSTextField!

    convenience init(onFinished: @escaping (Result<Void, Error>) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "登入 ChatGPT（非官方）"
        window.center()
        self.init(window: window)
        self.onFinished = onFinished
        setup()
    }

    private func setup() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.webView = webView

        let header = NSTextField(wrappingLabelWithString: "請登入你的 ChatGPT Plus／Pro 帳戶。看到聊天畫面後，若沒有自動關閉，按下方「完成登入」。此為非官方 session。")
        header.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "等待登入…")
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = status

        let finishButton = NSButton(title: "完成登入", target: self, action: #selector(finishLoginClicked))
        finishButton.bezelStyle = .rounded
        finishButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [finishButton, cancelButton, status])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(webView)
        container.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            webView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            buttonRow.heightAnchor.constraint(equalToConstant: 28)
        ])
        window?.contentView = container

        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/auth/login")!))
        startPolling()
    }

    @objc private func finishLoginClicked() {
        statusLabel.stringValue = "正在讀取 session…"
        Task { await captureSession(force: true) }
    }

    @objc private func cancelClicked() {
        finish(.failure(CancellationError()))
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Timer must be on common run loop mode so it fires while user interacts with WebView.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.captureSession(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func captureSession(force: Bool) async {
        guard let webView, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        // callAsyncJavaScript treats the string as the BODY of an async function.
        // Do not wrap in an IIFE — that returns an unawaited Promise and Swift gets nil.
        let js = """
        const urls = [
          '/api/auth/session',
          'https://chatgpt.com/api/auth/session',
          '/api/auth/session'
        ];
        for (const url of urls) {
          try {
            const res = await fetch(url, { credentials: 'include', cache: 'no-store' });
            if (!res.ok) continue;
            const data = await res.json();
            if (data && (data.accessToken || data.access_token)) {
              return {
                accessToken: data.accessToken || data.access_token,
                email: (data.user && (data.user.email || data.user.name)) || data.email || null,
                source: url
              };
            }
          } catch (e) {}
        }
        return null;
        """

        var payload: [String: Any]?
        do {
            if let result = try await webView.callAsyncJavaScript(
                js,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? [String: Any] {
                payload = result
            }
        } catch {
            if force {
                statusLabel.stringValue = "讀取失敗：\(error.localizedDescription)"
            }
        }

        // Fallback: classic evaluateJavaScript returning a JSON string.
        if payload == nil {
            let legacy = """
            fetch('/api/auth/session', { credentials: 'include', cache: 'no-store' })
              .then(r => r.ok ? r.json() : null)
              .then(data => {
                if (!data) return null;
                const token = data.accessToken || data.access_token;
                if (!token) return null;
                return JSON.stringify({
                  accessToken: token,
                  email: (data.user && (data.user.email || data.user.name)) || data.email || null
                });
              })
              .catch(() => null);
            """
            if let raw = try? await webView.evaluateJavaScript(legacy) as? String,
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload = obj
            }
        }

        guard let dict = payload,
              let token = dict["accessToken"] as? String,
              !token.isEmpty
        else {
            if force {
                statusLabel.stringValue = "還抓不到 token。請確認已看到 ChatGPT 聊天畫面後再按一次。"
            }
            return
        }

        let email = dict["email"] as? String
        do {
            try ChatGPTSessionStore.shared.save(accessToken: token, email: email)
            statusLabel.stringValue = "已儲存 session"
            finish(.success(()))
        } catch {
            statusLabel.stringValue = error.localizedDescription
            if force {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        pollTimer?.invalidate()
        pollTimer = nil
        onFinished?(result)
        onFinished = nil
        close()
    }

    override func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        super.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.stringValue = webView.url?.host.map { "頁面：\($0)" } ?? "等待登入…"
        Task { await captureSession(force: false) }
    }
}
