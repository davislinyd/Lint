# Lint

[English](#english) | [繁體中文](#繁體中文)

---

## English

A macOS menu-bar AI writing assistant. Press a global hotkey to capture the selected text, send it to an LLM, compare the suggestion in a floating panel, then replace or copy it.

### Requirements

- macOS 14+
- Xcode / Swift 6.1+ toolchain
- An LLM backend: an OpenAI-compatible endpoint (default `http://127.0.0.1:8000/v1`, e.g. `llama-server`, Ollama, LM Studio), or OpenAI / Anthropic / Gemini

### Run

```sh
# Optional: store the API key in Keychain (reads the gitignored .env.local)
# .env.local content: LINT_API_KEY=...
chmod +x Scripts/*.sh
./Scripts/seed-keychain.sh
./Scripts/run-dev.sh
```

A pencil icon appears in the menu bar.

| Hotkey | Action |
|--------|--------|
| `⌥⌘K` | Compact suggestion bubble |
| `⌥⌘L` | Full two-column panel |

Hotkeys can be rebound in Settings.

### How it reads text

- **Live check:** while you type, Lint watches the focused field (English-leaning text) and prepares a suggestion in the background, so `⌥⌘K` shows it right away. With a local model, it is also warmed up as soon as you start typing.
- **Any app:** native apps are read through Accessibility. For Chromium / Electron apps (browsers, Slack, SeaTalk, ChatGPT, …) Lint switches on their accessibility tree automatically.
- **Fallback:** if a field exposes no text, `⌥⌘K` selects the field (⌘A), copies it, then restores the clipboard and the caret.
- **Fullscreen:** the bubble opens on the Space you are working in, including fullscreen apps.

### Permissions

System Settings → Privacy & Security → Accessibility → enable **Lint**.

Without permission the app still works, but falls back to simulated ⌘C / ⌘V through the clipboard. Run the signed `dist/Lint.app`; a bare binary does not reliably show up in the Accessibility list. If the system treats a rebuilt app as new, grant the permission again. Use a stable code-signing identity (e.g. Apple Development) to avoid this.

### Settings

- Providers: local llama.cpp (managed by Lint), OpenAI, OpenAI-compatible endpoint (Ollama / LM Studio / custom), Anthropic, Gemini
- API keys are stored in Keychain (service `app.lint.assistant`)
- Default endpoint: `http://127.0.0.1:8000/v1`
- Ollama: `http://127.0.0.1:11434/v1`; LM Studio: `http://127.0.0.1:1234/v1`
- Local llama.cpp: pick it as the source in Settings → Model to manage `llama-server` (start / stop / restart, model, port) on the same page

### Writing modes

Proofreading and polishing, formal / concise / professional tone, translation, custom prompt.

### Test

```sh
swift test
```

### License

[MIT](./LICENSE)

---

## 繁體中文

macOS 選單列 AI 寫作助手：全域快捷鍵擷取選取文字，送到 LLM，在浮動面板對比後覆蓋或複製。

### 需求

- macOS 14+
- Xcode / Swift 6.1+ 工具鏈
- LLM 後端：OpenAI 相容 API（預設 `http://127.0.0.1:8000/v1`，例如 `llama-server`、Ollama、LM Studio），或 OpenAI / Anthropic / Gemini

### 啟動

```sh
# 可選：把 API Key 寫進 Keychain（讀取 gitignored 的 .env.local）
# .env.local 內容：LINT_API_KEY=...
chmod +x Scripts/*.sh
./Scripts/seed-keychain.sh
./Scripts/run-dev.sh
```

選單列會出現鉛筆圖示。

| 快捷鍵 | 行為 |
|--------|------|
| `⌥⌘K` | 迷你建議浮窗 |
| `⌥⌘L` | 雙欄全面板 |

快捷鍵可在設定中重新綁定。

### 如何讀取文字

- **即時檢查：** 打字時 Lint 會監看目前輸入框（以英文為主的文字），在背景先準備好建議，按 `⌥⌘K` 即可立刻顯示；使用本機模型時，開始打字就會先暖機。
- **任何 App：** 原生 App 透過輔助功能讀取；Chromium／Electron 系 App（瀏覽器、Slack、SeaTalk、ChatGPT 等）由 Lint 自動開啟其輔助功能樹。
- **後備：** 輸入框讀不到文字時，`⌥⌘K` 會全選（⌘A）並複製，再還原剪貼簿與游標位置。
- **全螢幕：** 浮窗會出現在你正在使用的 Space，包含全螢幕 App。

### 權限

系統設定 → 隱私權與安全性 → 輔助功能 → 勾選 **Lint**。

未授權時仍可運作，但改走模擬 ⌘C／⌘V 的剪貼簿備援。必須執行簽名過的 `dist/Lint.app`，裸 binary 不會穩定出現在輔助功能列表。重新組包後若系統視為新 App，需再勾選一次；使用固定的程式碼簽署憑證（如 Apple Development）可避免。

### 設定

- Provider：本機 llama.cpp（由 Lint 管理）、OpenAI、OpenAI 相容端點（Ollama / LM Studio / 自訂）、Anthropic、Gemini
- API Key 存在 Keychain（service `app.lint.assistant`）
- 預設 Endpoint：`http://127.0.0.1:8000/v1`
- Ollama：`http://127.0.0.1:11434/v1`；LM Studio：`http://127.0.0.1:1234/v1`
- 本機 llama.cpp：在「設定 → 模型」選擇該來源，即可在同頁管理 `llama-server`（啟動／停止／重啟、模型、埠）

### 寫作模式

文法校對與潤飾、正式／簡潔／專業語氣、翻譯、自訂 Prompt。

### 測試

```sh
swift test
```

### 授權

[MIT](./LICENSE)
