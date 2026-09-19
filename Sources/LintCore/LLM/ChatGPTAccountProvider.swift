import Foundation
import JavaScriptCore

/// Unofficial ChatGPT website backend (Plus/Pro access token from in-app login).
public struct ChatGPTAccountProvider: LLMProvider {
    public let id: ProviderKind = .chatgptAccount
    public let accessToken: String
    public let model: String
    private let session: URLSession

    public init(accessToken: String, model: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.model = model.isEmpty ? "auto" : model
        self.session = session
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let answer: String
                    if let backend = ChatGPTBrowserBackendRegistry.shared.backend {
                        answer = try await backend.complete(
                            ChatGPTCompletionRequest(
                                accessToken: accessToken,
                                model: model,
                                systemPrompt: request.systemPrompt,
                                userText: request.userText,
                                reasoningEffort: request.reasoningEffort,
                                fastMode: request.fastMode
                            )
                        )
                    } else {
                        answer = try await Self.generate(
                            token: accessToken,
                            model: model,
                            systemPrompt: request.systemPrompt,
                            userText: request.userText,
                            reasoningEffort: request.reasoningEffort,
                            fastMode: request.fastMode,
                            session: session
                        )
                    }
                    continuation.yield(.text(answer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func generate(
        token: String,
        model: String,
        systemPrompt: String,
        userText: String,
        reasoningEffort: ReasoningEffort?,
        fastMode: Bool,
        session: URLSession
    ) async throws -> String {
        let deviceId = persistedDeviceId()
        let requirements = try await chatRequirements(token: token, deviceId: deviceId, session: session)
        let proof: String
        if requirements.proofRequired {
            proof = try solveProof(seed: requirements.seed, difficulty: requirements.difficulty)
        } else {
            proof = try placeholderProof()
        }

        let prompt = systemPrompt.isEmpty ? userText : "\(systemPrompt)\n\n---\n\n\(userText)"
        var body: [String: Any] = [
            "action": "next",
            "messages": [[
                "id": UUID().uuidString,
                "author": ["role": "user"],
                "create_time": Date().timeIntervalSince1970,
                "content": ["content_type": "text", "parts": [prompt]],
                "metadata": [:] as [String: Any]
            ]],
            "parent_message_id": UUID().uuidString,
            "model": model,
            "timezone_offset_min": TimeZone.current.secondsFromGMT() / -60,
            "timezone": TimeZone.current.identifier,
            "history_and_training_disabled": true,
            "conversation_mode": ["kind": "primary_assistant"],
            "websocket_request_id": UUID().uuidString
        ]
        if let effort = reasoningEffort {
            body["reasoning_effort"] = effort.rawValue
        }
        if fastMode {
            // Official API uses service_tier=fast; ChatGPT web may honor the same hint.
            body["service_tier"] = "fast"
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/conversation") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "oai-device-id")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(requirements.token, forHTTPHeaderField: "openai-sentinel-chat-requirements-token")
        request.setValue(proof, forHTTPHeaderField: "openai-sentinel-proof-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var err = ""
            for try await line in bytes.lines {
                err.append(line)
                if err.count > 2500 { break }
            }
            if http.statusCode == 403, err.contains("Unusual activity") {
                throw LLMError.httpStatus(
                    403,
                    "ChatGPT 判定為異常流量（403）。請改走 App 內 WebView 連線，或稍後重試／重新登入。"
                )
            }
            throw LLMError.httpStatus(http.statusCode, err)
        }

        var assembled = ""
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [String: Any],
               let parts = content["parts"] as? [Any],
               let first = parts.first as? String {
                assembled = first
            }
            if let ops = obj["v"] as? [[String: Any]] {
                for op in ops {
                    if op["p"] as? String == "/message/content/parts/0",
                       op["o"] as? String == "append",
                       let chunk = op["v"] as? String {
                        assembled += chunk
                    }
                }
            } else if obj["o"] as? String == "append",
                      obj["p"] as? String == "/message/content/parts/0",
                      let chunk = obj["v"] as? String {
                assembled += chunk
            }
        }

        let out = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { throw LLMError.decoding }
        return out
    }

    private struct ChatRequirements {
        var token: String
        var seed: String
        var difficulty: String
        var proofRequired: Bool
    }

    private static func chatRequirements(token: String, deviceId: String, session: URLSession) async throws -> ChatRequirements {
        guard let url = URL(string: "https://chatgpt.com/backend-api/sentinel/chat-requirements") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "oai-device-id")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p": try placeholderProof()])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reqToken = json["token"] as? String
        else { throw LLMError.decoding }

        let pow = json["proofofwork"] as? [String: Any]
        let required = (pow?["required"] as? Bool) ?? false
        return ChatRequirements(
            token: reqToken,
            seed: (pow?["seed"] as? String) ?? "0",
            difficulty: (pow?["difficulty"] as? String) ?? "0",
            proofRequired: required
        )
    }

    private static func persistedDeviceId() -> String {
        let key = "app.lint.chatgpt.oaiDeviceId"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private static func placeholderProof() throws -> String {
        let payload: [Any] = [
            Int.random(in: 3000...6000),
            Date().description,
            4_294_705_152,
            0,
            "Mozilla/5.0",
            "en-US",
            "en-US",
            401,
            "mediaSession",
            "location",
            "scrollX",
            String(format: "%.4f", Double.random(in: 1000...5000)),
            UUID().uuidString,
            "",
            12,
            Int(Date().timeIntervalSince1970 * 1000)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return "gAAAAAC" + data.base64EncodedString()
    }

    private static func solveProof(seed: String, difficulty: String) throws -> String {
        guard let context = JSContext() else { throw LLMError.decoding }
        context.exceptionHandler = { _, exc in
            if let exc { print("ChatGPT PoW JS error: \(exc)") }
        }
        // js-sha3 attaches to window/global — map them onto the JSC global object.
        context.evaluateScript("var window = this; var global = this; var module = undefined;")
        let decoded = String(data: Data(base64Encoded: sha3Base64) ?? Data(), encoding: .utf8) ?? ""
        context.evaluateScript(decoded)
        context.evaluateScript("""
        function lintSolve(seed, difficulty) {
          const screens = [3000, 4000, 6000];
          const cores = [8, 12, 16, 24];
          const screen = screens[Math.floor(Math.random() * screens.length)];
          const core = cores[Math.floor(Math.random() * cores.length)];
          const now = new Date(Date.now() - 8 * 3600 * 1000);
          const parseTime = now.toUTCString().replace("GMT", "GMT+0100 (Central European Time)");
          const agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
          const config = [core + screen, parseTime, 4294705152, 0, agent];
          const diffLen = Math.floor(difficulty.length / 2);
          for (let i = 0; i < 150000; i++) {
            config[3] = i;
            const base = btoa(JSON.stringify(config));
            const digest = sha3_512(seed + base);
            if (digest.substring(0, diffLen) <= difficulty) {
              return "gAAAAAB" + base;
            }
          }
          return "gAAAAAB" + btoa('"' + seed + '"');
        }
        """)
        guard let fn = context.objectForKeyedSubscript("lintSolve"),
              let value = fn.call(withArguments: [seed, difficulty]),
              let proof = value.toString(),
              !proof.isEmpty
        else {
            throw LLMError.decoding
        }
        return proof
    }

    private static let sha3Base64 = "LyoqCiAqIFtqcy1zaGEzXXtAbGluayBodHRwczovL2dpdGh1Yi5jb20vZW1uMTc4L2pzLXNoYTN9CiAqCiAqIEB2ZXJzaW9uIDAuOS4zCiAqIEBhdXRob3IgQ2hlbiwgWWktQ3l1YW4gW2VtbjE3OEBnbWFpbC5jb21dCiAqIEBjb3B5cmlnaHQgQ2hlbiwgWWktQ3l1YW4gMjAxNS0yMDIzCiAqIEBsaWNlbnNlIE1JVAogKi8KLypqc2xpbnQgYml0d2lzZTogdHJ1ZSAqLwooZnVuY3Rpb24gKCkgewogICd1c2Ugc3RyaWN0JzsKCiAgdmFyIElOUFVUX0VSUk9SID0gJ2lucHV0IGlzIGludmFsaWQgdHlwZSc7CiAgdmFyIEZJTkFMSVpFX0VSUk9SID0gJ2ZpbmFsaXplIGFscmVhZHkgY2FsbGVkJzsKICB2YXIgV0lORE9XID0gdHlwZW9mIHdpbmRvdyA9PT0gJ29iamVjdCc7CiAgdmFyIHJvb3QgPSBXSU5ET1cgPyB3aW5kb3cgOiB7fTsKICBpZiAocm9vdC5KU19TSEEzX05PX1dJTkRPVykgewogICAgV0lORE9XID0gZmFsc2U7CiAgfQogIHZhciBXRUJfV09SS0VSID0gIVdJTkRPVyAmJiB0eXBlb2Ygc2VsZiA9PT0gJ29iamVjdCc7CiAgdmFyIE5PREVfSlMgPSAhcm9vdC5KU19TSEEzX05PX05PREVfSlMgJiYgdHlwZW9mIHByb2Nlc3MgPT09ICdvYmplY3QnICYmIHByb2Nlc3MudmVyc2lvbnMgJiYgcHJvY2Vzcy52ZXJzaW9ucy5ub2RlOwogIGlmIChOT0RFX0pTKSB7CiAgICByb290ID0gZ2xvYmFsOwogIH0gZWxzZSBpZiAoV0VCX1dPUktFUikgewogICAgcm9vdCA9IHNlbGY7CiAgfQogIHZhciBDT01NT05fSlMgPSAhcm9vdC5KU19TSEEzX05PX0NPTU1PTl9KUyAmJiB0eXBlb2YgbW9kdWxlID09PSAnb2JqZWN0JyAmJiBtb2R1bGUuZXhwb3J0czsKICB2YXIgQU1EID0gdHlwZW9mIGRlZmluZSA9PT0gJ2Z1bmN0aW9uJyAmJiBkZWZpbmUuYW1kOwogIHZhciBBUlJBWV9CVUZGRVIgPSAhcm9vdC5KU19TSEEzX05PX0FSUkFZX0JVRkZFUiAmJiB0eXBlb2YgQXJyYXlCdWZmZXIgIT09ICd1bmRlZmluZWQnOwogIHZhciBIRVhfQ0hBUlMgPSAnMDEyMzQ1Njc4OWFiY2RlZicuc3BsaXQoJycpOwogIHZhciBTSEFLRV9QQURESU5HID0gWzMxLCA3OTM2LCAyMDMxNjE2LCA1MjAwOTM2OTZdOwogIHZhciBDU0hBS0VfUEFERElORyA9IFs0LCAxMDI0LCAyNjIxNDQsIDY3MTA4ODY0XTsKICB2YXIgS0VDQ0FLX1BBRERJTkcgPSBbMSwgMjU2LCA2NTUzNiwgMTY3NzcyMTZdOwogIHZhciBQQURESU5HID0gWzYsIDE1MzYsIDM5MzIxNiwgMTAwNjYzMjk2XTsKICB2YXIgU0hJRlQgPSBbMCwgOCwgMTYsIDI0XTsKICB2YXIgUkMgPSBbMSwgMCwgMzI4OTgsIDAsIDMyOTA2LCAyMTQ3NDgzNjQ4LCAyMTQ3NTE2NDE2LCAyMTQ3NDgzNjQ4LCAzMjkwNywgMCwgMjE0NzQ4MzY0OSwKICAgIDAsIDIxNDc1MTY1NDUsIDIxNDc0ODM2NDgsIDMyNzc3LCAyMTQ3NDgzNjQ4LCAxMzgsIDAsIDEzNiwgMCwgMjE0NzUxNjQyNSwgMCwKICAgIDIxNDc0ODM2NTgsIDAsIDIxNDc1MTY1NTUsIDAsIDEzOSwgMjE0NzQ4MzY0OCwgMzI5MDUsIDIxNDc0ODM2NDgsIDMyNzcxLAogICAgMjE0NzQ4MzY0OCwgMzI3NzAsIDIxNDc0ODM2NDgsIDEyOCwgMjE0NzQ4MzY0OCwgMzI3NzgsIDAsIDIxNDc0ODM2NTgsIDIxNDc0ODM2NDgsCiAgICAyMTQ3NTE2NTQ1LCAyMTQ3NDgzNjQ4LCAzMjg5NiwgMjE0NzQ4MzY0OCwgMjE0NzQ4MzY0OSwgMCwgMjE0NzUxNjQyNCwgMjE0NzQ4MzY0OF07CiAgdmFyIEJJVFMgPSBbMjI0LCAyNTYsIDM4NCwgNTEyXTsKICB2YXIgU0hBS0VfQklUUyA9IFsxMjgsIDI1Nl07CiAgdmFyIE9VVFBVVF9UWVBFUyA9IFsnaGV4JywgJ2J1ZmZlcicsICdhcnJheUJ1ZmZlcicsICdhcnJheScsICdkaWdlc3QnXTsKICB2YXIgQ1NIQUtFX0JZVEVQQUQgPSB7CiAgICAnMTI4JzogMTY4LAogICAgJzI1Nic6IDEzNgogIH07CgoKICB2YXIgaXNBcnJheSA9IHJvb3QuSlNfU0hBM19OT19OT0RFX0pTIHx8ICFBcnJheS5pc0FycmF5CiAgICA/IGZ1bmN0aW9uIChvYmopIHsKICAgICAgICByZXR1cm4gT2JqZWN0LnByb3RvdHlwZS50b1N0cmluZy5jYWxsKG9iaikgPT09ICdbb2JqZWN0IEFycmF5XSc7CiAgICAgIH0KICAgIDogQXJyYXkuaXNBcnJheTsKCiAgdmFyIGlzVmlldyA9IChBUlJBWV9CVUZGRVIgJiYgKHJvb3QuSlNfU0hBM19OT19BUlJBWV9CVUZGRVJfSVNfVklFVyB8fCAhQXJyYXlCdWZmZXIuaXNWaWV3KSkKICAgID8gZnVuY3Rpb24gKG9iaikgewogICAgICAgIHJldHVybiB0eXBlb2Ygb2JqID09PSAnb2JqZWN0JyAmJiBvYmouYnVmZmVyICYmIG9iai5idWZmZXIuY29uc3RydWN0b3IgPT09IEFycmF5QnVmZmVyOwogICAgICB9CiAgICA6IEFycmF5QnVmZmVyLmlzVmlldzsKCiAgLy8gW21lc3NhZ2U6IHN0cmluZywgaXNTdHJpbmc6IGJvb2xdCiAgdmFyIGZvcm1hdE1lc3NhZ2UgPSBmdW5jdGlvbiAobWVzc2FnZSkgewogICAgdmFyIHR5cGUgPSB0eXBlb2YgbWVzc2FnZTsKICAgIGlmICh0eXBlID09PSAnc3RyaW5nJykgewogICAgICByZXR1cm4gW21lc3NhZ2UsIHRydWVdOwogICAgfQogICAgaWYgKHR5cGUgIT09ICdvYmplY3QnIHx8IG1lc3NhZ2UgPT09IG51bGwpIHsKICAgICAgdGhyb3cgbmV3IEVycm9yKElOUFVUX0VSUk9SKTsKICAgIH0KICAgIGlmIChBUlJBWV9CVUZGRVIgJiYgbWVzc2FnZS5jb25zdHJ1Y3RvciA9PT0gQXJyYXlCdWZmZXIpIHsKICAgICAgcmV0dXJuIFtuZXcgVWludDhBcnJheShtZXNzYWdlKSwgZmFsc2VdOwogICAgfQogICAgaWYgKCFpc0FycmF5KG1lc3NhZ2UpICYmICFpc1ZpZXcobWVzc2FnZSkpIHsKICAgICAgdGhyb3cgbmV3IEVycm9yKElOUFVUX0VSUk9SKTsKICAgIH0KICAgIHJldHVybiBbbWVzc2FnZSwgZmFsc2VdOwogIH0KCiAgdmFyIGVtcHR5ID0gZnVuY3Rpb24gKG1lc3NhZ2UpIHsKICAgIHJldHVybiBmb3JtYXRNZXNzYWdlKG1lc3NhZ2UpWzBdLmxlbmd0aCA9PT0gMDsKICB9OwoKICB2YXIgY2xvbmVBcnJheSA9IGZ1bmN0aW9uIChhcnJheSkgewogICAgdmFyIG5ld0FycmF5ID0gW107CiAgICBmb3IgKHZhciBpID0gMDsgaSA8IGFycmF5Lmxlbmd0aDsgKytpKSB7CiAgICAgIG5ld0FycmF5W2ldID0gYXJyYXlbaV07CiAgICB9CiAgICByZXR1cm4gbmV3QXJyYXk7CiAgfQoKICB2YXIgY3JlYXRlT3V0cHV0TWV0aG9kID0gZnVuY3Rpb24gKGJpdHMsIHBhZGRpbmcsIG91dHB1dFR5cGUpIHsKICAgIHJldHVybiBmdW5jdGlvbiAobWVzc2FnZSkgewogICAgICByZXR1cm4gbmV3IEtlY2NhayhiaXRzLCBwYWRkaW5nLCBiaXRzKS51cGRhdGUobWVzc2FnZSlbb3V0cHV0VHlwZV0oKTsKICAgIH07CiAgfTsKCiAgdmFyIGNyZWF0ZVNoYWtlT3V0cHV0TWV0aG9kID0gZnVuY3Rpb24gKGJpdHMsIHBhZGRpbmcsIG91dHB1dFR5cGUpIHsKICAgIHJldHVybiBmdW5jdGlvbiAobWVzc2FnZSwgb3V0cHV0Qml0cykgewogICAgICByZXR1cm4gbmV3IEtlY2NhayhiaXRzLCBwYWRkaW5nLCBvdXRwdXRCaXRzKS51cGRhdGUobWVzc2FnZSlbb3V0cHV0VHlwZV0oKTsKICAgIH07CiAgfTsKCiAgdmFyIGNyZWF0ZUNzaGFrZU91dHB1dE1ldGhvZCA9IGZ1bmN0aW9uIChiaXRzLCBwYWRkaW5nLCBvdXRwdXRUeXBlKSB7CiAgICByZXR1cm4gZnVuY3Rpb24gKG1lc3NhZ2UsIG91dHB1dEJpdHMsIG4sIHMpIHsKICAgICAgcmV0dXJuIG1ldGhvZHNbJ2NzaGFrZScgKyBiaXRzXS51cGRhdGUobWVzc2FnZSwgb3V0cHV0Qml0cywgbiwgcylbb3V0cHV0VHlwZV0oKTsKICAgIH07CiAgfTsKCiAgdmFyIGNyZWF0ZUttYWNPdXRwdXRNZXRob2QgPSBmdW5jdGlvbiAoYml0cywgcGFkZGluZywgb3V0cHV0VHlwZSkgewogICAgcmV0dXJuIGZ1bmN0aW9uIChrZXksIG1lc3NhZ2UsIG91dHB1dEJpdHMsIHMpIHsKICAgICAgcmV0dXJuIG1ldGhvZHNbJ2ttYWMnICsgYml0c10udXBkYXRlKGtleSwgbWVzc2FnZSwgb3V0cHV0Qml0cywgcylbb3V0cHV0VHlwZV0oKTsKICAgIH07CiAgfTsKCiAgdmFyIGNyZWF0ZU91dHB1dE1ldGhvZHMgPSBmdW5jdGlvbiAobWV0aG9kLCBjcmVhdGVNZXRob2QsIGJpdHMsIHBhZGRpbmcpIHsKICAgIGZvciAodmFyIGkgPSAwOyBpIDwgT1VUUFVUX1RZUEVTLmxlbmd0aDsgKytpKSB7CiAgICAgIHZhciB0eXBlID0gT1VUUFVUX1RZUEVTW2ldOwogICAgICBtZXRob2RbdHlwZV0gPSBjcmVhdGVNZXRob2QoYml0cywgcGFkZGluZywgdHlwZSk7CiAgICB9CiAgICByZXR1cm4gbWV0aG9kOwogIH07CgogIHZhciBjcmVhdGVNZXRob2QgPSBmdW5jdGlvbiAoYml0cywgcGFkZGluZykgewogICAgdmFyIG1ldGhvZCA9IGNyZWF0ZU91dHB1dE1ldGhvZChiaXRzLCBwYWRkaW5nLCAnaGV4Jyk7CiAgICBtZXRob2QuY3JlYXRlID0gZnVuY3Rpb24gKCkgewogICAgICByZXR1cm4gbmV3IEtlY2NhayhiaXRzLCBwYWRkaW5nLCBiaXRzKTsKICAgIH07CiAgICBtZXRob2QudXBkYXRlID0gZnVuY3Rpb24gKG1lc3NhZ2UpIHsKICAgICAgcmV0dXJuIG1ldGhvZC5jcmVhdGUoKS51cGRhdGUobWVzc2FnZSk7CiAgICB9OwogICAgcmV0dXJuIGNyZWF0ZU91dHB1dE1ldGhvZHMobWV0aG9kLCBjcmVhdGVPdXRwdXRNZXRob2QsIGJpdHMsIHBhZGRpbmcpOwogIH07CgogIHZhciBjcmVhdGVTaGFrZU1ldGhvZCA9IGZ1bmN0aW9uIChiaXRzLCBwYWRkaW5nKSB7CiAgICB2YXIgbWV0aG9kID0gY3JlYXRlU2hha2VPdXRwdXRNZXRob2QoYml0cywgcGFkZGluZywgJ2hleCcpOwogICAgbWV0aG9kLmNyZWF0ZSA9IGZ1bmN0aW9uIChvdXRwdXRCaXRzKSB7CiAgICAgIHJldHVybiBuZXcgS2VjY2FrKGJpdHMsIHBhZGRpbmcsIG91dHB1dEJpdHMpOwogICAgfTsKICAgIG1ldGhvZC51cGRhdGUgPSBmdW5jdGlvbiAobWVzc2FnZSwgb3V0cHV0Qml0cykgewogICAgICByZXR1cm4gbWV0aG9kLmNyZWF0ZShvdXRwdXRCaXRzKS51cGRhdGUobWVzc2FnZSk7CiAgICB9OwogICAgcmV0dXJuIGNyZWF0ZU91dHB1dE1ldGhvZHMobWV0aG9kLCBjcmVhdGVTaGFrZU91dHB1dE1ldGhvZCwgYml0cywgcGFkZGluZyk7CiAgfTsKCiAgdmFyIGNyZWF0ZUNzaGFrZU1ldGhvZCA9IGZ1bmN0aW9uIChiaXRzLCBwYWRkaW5nKSB7CiAgICB2YXIgdyA9IENTSEFLRV9CWVRFUEFEW2JpdHNdOwogICAgdmFyIG1ldGhvZCA9IGNyZWF0ZUNzaGFrZU91dHB1dE1ldGhvZChiaXRzLCBwYWRkaW5nLCAnaGV4Jyk7CiAgICBtZXRob2QuY3JlYXRlID0gZnVuY3Rpb24gKG91dHB1dEJpdHMsIG4sIHMpIHsKICAgICAgaWYgKGVtcHR5KG4pICYmIGVtcHR5KHMpKSB7CiAgICAgICAgcmV0dXJuIG1ldGhvZHNbJ3NoYWtlJyArIGJpdHNdLmNyZWF0ZShvdXRwdXRCaXRzKTsKICAgICAgfSBlbHNlIHsKICAgICAgICByZXR1cm4gbmV3IEtlY2NhayhiaXRzLCBwYWRkaW5nLCBvdXRwdXRCaXRzKS5ieXRlcGFkKFtuLCBzXSwgdyk7CiAgICAgIH0KICAgIH07CiAgICBtZXRob2QudXBkYXRlID0gZnVuY3Rpb24gKG1lc3NhZ2UsIG91dHB1dEJpdHMsIG4sIHMpIHsKICAgICAgcmV0dXJuIG1ldGhvZC5jcmVhdGUob3V0cHV0Qml0cywgbiwgcykudXBkYXRlKG1lc3NhZ2UpOwogICAgfTsKICAgIHJldHVybiBjcmVhdGVPdXRwdXRNZXRob2RzKG1ldGhvZCwgY3JlYXRlQ3NoYWtlT3V0cHV0TWV0aG9kLCBiaXRzLCBwYWRkaW5nKTsKICB9OwoKICB2YXIgY3JlYXRlS21hY01ldGhvZCA9IGZ1bmN0aW9uIChiaXRzLCBwYWRkaW5nKSB7CiAgICB2YXIgdyA9IENTSEFLRV9CWVRFUEFEW2JpdHNdOwogICAgdmFyIG1ldGhvZCA9IGNyZWF0ZUttYWNPdXRwdXRNZXRob2QoYml0cywgcGFkZGluZywgJ2hleCcpOwogICAgbWV0aG9kLmNyZWF0ZSA9IGZ1bmN0aW9uIChrZXksIG91dHB1dEJpdHMsIHMpIHsKICAgICAgcmV0dXJuIG5ldyBLbWFjKGJpdHMsIHBhZGRpbmcsIG91dHB1dEJpdHMpLmJ5dGVwYWQoWydLTUFDJywgc10sIHcpLmJ5dGVwYWQoW2tleV0sIHcpOwogICAgfTsKICAgIG1ldGhvZC51cGRhdGUgPSBmdW5jdGlvbiAoa2V5LCBtZXNzYWdlLCBvdXRwdXRCaXRzLCBzKSB7CiAgICAgIHJldHVybiBtZXRob2QuY3JlYXRlKGtleSwgb3V0cHV0Qml0cywgcykudXBkYXRlKG1lc3NhZ2UpOwogICAgfTsKICAgIHJldHVybiBjcmVhdGVPdXRwdXRNZXRob2RzKG1ldGhvZCwgY3JlYXRlS21hY091dHB1dE1ldGhvZCwgYml0cywgcGFkZGluZyk7CiAgfTsKCiAgdmFyIGFsZ29yaXRobXMgPSBbCiAgICB7IG5hbWU6ICdrZWNjYWsnLCBwYWRkaW5nOiBLRUNDQUtfUEFERElORywgYml0czogQklUUywgY3JlYXRlTWV0aG9kOiBjcmVhdGVNZXRob2QgfSwKICAgIHsgbmFtZTogJ3NoYTMnLCBwYWRkaW5nOiBQQURESU5HLCBiaXRzOiBCSVRTLCBjcmVhdGVNZXRob2Q6IGNyZWF0ZU1ldGhvZCB9LAogICAgeyBuYW1lOiAnc2hha2UnLCBwYWRkaW5nOiBTSEFLRV9QQURESU5HLCBiaXRzOiBTSEFLRV9CSVRTLCBjcmVhdGVNZXRob2Q6IGNyZWF0ZVNoYWtlTWV0aG9kIH0sCiAgICB7IG5hbWU6ICdjc2hha2UnLCBwYWRkaW5nOiBDU0hBS0VfUEFERElORywgYml0czogU0hBS0VfQklUUywgY3JlYXRlTWV0aG9kOiBjcmVhdGVDc2hha2VNZXRob2QgfSwKICAgIHsgbmFtZTogJ2ttYWMnLCBwYWRkaW5nOiBDU0hBS0VfUEFERElORywgYml0czogU0hBS0VfQklUUywgY3JlYXRlTWV0aG9kOiBjcmVhdGVLbWFjTWV0aG9kIH0KICBdOwoKICB2YXIgbWV0aG9kcyA9IHt9LCBtZXRob2ROYW1lcyA9IFtdOwoKICBmb3IgKHZhciBpID0gMDsgaSA8IGFsZ29yaXRobXMubGVuZ3RoOyArK2kpIHsKICAgIHZhciBhbGdvcml0aG0gPSBhbGdvcml0aG1zW2ldOwogICAgdmFyIGJpdHMgPSBhbGdvcml0aG0uYml0czsKICAgIGZvciAodmFyIGogPSAwOyBqIDwgYml0cy5sZW5ndGg7ICsraikgewogICAgICB2YXIgbWV0aG9kTmFtZSA9IGFsZ29yaXRobS5uYW1lICsgJ18nICsgYml0c1tqXTsKICAgICAgbWV0aG9kTmFtZXMucHVzaChtZXRob2ROYW1lKTsKICAgICAgbWV0aG9kc1ttZXRob2ROYW1lXSA9IGFsZ29yaXRobS5jcmVhdGVNZXRob2QoYml0c1tqXSwgYWxnb3JpdGhtLnBhZGRpbmcpOwogICAgICBpZiAoYWxnb3JpdGhtLm5hbWUgIT09ICdzaGEzJykgewogICAgICAgIHZhciBuZXdNZXRob2ROYW1lID0gYWxnb3JpdGhtLm5hbWUgKyBiaXRzW2pdOwogICAgICAgIG1ldGhvZE5hbWVzLnB1c2gobmV3TWV0aG9kTmFtZSk7CiAgICAgICAgbWV0aG9kc1tuZXdNZXRob2ROYW1lXSA9IG1ldGhvZHNbbWV0aG9kTmFtZV07CiAgICAgIH0KICAgIH0KICB9CgogIGZ1bmN0aW9uIEtlY2NhayhiaXRzLCBwYWRkaW5nLCBvdXRwdXRCaXRzKSB7CiAgICB0aGlzLmJsb2NrcyA9IFtdOwogICAgdGhpcy5zID0gW107CiAgICB0aGlzLnBhZGRpbmcgPSBwYWRkaW5nOwogICAgdGhpcy5vdXRwdXRCaXRzID0gb3V0cHV0Qml0czsKICAgIHRoaXMucmVzZXQgPSB0cnVlOwogICAgdGhpcy5maW5hbGl6ZWQgPSBmYWxzZTsKICAgIHRoaXMuYmxvY2sgPSAwOwogICAgdGhpcy5zdGFydCA9IDA7CiAgICB0aGlzLmJsb2NrQ291bnQgPSAoMTYwMCAtIChiaXRzIDw8IDEpKSA+PiA1OwogICAgdGhpcy5ieXRlQ291bnQgPSB0aGlzLmJsb2NrQ291bnQgPDwgMjsKICAgIHRoaXMub3V0cHV0QmxvY2tzID0gb3V0cHV0Qml0cyA+PiA1OwogICAgdGhpcy5leHRyYUJ5dGVzID0gKG91dHB1dEJpdHMgJiAzMSkgPj4gMzsKCiAgICBmb3IgKHZhciBpID0gMDsgaSA8IDUwOyArK2kpIHsKICAgICAgdGhpcy5zW2ldID0gMDsKICAgIH0KICB9CgogIEtlY2Nhay5wcm90b3R5cGUudXBkYXRlID0gZnVuY3Rpb24gKG1lc3NhZ2UpIHsKICAgIGlmICh0aGlzLmZpbmFsaXplZCkgewogICAgICB0aHJvdyBuZXcgRXJyb3IoRklOQUxJWkVfRVJST1IpOwogICAgfQogICAgdmFyIHJlc3VsdCA9IGZvcm1hdE1lc3NhZ2UobWVzc2FnZSk7CiAgICBtZXNzYWdlID0gcmVzdWx0WzBdOwogICAgdmFyIGlzU3RyaW5nID0gcmVzdWx0WzFdOwogICAgdmFyIGJsb2NrcyA9IHRoaXMuYmxvY2tzLCBieXRlQ291bnQgPSB0aGlzLmJ5dGVDb3VudCwgbGVuZ3RoID0gbWVzc2FnZS5sZW5ndGgsCiAgICAgIGJsb2NrQ291bnQgPSB0aGlzLmJsb2NrQ291bnQsIGluZGV4ID0gMCwgcyA9IHRoaXMucywgaSwgY29kZTsKCiAgICB3aGlsZSAoaW5kZXggPCBsZW5ndGgpIHsKICAgICAgaWYgKHRoaXMucmVzZXQpIHsKICAgICAgICB0aGlzLnJlc2V0ID0gZmFsc2U7CiAgICAgICAgYmxvY2tzWzBdID0gdGhpcy5ibG9jazsKICAgICAgICBmb3IgKGkgPSAxOyBpIDwgYmxvY2tDb3VudCArIDE7ICsraSkgewogICAgICAgICAgYmxvY2tzW2ldID0gMDsKICAgICAgICB9CiAgICAgIH0KICAgICAgaWYgKGlzU3RyaW5nKSB7CiAgICAgICAgZm9yIChpID0gdGhpcy5zdGFydDsgaW5kZXggPCBsZW5ndGggJiYgaSA8IGJ5dGVDb3VudDsgKytpbmRleCkgewogICAgICAgICAgY29kZSA9IG1lc3NhZ2UuY2hhckNvZGVBdChpbmRleCk7CiAgICAgICAgICBpZiAoY29kZSA8IDB4ODApIHsKICAgICAgICAgICAgYmxvY2tzW2kgPj4gMl0gfD0gY29kZSA8PCBTSElGVFtpKysgJiAzXTsKICAgICAgICAgIH0gZWxzZSBpZiAoY29kZSA8IDB4ODAwKSB7CiAgICAgICAgICAgIGJsb2Nrc1tpID4+IDJdIHw9ICgweGMwIHwgKGNvZGUgPj4gNikpIDw8IFNISUZUW2krKyAmIDNdOwogICAgICAgICAgICBibG9ja3NbaSA+PiAyXSB8PSAoMHg4MCB8IChjb2RlICYgMHgzZikpIDw8IFNISUZUW2krKyAmIDNdOwogICAgICAgICAgfSBlbHNlIGlmIChjb2RlIDwgMHhkODAwIHx8IGNvZGUgPj0gMHhlMDAwKSB7CiAgICAgICAgICAgIGJsb2Nrc1tpID4+IDJdIHw9ICgweGUwIHwgKGNvZGUgPj4gMTIpKSA8PCBTSElGVFtpKysgJiAzXTsKICAgICAgICAgICAgYmxvY2tzW2kgPj4gMl0gfD0gKDB4ODAgfCAoKGNvZGUgPj4gNikgJiAweDNmKSkgPDwgU0hJRlRbaSsrICYgM107CiAgICAgICAgICAgIGJsb2Nrc1tpID4+IDJdIHw9ICgweDgwIHwgKGNvZGUgJiAweDNmKSkgPDwgU0hJRlRbaSsrICYgM107CiAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBjb2RlID0gMHgxMDAwMCArICgoKGNvZGUgJiAweDNmZikgPDwgMTApIHwgKG1lc3NhZ2UuY2hhckNvZGVBdCgrK2luZGV4KSAmIDB4M2ZmKSk7CiAgICAgICAgICAgIGJsb2Nrc1tpID4+IDJdIHw9ICgweGYwIHwgKGNvZGUgPj4gMTgpKSA8PCBTSElGVFtpKysgJiAzXTsKICAgICAgICAgICAgYmxvY2tzW2kgPj4gMl0gfD0gKDB4ODAgfCAoKGNvZGUgPj4gMTIpICYgMHgzZikpIDw8IFNISUZUW2krKyAmIDNdOwogICAgICAgICAgICBibG9ja3NbaSA+PiAyXSB8PSAoMHg4MCB8ICgoY29kZSA+PiA2KSAmIDB4M2YpKSA8PCBTSElGVFtpKysgJiAzXTsKICAgICAgICAgICAgYmxvY2tzW2kgPj4gMl0gfD0gKDB4ODAgfCAoY29kZSAmIDB4M2YpKSA8PCBTSElGVFtpKysgJiAzXTsKICAgICAgICAgIH0KICAgICAgICB9CiAgICAgIH0gZWxzZSB7CiAgICAgICAgZm9yIChpID0gdGhpcy5zdGFydDsgaW5kZXggPCBsZW5ndGggJiYgaSA8IGJ5dGVDb3VudDsgKytpbmRleCkgewogICAgICAgICAgYmxvY2tzW2kgPj4gMl0gfD0gbWVzc2FnZVtpbmRleF0gPDwgU0hJRlRbaSsrICYgM107CiAgICAgICAgfQogICAgICB9CiAgICAgIHRoaXMubGFzdEJ5dGVJbmRleCA9IGk7CiAgICAgIGlmIChpID49IGJ5dGVDb3VudCkgewogICAgICAgIHRoaXMuc3RhcnQgPSBpIC0gYnl0ZUNvdW50OwogICAgICAgIHRoaXMuYmxvY2sgPSBibG9ja3NbYmxvY2tDb3VudF07CiAgICAgICAgZm9yIChpID0gMDsgaSA8IGJsb2NrQ291bnQ7ICsraSkgewogICAgICAgICAgc1tpXSBePSBibG9ja3NbaV07CiAgICAgICAgfQogICAgICAgIGYocyk7CiAgICAgICAgdGhpcy5yZXNldCA9IHRydWU7CiAgICAgIH0gZWxzZSB7CiAgICAgICAgdGhpcy5zdGFydCA9IGk7CiAgICAgIH0KICAgIH0KICAgIHJldHVybiB0aGlzOwogIH07CgogIEtlY2Nhay5wcm90b3R5cGUuZW5jb2RlID0gZnVuY3Rpb24gKHgsIHJpZ2h0KSB7CiAgICB2YXIgbyA9IHggJiAyNTUsIG4gPSAxOwogICAgdmFyIGJ5dGVzID0gW29dOwogICAgeCA9IHggPj4gODsKICAgIG8gPSB4ICYgMjU1OwogICAgd2hpbGUgKG8gPiAwKSB7CiAgICAgIGJ5dGVzLnVuc2hpZnQobyk7CiAgICAgIHggPSB4ID4+IDg7CiAgICAgIG8gPSB4ICYgMjU1OwogICAgICArK247CiAgICB9CiAgICBpZiAocmlnaHQpIHsKICAgICAgYnl0ZXMucHVzaChuKTsKICAgIH0gZWxzZSB7CiAgICAgIGJ5dGVzLnVuc2hpZnQobik7CiAgICB9CiAgICB0aGlzLnVwZGF0ZShieXRlcyk7CiAgICByZXR1cm4gYnl0ZXMubGVuZ3RoOwogIH07CgogIEtlY2Nhay5wcm90b3R5cGUuZW5jb2RlU3RyaW5nID0gZnVuY3Rpb24gKHN0cikgewogICAgdmFyIHJlc3VsdCA9IGZvcm1hdE1lc3NhZ2Uoc3RyKTsKICAgIHN0ciA9IHJlc3VsdFswXTsKICAgIHZhciBpc1N0cmluZyA9IHJlc3VsdFsxXTsKICAgIHZhciBieXRlcyA9IDAsIGxlbmd0aCA9IHN0ci5sZW5ndGg7CiAgICBpZiAoaXNTdHJpbmcpIHsKICAgICAgZm9yICh2YXIgaSA9IDA7IGkgPCBzdHIubGVuZ3RoOyArK2kpIHsKICAgICAgICB2YXIgY29kZSA9IHN0ci5jaGFyQ29kZUF0KGkpOwogICAgICAgIGlmIChjb2RlIDwgMHg4MCkgewogICAgICAgICAgYnl0ZXMgKz0gMTsKICAgICAgICB9IGVsc2UgaWYgKGNvZGUgPCAweDgwMCkgewogICAgICAgICAgYnl0ZXMgKz0gMjsKICAgICAgICB9IGVsc2UgaWYgKGNvZGUgPCAweGQ4MDAgfHwgY29kZSA+PSAweGUwMDApIHsKICAgICAgICAgIGJ5dGVzICs9IDM7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgIGNvZGUgPSAweDEwMDAwICsgKCgoY29kZSAmIDB4M2ZmKSA8PCAxMCkgfCAoc3RyLmNoYXJDb2RlQXQoKytpKSAmIDB4M2ZmKSk7CiAgICAgICAgICBieXRlcyArPSA0OwogICAgICAgIH0KICAgICAgfQogICAgfSBlbHNlIHsKICAgICAgYnl0ZXMgPSBsZW5ndGg7CiAgICB9CiAgICBieXRlcyArPSB0aGlzLmVuY29kZShieXRlcyAqIDgpOwogICAgdGhpcy51cGRhdGUoc3RyKTsKICAgIHJldHVybiBieXRlczsKICB9OwoKICBLZWNjYWsucHJvdG90eXBlLmJ5dGVwYWQgPSBmdW5jdGlvbiAoc3RycywgdykgewogICAgdmFyIGJ5dGVzID0gdGhpcy5lbmNvZGUodyk7CiAgICBmb3IgKHZhciBpID0gMDsgaSA8IHN0cnMubGVuZ3RoOyArK2kpIHsKICAgICAgYnl0ZXMgKz0gdGhpcy5lbmNvZGVTdHJpbmcoc3Ryc1tpXSk7CiAgICB9CiAgICB2YXIgcGFkZGluZ0J5dGVzID0gKHcgLSBieXRlcyAlIHcpICUgdzsKICAgIHZhciB6ZXJvcyA9IFtdOwogICAgemVyb3MubGVuZ3RoID0gcGFkZGluZ0J5dGVzOwogICAgdGhpcy51cGRhdGUoemVyb3MpOwogICAgcmV0dXJuIHRoaXM7CiAgfTsKCiAgS2VjY2FrLnByb3RvdHlwZS5maW5hbGl6ZSA9IGZ1bmN0aW9uICgpIHsKICAgIGlmICh0aGlzLmZpbmFsaXplZCkgewogICAgICByZXR1cm47CiAgICB9CiAgICB0aGlzLmZpbmFsaXplZCA9IHRydWU7CiAgICB2YXIgYmxvY2tzID0gdGhpcy5ibG9ja3MsIGkgPSB0aGlzLmxhc3RCeXRlSW5kZXgsIGJsb2NrQ291bnQgPSB0aGlzLmJsb2NrQ291bnQsIHMgPSB0aGlzLnM7CiAgICBibG9ja3NbaSA+PiAyXSB8PSB0aGlzLnBhZGRpbmdbaSAmIDNdOwogICAgaWYgKHRoaXMubGFzdEJ5dGVJbmRleCA9PT0gdGhpcy5ieXRlQ291bnQpIHsKICAgICAgYmxvY2tzWzBdID0gYmxvY2tzW2Jsb2NrQ291bnRdOwogICAgICBmb3IgKGkgPSAxOyBpIDwgYmxvY2tDb3VudCArIDE7ICsraSkgewogICAgICAgIGJsb2Nrc1tpXSA9IDA7CiAgICAgIH0KICAgIH0KICAgIGJsb2Nrc1tibG9ja0NvdW50IC0gMV0gfD0gMHg4MDAwMDAwMDsKICAgIGZvciAoaSA9IDA7IGkgPCBibG9ja0NvdW50OyArK2kpIHsKICAgICAgc1tpXSBePSBibG9ja3NbaV07CiAgICB9CiAgICBmKHMpOwogIH07CgogIEtlY2Nhay5wcm90b3R5cGUudG9TdHJpbmcgPSBLZWNjYWsucHJvdG90eXBlLmhleCA9IGZ1bmN0aW9uICgpIHsKICAgIHRoaXMuZmluYWxpemUoKTsKCiAgICB2YXIgYmxvY2tDb3VudCA9IHRoaXMuYmxvY2tDb3VudCwgcyA9IHRoaXMucywgb3V0cHV0QmxvY2tzID0gdGhpcy5vdXRwdXRCbG9ja3MsCiAgICAgIGV4dHJhQnl0ZXMgPSB0aGlzLmV4dHJhQnl0ZXMsIGkgPSAwLCBqID0gMDsKICAgIHZhciBoZXggPSAnJywgYmxvY2s7CiAgICB3aGlsZSAoaiA8IG91dHB1dEJsb2NrcykgewogICAgICBmb3IgKGkgPSAwOyBpIDwgYmxvY2tDb3VudCAmJiBqIDwgb3V0cHV0QmxvY2tzOyArK2ksICsraikgewogICAgICAgIGJsb2NrID0gc1tpXTsKICAgICAgICBoZXggKz0gSEVYX0NIQVJTWyhibG9jayA+PiA0KSAmIDB4MEZdICsgSEVYX0NIQVJTW2Jsb2NrICYgMHgwRl0gKwogICAgICAgICAgSEVYX0NIQVJTWyhibG9jayA+PiAxMikgJiAweDBGXSArIEhFWF9DSEFSU1soYmxvY2sgPj4gOCkgJiAweDBGXSArCiAgICAgICAgICBIRVhfQ0hBUlNbKGJsb2NrID4+IDIwKSAmIDB4MEZdICsgSEVYX0NIQVJTWyhibG9jayA+PiAxNikgJiAweDBGXSArCiAgICAgICAgICBIRVhfQ0hBUlNbKGJsb2NrID4+IDI4KSAmIDB4MEZdICsgSEVYX0NIQVJTWyhibG9jayA+PiAyNCkgJiAweDBGXTsKICAgICAgfQogICAgICBpZiAoaiAlIGJsb2NrQ291bnQgPT09IDApIHsKICAgICAgICBzID0gY2xvbmVBcnJheShzKTsKICAgICAgICBmKHMpOwogICAgICAgIGkgPSAwOwogICAgICB9CiAgICB9CiAgICBpZiAoZXh0cmFCeXRlcykgewogICAgICBibG9jayA9IHNbaV07CiAgICAgIGhleCArPSBIRVhfQ0hBUlNbKGJsb2NrID4+IDQpICYgMHgwRl0gKyBIRVhfQ0hBUlNbYmxvY2sgJiAweDBGXTsKICAgICAgaWYgKGV4dHJhQnl0ZXMgPiAxKSB7CiAgICAgICAgaGV4ICs9IEhFWF9DSEFSU1soYmxvY2sgPj4gMTIpICYgMHgwRl0gKyBIRVhfQ0hBUlNbKGJsb2NrID4+IDgpICYgMHgwRl07CiAgICAgIH0KICAgICAgaWYgKGV4dHJhQnl0ZXMgPiAyKSB7CiAgICAgICAgaGV4ICs9IEhFWF9DSEFSU1soYmxvY2sgPj4gMjApICYgMHgwRl0gKyBIRVhfQ0hBUlNbKGJsb2NrID4+IDE2KSAmIDB4MEZdOwogICAgICB9CiAgICB9CiAgICByZXR1cm4gaGV4OwogIH07CgogIEtlY2Nhay5wcm90b3R5cGUuYXJyYXlCdWZmZXIgPSBmdW5jdGlvbiAoKSB7CiAgICB0aGlzLmZpbmFsaXplKCk7CgogICAgdmFyIGJsb2NrQ291bnQgPSB0aGlzLmJsb2NrQ291bnQsIHMgPSB0aGlzLnMsIG91dHB1dEJsb2NrcyA9IHRoaXMub3V0cHV0QmxvY2tzLAogICAgICBleHRyYUJ5dGVzID0gdGhpcy5leHRyYUJ5dGVzLCBpID0gMCwgaiA9IDA7CiAgICB2YXIgYnl0ZXMgPSB0aGlzLm91dHB1dEJpdHMgPj4gMzsKICAgIHZhciBidWZmZXI7CiAgICBpZiAoZXh0cmFCeXRlcykgewogICAgICBidWZmZXIgPSBuZXcgQXJyYXlCdWZmZXIoKG91dHB1dEJsb2NrcyArIDEpIDw8IDIpOwogICAgfSBlbHNlIHsKICAgICAgYnVmZmVyID0gbmV3IEFycmF5QnVmZmVyKGJ5dGVzKTsKICAgIH0KICAgIHZhciBhcnJheSA9IG5ldyBVaW50MzJBcnJheShidWZmZXIpOwogICAgd2hpbGUgKGogPCBvdXRwdXRCbG9ja3MpIHsKICAgICAgZm9yIChpID0gMDsgaSA8IGJsb2NrQ291bnQgJiYgaiA8IG91dHB1dEJsb2NrczsgKytpLCArK2opIHsKICAgICAgICBhcnJheVtqXSA9IHNbaV07CiAgICAgIH0KICAgICAgaWYgKGogJSBibG9ja0NvdW50ID09PSAwKSB7CiAgICAgICAgcyA9IGNsb25lQXJyYXkocyk7CiAgICAgICAgZihzKTsKICAgICAgfQogICAgfQogICAgaWYgKGV4dHJhQnl0ZXMpIHsKICAgICAgYXJyYXlbal0gPSBzW2ldOwogICAgICBidWZmZXIgPSBidWZmZXIuc2xpY2UoMCwgYnl0ZXMpOwogICAgfQogICAgcmV0dXJuIGJ1ZmZlcjsKICB9OwoKICBLZWNjYWsucHJvdG90eXBlLmJ1ZmZlciA9IEtlY2Nhay5wcm90b3R5cGUuYXJyYXlCdWZmZXI7CgogIEtlY2Nhay5wcm90b3R5cGUuZGlnZXN0ID0gS2VjY2FrLnByb3RvdHlwZS5hcnJheSA9IGZ1bmN0aW9uICgpIHsKICAgIHRoaXMuZmluYWxpemUoKTsKCiAgICB2YXIgYmxvY2tDb3VudCA9IHRoaXMuYmxvY2tDb3VudCwgcyA9IHRoaXMucywgb3V0cHV0QmxvY2tzID0gdGhpcy5vdXRwdXRCbG9ja3MsCiAgICAgIGV4dHJhQnl0ZXMgPSB0aGlzLmV4dHJhQnl0ZXMsIGkgPSAwLCBqID0gMDsKICAgIHZhciBhcnJheSA9IFtdLCBvZmZzZXQsIGJsb2NrOwogICAgd2hpbGUgKGogPCBvdXRwdXRCbG9ja3MpIHsKICAgICAgZm9yIChpID0gMDsgaSA8IGJsb2NrQ291bnQgJiYgaiA8IG91dHB1dEJsb2NrczsgKytpLCArK2opIHsKICAgICAgICBvZmZzZXQgPSBqIDw8IDI7CiAgICAgICAgYmxvY2sgPSBzW2ldOwogICAgICAgIGFycmF5W29mZnNldF0gPSBibG9jayAmIDB4RkY7CiAgICAgICAgYXJyYXlbb2Zmc2V0ICsgMV0gPSAoYmxvY2sgPj4gOCkgJiAweEZGOwogICAgICAgIGFycmF5W29mZnNldCArIDJdID0gKGJsb2NrID4+IDE2KSAmIDB4RkY7CiAgICAgICAgYXJyYXlbb2Zmc2V0ICsgM10gPSAoYmxvY2sgPj4gMjQpICYgMHhGRjsKICAgICAgfQogICAgICBpZiAoaiAlIGJsb2NrQ291bnQgPT09IDApIHsKICAgICAgICBzID0gY2xvbmVBcnJheShzKTsKICAgICAgICBmKHMpOwogICAgICB9CiAgICB9CiAgICBpZiAoZXh0cmFCeXRlcykgewogICAgICBvZmZzZXQgPSBqIDw8IDI7CiAgICAgIGJsb2NrID0gc1tpXTsKICAgICAgYXJyYXlbb2Zmc2V0XSA9IGJsb2NrICYgMHhGRjsKICAgICAgaWYgKGV4dHJhQnl0ZXMgPiAxKSB7CiAgICAgICAgYXJyYXlbb2Zmc2V0ICsgMV0gPSAoYmxvY2sgPj4gOCkgJiAweEZGOwogICAgICB9CiAgICAgIGlmIChleHRyYUJ5dGVzID4gMikgewogICAgICAgIGFycmF5W29mZnNldCArIDJdID0gKGJsb2NrID4+IDE2KSAmIDB4RkY7CiAgICAgIH0KICAgIH0KICAgIHJldHVybiBhcnJheTsKICB9OwoKICBmdW5jdGlvbiBLbWFjKGJpdHMsIHBhZGRpbmcsIG91dHB1dEJpdHMpIHsKICAgIEtlY2Nhay5jYWxsKHRoaXMsIGJpdHMsIHBhZGRpbmcsIG91dHB1dEJpdHMpOwogIH0KCiAgS21hYy5wcm90b3R5cGUgPSBuZXcgS2VjY2FrKCk7CgogIEttYWMucHJvdG90eXBlLmZpbmFsaXplID0gZnVuY3Rpb24gKCkgewogICAgdGhpcy5lbmNvZGUodGhpcy5vdXRwdXRCaXRzLCB0cnVlKTsKICAgIHJldHVybiBLZWNjYWsucHJvdG90eXBlLmZpbmFsaXplLmNhbGwodGhpcyk7CiAgfTsKCiAgdmFyIGYgPSBmdW5jdGlvbiAocykgewogICAgdmFyIGgsIGwsIG4sIGMwLCBjMSwgYzIsIGMzLCBjNCwgYzUsIGM2LCBjNywgYzgsIGM5LAogICAgICBiMCwgYjEsIGIyLCBiMywgYjQsIGI1LCBiNiwgYjcsIGI4LCBiOSwgYjEwLCBiMTEsIGIxMiwgYjEzLCBiMTQsIGIxNSwgYjE2LCBiMTcsCiAgICAgIGIxOCwgYjE5LCBiMjAsIGIyMSwgYjIyLCBiMjMsIGIyNCwgYjI1LCBiMjYsIGIyNywgYjI4LCBiMjksIGIzMCwgYjMxLCBiMzIsIGIzMywKICAgICAgYjM0LCBiMzUsIGIzNiwgYjM3LCBiMzgsIGIzOSwgYjQwLCBiNDEsIGI0MiwgYjQzLCBiNDQsIGI0NSwgYjQ2LCBiNDcsIGI0OCwgYjQ5OwogICAgZm9yIChuID0gMDsgbiA8IDQ4OyBuICs9IDIpIHsKICAgICAgYzAgPSBzWzBdIF4gc1sxMF0gXiBzWzIwXSBeIHNbMzBdIF4gc1s0MF07CiAgICAgIGMxID0gc1sxXSBeIHNbMTFdIF4gc1syMV0gXiBzWzMxXSBeIHNbNDFdOwogICAgICBjMiA9IHNbMl0gXiBzWzEyXSBeIHNbMjJdIF4gc1szMl0gXiBzWzQyXTsKICAgICAgYzMgPSBzWzNdIF4gc1sxM10gXiBzWzIzXSBeIHNbMzNdIF4gc1s0M107CiAgICAgIGM0ID0gc1s0XSBeIHNbMTRdIF4gc1syNF0gXiBzWzM0XSBeIHNbNDRdOwogICAgICBjNSA9IHNbNV0gXiBzWzE1XSBeIHNbMjVdIF4gc1szNV0gXiBzWzQ1XTsKICAgICAgYzYgPSBzWzZdIF4gc1sxNl0gXiBzWzI2XSBeIHNbMzZdIF4gc1s0Nl07CiAgICAgIGM3ID0gc1s3XSBeIHNbMTddIF4gc1syN10gXiBzWzM3XSBeIHNbNDddOwogICAgICBjOCA9IHNbOF0gXiBzWzE4XSBeIHNbMjhdIF4gc1szOF0gXiBzWzQ4XTsKICAgICAgYzkgPSBzWzldIF4gc1sxOV0gXiBzWzI5XSBeIHNbMzldIF4gc1s0OV07CgogICAgICBoID0gYzggXiAoKGMyIDw8IDEpIHwgKGMzID4+PiAzMSkpOwogICAgICBsID0gYzkgXiAoKGMzIDw8IDEpIHwgKGMyID4+PiAzMSkpOwogICAgICBzWzBdIF49IGg7CiAgICAgIHNbMV0gXj0gbDsKICAgICAgc1sxMF0gXj0gaDsKICAgICAgc1sxMV0gXj0gbDsKICAgICAgc1syMF0gXj0gaDsKICAgICAgc1syMV0gXj0gbDsKICAgICAgc1szMF0gXj0gaDsKICAgICAgc1szMV0gXj0gbDsKICAgICAgc1s0MF0gXj0gaDsKICAgICAgc1s0MV0gXj0gbDsKICAgICAgaCA9IGMwIF4gKChjNCA8PCAxKSB8IChjNSA+Pj4gMzEpKTsKICAgICAgbCA9IGMxIF4gKChjNSA8PCAxKSB8IChjNCA+Pj4gMzEpKTsKICAgICAgc1syXSBePSBoOwogICAgICBzWzNdIF49IGw7CiAgICAgIHNbMTJdIF49IGg7CiAgICAgIHNbMTNdIF49IGw7CiAgICAgIHNbMjJdIF49IGg7CiAgICAgIHNbMjNdIF49IGw7CiAgICAgIHNbMzJdIF49IGg7CiAgICAgIHNbMzNdIF49IGw7CiAgICAgIHNbNDJdIF49IGg7CiAgICAgIHNbNDNdIF49IGw7CiAgICAgIGggPSBjMiBeICgoYzYgPDwgMSkgfCAoYzcgPj4+IDMxKSk7CiAgICAgIGwgPSBjMyBeICgoYzcgPDwgMSkgfCAoYzYgPj4+IDMxKSk7CiAgICAgIHNbNF0gXj0gaDsKICAgICAgc1s1XSBePSBsOwogICAgICBzWzE0XSBePSBoOwogICAgICBzWzE1XSBePSBsOwogICAgICBzWzI0XSBePSBoOwogICAgICBzWzI1XSBePSBsOwogICAgICBzWzM0XSBePSBoOwogICAgICBzWzM1XSBePSBsOwogICAgICBzWzQ0XSBePSBoOwogICAgICBzWzQ1XSBePSBsOwogICAgICBoID0gYzQgXiAoKGM4IDw8IDEpIHwgKGM5ID4+PiAzMSkpOwogICAgICBsID0gYzUgXiAoKGM5IDw8IDEpIHwgKGM4ID4+PiAzMSkpOwogICAgICBzWzZdIF49IGg7CiAgICAgIHNbN10gXj0gbDsKICAgICAgc1sxNl0gXj0gaDsKICAgICAgc1sxN10gXj0gbDsKICAgICAgc1syNl0gXj0gaDsKICAgICAgc1syN10gXj0gbDsKICAgICAgc1szNl0gXj0gaDsKICAgICAgc1szN10gXj0gbDsKICAgICAgc1s0Nl0gXj0gaDsKICAgICAgc1s0N10gXj0gbDsKICAgICAgaCA9IGM2IF4gKChjMCA8PCAxKSB8IChjMSA+Pj4gMzEpKTsKICAgICAgbCA9IGM3IF4gKChjMSA8PCAxKSB8IChjMCA+Pj4gMzEpKTsKICAgICAgc1s4XSBePSBoOwogICAgICBzWzldIF49IGw7CiAgICAgIHNbMThdIF49IGg7CiAgICAgIHNbMTldIF49IGw7CiAgICAgIHNbMjhdIF49IGg7CiAgICAgIHNbMjldIF49IGw7CiAgICAgIHNbMzhdIF49IGg7CiAgICAgIHNbMzldIF49IGw7CiAgICAgIHNbNDhdIF49IGg7CiAgICAgIHNbNDldIF49IGw7CgogICAgICBiMCA9IHNbMF07CiAgICAgIGIxID0gc1sxXTsKICAgICAgYjMyID0gKHNbMTFdIDw8IDQpIHwgKHNbMTBdID4+PiAyOCk7CiAgICAgIGIzMyA9IChzWzEwXSA8PCA0KSB8IChzWzExXSA+Pj4gMjgpOwogICAgICBiMTQgPSAoc1syMF0gPDwgMykgfCAoc1syMV0gPj4+IDI5KTsKICAgICAgYjE1ID0gKHNbMjFdIDw8IDMpIHwgKHNbMjBdID4+PiAyOSk7CiAgICAgIGI0NiA9IChzWzMxXSA8PCA5KSB8IChzWzMwXSA+Pj4gMjMpOwogICAgICBiNDcgPSAoc1szMF0gPDwgOSkgfCAoc1szMV0gPj4+IDIzKTsKICAgICAgYjI4ID0gKHNbNDBdIDw8IDE4KSB8IChzWzQxXSA+Pj4gMTQpOwogICAgICBiMjkgPSAoc1s0MV0gPDwgMTgpIHwgKHNbNDBdID4+PiAxNCk7CiAgICAgIGIyMCA9IChzWzJdIDw8IDEpIHwgKHNbM10gPj4+IDMxKTsKICAgICAgYjIxID0gKHNbM10gPDwgMSkgfCAoc1syXSA+Pj4gMzEpOwogICAgICBiMiA9IChzWzEzXSA8PCAxMikgfCAoc1sxMl0gPj4+IDIwKTsKICAgICAgYjMgPSAoc1sxMl0gPDwgMTIpIHwgKHNbMTNdID4+PiAyMCk7CiAgICAgIGIzNCA9IChzWzIyXSA8PCAxMCkgfCAoc1syM10gPj4+IDIyKTsKICAgICAgYjM1ID0gKHNbMjNdIDw8IDEwKSB8IChzWzIyXSA+Pj4gMjIpOwogICAgICBiMTYgPSAoc1szM10gPDwgMTMpIHwgKHNbMzJdID4+PiAxOSk7CiAgICAgIGIxNyA9IChzWzMyXSA8PCAxMykgfCAoc1szM10gPj4+IDE5KTsKICAgICAgYjQ4ID0gKHNbNDJdIDw8IDIpIHwgKHNbNDNdID4+PiAzMCk7CiAgICAgIGI0OSA9IChzWzQzXSA8PCAyKSB8IChzWzQyXSA+Pj4gMzApOwogICAgICBiNDAgPSAoc1s1XSA8PCAzMCkgfCAoc1s0XSA+Pj4gMik7CiAgICAgIGI0MSA9IChzWzRdIDw8IDMwKSB8IChzWzVdID4+PiAyKTsKICAgICAgYjIyID0gKHNbMTRdIDw8IDYpIHwgKHNbMTVdID4+PiAyNik7CiAgICAgIGIyMyA9IChzWzE1XSA8PCA2KSB8IChzWzE0XSA+Pj4gMjYpOwogICAgICBiNCA9IChzWzI1XSA8PCAxMSkgfCAoc1syNF0gPj4+IDIxKTsKICAgICAgYjUgPSAoc1syNF0gPDwgMTEpIHwgKHNbMjVdID4+PiAyMSk7CiAgICAgIGIzNiA9IChzWzM0XSA8PCAxNSkgfCAoc1szNV0gPj4+IDE3KTsKICAgICAgYjM3ID0gKHNbMzVdIDw8IDE1KSB8IChzWzM0XSA+Pj4gMTcpOwogICAgICBiMTggPSAoc1s0NV0gPDwgMjkpIHwgKHNbNDRdID4+PiAzKTsKICAgICAgYjE5ID0gKHNbNDRdIDw8IDI5KSB8IChzWzQ1XSA+Pj4gMyk7CiAgICAgIGIxMCA9IChzWzZdIDw8IDI4KSB8IChzWzddID4+PiA0KTsKICAgICAgYjExID0gKHNbN10gPDwgMjgpIHwgKHNbNl0gPj4+IDQpOwogICAgICBiNDIgPSAoc1sxN10gPDwgMjMpIHwgKHNbMTZdID4+PiA5KTsKICAgICAgYjQzID0gKHNbMTZdIDw8IDIzKSB8IChzWzE3XSA+Pj4gOSk7CiAgICAgIGIyNCA9IChzWzI2XSA8PCAyNSkgfCAoc1syN10gPj4+IDcpOwogICAgICBiMjUgPSAoc1syN10gPDwgMjUpIHwgKHNbMjZdID4+PiA3KTsKICAgICAgYjYgPSAoc1szNl0gPDwgMjEpIHwgKHNbMzddID4+PiAxMSk7CiAgICAgIGI3ID0gKHNbMzddIDw8IDIxKSB8IChzWzM2XSA+Pj4gMTEpOwogICAgICBiMzggPSAoc1s0N10gPDwgMjQpIHwgKHNbNDZdID4+PiA4KTsKICAgICAgYjM5ID0gKHNbNDZdIDw8IDI0KSB8IChzWzQ3XSA+Pj4gOCk7CiAgICAgIGIzMCA9IChzWzhdIDw8IDI3KSB8IChzWzldID4+PiA1KTsKICAgICAgYjMxID0gKHNbOV0gPDwgMjcpIHwgKHNbOF0gPj4+IDUpOwogICAgICBiMTIgPSAoc1sxOF0gPDwgMjApIHwgKHNbMTldID4+PiAxMik7CiAgICAgIGIxMyA9IChzWzE5XSA8PCAyMCkgfCAoc1sxOF0gPj4+IDEyKTsKICAgICAgYjQ0ID0gKHNbMjldIDw8IDcpIHwgKHNbMjhdID4+PiAyNSk7CiAgICAgIGI0NSA9IChzWzI4XSA8PCA3KSB8IChzWzI5XSA+Pj4gMjUpOwogICAgICBiMjYgPSAoc1szOF0gPDwgOCkgfCAoc1szOV0gPj4+IDI0KTsKICAgICAgYjI3ID0gKHNbMzldIDw8IDgpIHwgKHNbMzhdID4+PiAyNCk7CiAgICAgIGI4ID0gKHNbNDhdIDw8IDE0KSB8IChzWzQ5XSA+Pj4gMTgpOwogICAgICBiOSA9IChzWzQ5XSA8PCAxNCkgfCAoc1s0OF0gPj4+IDE4KTsKCiAgICAgIHNbMF0gPSBiMCBeICh+YjIgJiBiNCk7CiAgICAgIHNbMV0gPSBiMSBeICh+YjMgJiBiNSk7CiAgICAgIHNbMTBdID0gYjEwIF4gKH5iMTIgJiBiMTQpOwogICAgICBzWzExXSA9IGIxMSBeICh+YjEzICYgYjE1KTsKICAgICAgc1syMF0gPSBiMjAgXiAofmIyMiAmIGIyNCk7CiAgICAgIHNbMjFdID0gYjIxIF4gKH5iMjMgJiBiMjUpOwogICAgICBzWzMwXSA9IGIzMCBeICh+YjMyICYgYjM0KTsKICAgICAgc1szMV0gPSBiMzEgXiAofmIzMyAmIGIzNSk7CiAgICAgIHNbNDBdID0gYjQwIF4gKH5iNDIgJiBiNDQpOwogICAgICBzWzQxXSA9IGI0MSBeICh+YjQzICYgYjQ1KTsKICAgICAgc1syXSA9IGIyIF4gKH5iNCAmIGI2KTsKICAgICAgc1szXSA9IGIzIF4gKH5iNSAmIGI3KTsKICAgICAgc1sxMl0gPSBiMTIgXiAofmIxNCAmIGIxNik7CiAgICAgIHNbMTNdID0gYjEzIF4gKH5iMTUgJiBiMTcpOwogICAgICBzWzIyXSA9IGIyMiBeICh+YjI0ICYgYjI2KTsKICAgICAgc1syM10gPSBiMjMgXiAofmIyNSAmIGIyNyk7CiAgICAgIHNbMzJdID0gYjMyIF4gKH5iMzQgJiBiMzYpOwogICAgICBzWzMzXSA9IGIzMyBeICh+YjM1ICYgYjM3KTsKICAgICAgc1s0Ml0gPSBiNDIgXiAofmI0NCAmIGI0Nik7CiAgICAgIHNbNDNdID0gYjQzIF4gKH5iNDUgJiBiNDcpOwogICAgICBzWzRdID0gYjQgXiAofmI2ICYgYjgpOwogICAgICBzWzVdID0gYjUgXiAofmI3ICYgYjkpOwogICAgICBzWzE0XSA9IGIxNCBeICh+YjE2ICYgYjE4KTsKICAgICAgc1sxNV0gPSBiMTUgXiAofmIxNyAmIGIxOSk7CiAgICAgIHNbMjRdID0gYjI0IF4gKH5iMjYgJiBiMjgpOwogICAgICBzWzI1XSA9IGIyNSBeICh+YjI3ICYgYjI5KTsKICAgICAgc1szNF0gPSBiMzQgXiAofmIzNiAmIGIzOCk7CiAgICAgIHNbMzVdID0gYjM1IF4gKH5iMzcgJiBiMzkpOwogICAgICBzWzQ0XSA9IGI0NCBeICh+YjQ2ICYgYjQ4KTsKICAgICAgc1s0NV0gPSBiNDUgXiAofmI0NyAmIGI0OSk7CiAgICAgIHNbNl0gPSBiNiBeICh+YjggJiBiMCk7CiAgICAgIHNbN10gPSBiNyBeICh+YjkgJiBiMSk7CiAgICAgIHNbMTZdID0gYjE2IF4gKH5iMTggJiBiMTApOwogICAgICBzWzE3XSA9IGIxNyBeICh+YjE5ICYgYjExKTsKICAgICAgc1syNl0gPSBiMjYgXiAofmIyOCAmIGIyMCk7CiAgICAgIHNbMjddID0gYjI3IF4gKH5iMjkgJiBiMjEpOwogICAgICBzWzM2XSA9IGIzNiBeICh+YjM4ICYgYjMwKTsKICAgICAgc1szN10gPSBiMzcgXiAofmIzOSAmIGIzMSk7CiAgICAgIHNbNDZdID0gYjQ2IF4gKH5iNDggJiBiNDApOwogICAgICBzWzQ3XSA9IGI0NyBeICh+YjQ5ICYgYjQxKTsKICAgICAgc1s4XSA9IGI4IF4gKH5iMCAmIGIyKTsKICAgICAgc1s5XSA9IGI5IF4gKH5iMSAmIGIzKTsKICAgICAgc1sxOF0gPSBiMTggXiAofmIxMCAmIGIxMik7CiAgICAgIHNbMTldID0gYjE5IF4gKH5iMTEgJiBiMTMpOwogICAgICBzWzI4XSA9IGIyOCBeICh+YjIwICYgYjIyKTsKICAgICAgc1syOV0gPSBiMjkgXiAofmIyMSAmIGIyMyk7CiAgICAgIHNbMzhdID0gYjM4IF4gKH5iMzAgJiBiMzIpOwogICAgICBzWzM5XSA9IGIzOSBeICh+YjMxICYgYjMzKTsKICAgICAgc1s0OF0gPSBiNDggXiAofmI0MCAmIGI0Mik7CiAgICAgIHNbNDldID0gYjQ5IF4gKH5iNDEgJiBiNDMpOwoKICAgICAgc1swXSBePSBSQ1tuXTsKICAgICAgc1sxXSBePSBSQ1tuICsgMV07CiAgICB9CiAgfTsKCiAgaWYgKENPTU1PTl9KUykgewogICAgbW9kdWxlLmV4cG9ydHMgPSBtZXRob2RzOwogIH0gZWxzZSB7CiAgICBmb3IgKGkgPSAwOyBpIDwgbWV0aG9kTmFtZXMubGVuZ3RoOyArK2kpIHsKICAgICAgcm9vdFttZXRob2ROYW1lc1tpXV0gPSBtZXRob2RzW21ldGhvZE5hbWVzW2ldXTsKICAgIH0KICAgIGlmIChBTUQpIHsKICAgICAgZGVmaW5lKGZ1bmN0aW9uICgpIHsKICAgICAgICByZXR1cm4gbWV0aG9kczsKICAgICAgfSk7CiAgICB9CiAgfQp9KSgpOwo="
}
