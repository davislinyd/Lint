import AppKit
import Foundation
import LintCore
import WebKit

/// Hidden WKWebView sharing the login data store so ChatGPT sees browser cookies/TLS.
@MainActor
final class ChatGPTWebBridge: NSObject, ChatGPTBrowserBackend, WKNavigationDelegate {
    static let shared = ChatGPTWebBridge()

    private let webView: WKWebView
    private var hostWindow: NSWindow?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var isReady = false

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.webView = wv
        super.init()
        wv.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = wv
        window.orderBack(nil)
        self.hostWindow = window
    }

    func warmUp() {
        Task { try? await ensureReady() }
    }

    private func ensureReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
            if readyContinuations.count == 1 {
                webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                guard !isReady else { return }
                isReady = true
                let waiting = readyContinuations
                readyContinuations.removeAll()
                waiting.forEach { $0.resume() }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        let waiting = readyContinuations
        readyContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failReady(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failReady(error)
    }

    private func failReady(_ error: Error) {
        let waiting = readyContinuations
        readyContinuations.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
    }

    func complete(_ request: ChatGPTCompletionRequest) async throws -> String {
        try await ensureReady()

        let prompt: String
        if request.systemPrompt.isEmpty {
            prompt = request.userText
        } else {
            prompt = "\(request.systemPrompt)\n\n---\n\n\(request.userText)"
        }

        // Argument names become JS locals — never redeclare them with const/let of the same name.
        let args: [String: Any] = [
            "argToken": request.accessToken,
            "argModel": request.model,
            "argPrompt": prompt,
            "argEffort": request.reasoningEffort?.rawValue ?? "low",
            "argFast": request.fastMode
        ]

        // Raw string: keep JS escapes like \\n intact (plain """ would turn \\n into a real newline).
        let js = #"""
        try {
          function deviceId() {
            const key = 'oai-did';
            let id = localStorage.getItem(key);
            if (!id) {
              id = crypto.randomUUID();
              localStorage.setItem(key, id);
            }
            return id;
          }

          function softProof(seed) {
            const payload = [Date.now(), navigator.userAgent, seed || '0', Math.random()];
            return 'gAAAAAC' + btoa(unescape(encodeURIComponent(JSON.stringify(payload))));
          }

          const did = deviceId();

          const reqRes = await fetch('https://chatgpt.com/backend-api/sentinel/chat-requirements', {
            method: 'POST',
            credentials: 'include',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + argToken,
              'oai-device-id': did,
              'Referer': 'https://chatgpt.com/',
              'Origin': 'https://chatgpt.com'
            },
            body: JSON.stringify({ p: softProof('bootstrap') })
          });
          const reqText = await reqRes.text();
          if (!reqRes.ok) {
            return { ok: false, status: reqRes.status, body: reqText.slice(0, 1800) };
          }
          let reqJson = {};
          try { reqJson = JSON.parse(reqText); } catch (e) {
            return { ok: false, status: reqRes.status, body: reqText.slice(0, 1800) };
          }
          const reqToken = reqJson.token || '';
          const pow = reqJson.proofofwork || {};
          const proof = softProof(pow.seed || '0');

          const body = {
            action: 'next',
            messages: [{
              id: crypto.randomUUID(),
              author: { role: 'user' },
              create_time: Date.now() / 1000,
              content: { content_type: 'text', parts: [argPrompt] },
              metadata: {}
            }],
            parent_message_id: crypto.randomUUID(),
            model: argModel,
            timezone_offset_min: new Date().getTimezoneOffset(),
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            history_and_training_disabled: true,
            conversation_mode: { kind: 'primary_assistant' },
            websocket_request_id: crypto.randomUUID(),
            reasoning_effort: argEffort
          };
          if (argFast) body.service_tier = 'fast';

          const headers = {
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            'Authorization': 'Bearer ' + argToken,
            'oai-device-id': did,
            'Referer': 'https://chatgpt.com/',
            'Origin': 'https://chatgpt.com'
          };
          if (reqToken) headers['openai-sentinel-chat-requirements-token'] = reqToken;
          if (proof) headers['openai-sentinel-proof-token'] = proof;

          const res = await fetch('https://chatgpt.com/backend-api/conversation', {
            method: 'POST',
            credentials: 'include',
            headers: headers,
            body: JSON.stringify(body)
          });
          const text = await res.text();
          if (!res.ok) {
            return { ok: false, status: res.status, body: text.slice(0, 2000) };
          }

          let assembled = '';
          for (const line of text.split('\n')) {
            if (!line.startsWith('data:')) continue;
            const payload = line.slice(5).trim();
            if (!payload || payload === '[DONE]') continue;
            let obj;
            try { obj = JSON.parse(payload); } catch (e) { continue; }
            const parts = obj.message && obj.message.content && obj.message.content.parts;
            if (Array.isArray(parts) && typeof parts[0] === 'string') {
              assembled = parts[0];
            }
            if (Array.isArray(obj.v)) {
              for (const op of obj.v) {
                if (op.p === '/message/content/parts/0' && op.o === 'append' && typeof op.v === 'string') {
                  assembled += op.v;
                }
              }
            } else if (obj.o === 'append' && obj.p === '/message/content/parts/0' && typeof obj.v === 'string') {
              assembled += obj.v;
            }
          }
          assembled = (assembled || '').trim();
          if (!assembled) {
            return { ok: false, status: 200, body: text.slice(0, 2000) };
          }
          return { ok: true, text: assembled };
        } catch (e) {
          return { ok: false, status: 0, body: String((e && e.message) || e) };
        }
        """#

        let result: [String: Any]
        do {
            guard let value = try await webView.callAsyncJavaScript(
                js,
                arguments: args,
                in: nil,
                contentWorld: .page
            ) as? [String: Any] else {
                throw LLMError.decoding
            }
            result = value
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            throw LLMError.httpStatus(0, String(localized: "JavaScript：\(message)"))
        }

        if (result["ok"] as? Bool) == true,
           let text = result["text"] as? String,
           !text.isEmpty {
            return text
        }

        let status = result["status"] as? Int ?? 500
        let body = (result["body"] as? String) ?? String(localized: "ChatGPT WebView 請求失敗")
        if status == 403 || body.localizedCaseInsensitiveContains("unusual activity") {
            throw LLMError.httpStatus(
                403,
                String(localized: "ChatGPT 判定異常流量（403）。請稍後重試、重新登入，或改用官方 API Key。")
            )
        }
        throw LLMError.httpStatus(status == 0 ? 500 : status, String(body.prefix(800)))
    }
}
