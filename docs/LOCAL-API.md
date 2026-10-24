# 讓其他 app 使用本機模型（設計說明）

2026-10-24。基準：llama.cpp b11046、Gemma 4 E4B、`-c 8192`、`-np 1`。使用方式見 README「Use the local model from other apps」。

## 為什麼這樣做

之前 Lint 的 `llama-server`（`127.0.0.1:8000`）沒有驗證，CORS 會把任何 Origin 原樣放行。2026-10-24 用 Chrome 155 實測：`https://example.com` 的網頁直接打 `127.0.0.1:8000`，GET、帶 `Authorization` 的請求、JSON POST 都成功，還跑出一次補全，沒有權限提示。使用者在額外參數加了 `--tools` 的話，網頁甚至能用到 llama-server 的檔案與 shell 工具。

需求是讓本機其他 app 與網頁正式使用模型，但 **Lint 需要模型時永遠優先**。llama-server 只有一個 slot，請求先到先處理，沒有優先序，所以由 Lint 自己開一個代理擋在外部前面。

## 架構

```
外部 app／網頁 ─(127.0.0.1:API 埠，使用者金鑰，Host/Origin 檢查)─> LocalAPIProxy ─(內部金鑰)─┐
                                                                                        ├─> llama-server 127.0.0.1:8000
Lint（LLMService → OpenAICompatibleProvider）────────────(內部金鑰)────────────────────────┘
        ModelPriorityGate：Lint 開始 → 同步中斷外部請求；Lint 進行中、之後 3 秒內、打字時，外部等候
```

- **llama-server 永遠帶內部金鑰**（與開關無關）：每個 Lint 行程產生一次（`LocalLlamaServerManager.serverKey`），經 `--api-key-file /dev/stdin` 傳入，不在 argv、環境變數、磁碟或日誌。只有 Lint 與代理打得進去。
- **代理只在開關開啟、且 Lint 的請求走本機 llama.cpp 時監聽**，預設埠 8001。絕不能與 llama-server 同埠：`stop(port:)` 會殺掉該埠所有監聽者。
- 開關、重新產生金鑰、改允許清單、改 API 埠都即時生效，不重啟 llama-server。

## 元件（`Sources/LintCore/LocalAPI/`）

| 檔案 | 作用 |
|---|---|
| `LocalAPIKey.swift` | 32 bytes 亂數的 base64url 金鑰，印出時遮蔽；`LocalAPIKeyStore` 把使用者金鑰存在鑰匙圈（第一次開啟時才建立，讀一次後快取） |
| `ModelPriorityGate.swift` | Lint 一側同步、不等待；外部先進先出、一次一個、可被搶占、被搶占且未回應的插回隊首 |
| `LocalAPIHTTP.swift` | 只支援 `Content-Length` body 的最小 HTTP/1.1，回應後關閉連線 |
| `LocalAPIPolicy.swift` | Host、Origin 允許清單、金鑰、CORS 標頭 |
| `LocalAPIUpstream.swift` | 以 URLSession delegate 逐段讀 llama-server 的回應，取消即關閉連線 |
| `LocalAPIProxy.swift` | `NWListener`（只綁 127.0.0.1）、檢查、路由、排程、轉送、重送、日誌彙總 |
| `LocalAPIService.swift` | 依設定啟停代理；只有換埠才重新監聽 |

其他改動：`LlamaServerLaunchPlan`（金鑰、CORS 鎖、`--alias`、受保護參數丟棄表）、`LlamaServerEnvironment`（丟掉 `LLAMA_API_KEY`、`LLAMA_ARG_*`）、`BoundedLogBuffer`（遮掉含 `api_key` 的行）、`ForeignServerPolicy` 與 `LocalServerProbe`（接手別人的伺服器、替換 Lint 殘留的伺服器）、`LocalAISetupCoordinator.restartServer`（等到埠真的空出來）、`OpenAICompatibleProvider`（本機請求經 gate）。

## 行為細節

- **檢查順序**：Host（`127.0.0.1:<埠>` 或 `localhost:<埠>`，擋 DNS rebinding）→ Origin（有就必須在清單）→ 預檢 → 路由與方法 → 讀 body 前驗金鑰。
- **路由**：`GET /health`（代理自己回）、`GET /v1/models`（不經 gate）、`POST /v1/chat/completions`、`POST /v1/completions`。其他一律 404。
- **轉送**：上游只帶內部金鑰與 `Content-Type`；客戶端的金鑰、Origin、cookie 不轉送。第一個 body 位元組送出前都算「尚未回應」，被搶占就重送；之後被搶占則送出 `preempted_by_lint` 錯誤事件、不送結尾 chunk。
- **限制**：排隊上限 8、累計等候 120 秒、同一請求最多被搶占 5 次、32 條連線、標頭 16 KiB、body 4 MiB。
- **允許清單**：預設 `http://localhost:*`、`http://127.0.0.1:*`、`https://localhost:*`；使用者只能加 `https://` 網站。
- **日誌**：只記方法、路徑、狀態、耗時、搶占與重送次數；被拒絕的請求與 `/v1/models` 每 60 秒彙總一次；不記 body、金鑰、Origin。

## 實測數據（2026-10-24）

| 項目 | 結果 |
|---|---|
| 客戶端斷線 | llama-server 取消工作：400 token 任務在 2 秒時斷線，下一個請求 0.17–0.19 秒完成（串流與非串流皆是） |
| 處理 prompt 時斷線 | 6271 token 的 prompt（完整約 8.3 秒）途中斷線，下一個請求 0.66 秒完成 → 搶占最壞約 0.7 秒 |
| 不搶占時排隊 | 外部 300 token 任務進行中，短請求等了 8.8 秒 |
| 健康檢查 | 生成中 `/v1/models`、`/props` 約 1 ms 回應 |
| 外部擠掉 Lint 的 prompt | 約 1070 token 的 prompt 重算約 1.4 秒；`--cache-ram 128` 有時能還原；打字開始時的暖機會把它放回 |
| b11046 旗標 | `--api-key-file /dev/stdin` 可用；Bearer 與 `X-Api-Key` 都接受；有金鑰時 `/v1/models`、`/props` 回 401、`/health` 公開；`--alias` 讓 `/v1/models` 不再露出模型路徑；`--cors-origins http://lint.invalid` 讓其他網站讀不到回應 |
| Chrome 155 | 公開網站打 `127.0.0.1` 沒有權限提示或私有網路阻擋；新來源的第一個請求多等約 2 秒；曾有兩次第一個請求卡住 20 秒、原因不明、之後未重現 |
| 實機：Lint 優先 | 外部 400 token 任務進行中按 ⌥⌘K：建議 0.4／1.3 秒（閒置 0.6／0.3 秒）；外部請求被中斷 3 次、自動重送 3 次，最後拿到完整回答 |
| 實機：瀏覽器（錯的金鑰，讀得到 401 即代表放行） | Chrome、Brave 156、Safari 27：這台 Mac 的網頁（`http://localhost`）可用，預檢通過；直連 llama-server 一律被擋；不在清單的 https 網站被擋。加入清單的 https 網站：Chrome、Brave 可用；**Safari 不行**，它不讓 https 網頁連到這台 Mac 的任何 http 位址（混合內容；對照用的 `no-cors` 請求一樣失敗） |

## 已知取捨

- 使用者持續打字時，外部請求會一直被延後，最後回 `lint_busy`。
- 外部用過模型後，Lint 的下一個請求可能要重算 prompt（約 1.4 秒），打字時的暖機會先處理掉大部分。
- 從舊版升級後，直接打 `:8000` 的腳本會收到 401，要改用 API 埠與金鑰；用「OpenAI 相容端點」指向 Lint 自己 `:8000` 的設定也一樣。
- 自訂 `llama-server` 只會加上金鑰參數，不加 CORS 參數（舊版可能不認得，會無法啟動）。
- Safari 只能讓這台 Mac 上的網頁使用；加入清單的 https 網站在 Safari 用不了（瀏覽器限制，不是 Lint）。要支援，API 埠得改用本機信任的 https 憑證，目前不做。
