# Lint

[English](#english) | [繁體中文](#繁體中文)

---

## English

A macOS menu-bar AI writing assistant. Press a global hotkey to capture the selected text, send it to an LLM, compare the suggestion in a floating panel, then replace or copy it.

### Download

Get the latest `Lint-<version>-macOS-arm64.dmg` from [GitHub Releases](https://github.com/davislinyd/Lint/releases). Official releases are signed with a Developer ID certificate and notarized by Apple. They need macOS 14+ on an Apple Silicon Mac.

> **Preview builds:** until the first notarized release, Releases carries unsigned previews (`Lint-<version>-macOS-arm64-preview.dmg`, marked Pre-release). macOS blocks a preview the first time you open it: go to System Settings → Privacy & Security and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Lint.app`. Allow Accessibility again after installing each new preview.

1. Open the DMG and drag **Lint** into **Applications**.
2. Launch Lint from Applications. A pencil icon appears in the menu bar.
3. Enable **Lint** under System Settings → Privacy & Security → Accessibility.
4. Optional: verify the download with `shasum -a 256 -c Lint-<version>-macOS-arm64.dmg.sha256`, run in the folder that holds both files.

While replacing text, macOS may ask whether Lint may control "System Events". Allow it: Lint uses it only to bring your previous app back to the front, which makes Replace reliable in browsers and Electron apps.

The DMG contains Lint only, not a model. To run a model on your Mac, choose **Local llama.cpp** in Settings → Model: Lint asks before it installs `llama.cpp` with Homebrew (Homebrew must already be installed), and `llama-server` downloads the model on first use. You can also point Lint at an OpenAI-compatible endpoint or a cloud provider.

To build from source instead, see Requirements and Run below.

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

### Learning and privacy (optional, off by default)

With **Settings → Learning** turned on, Lint notices writing habits you keep correcting (a word you often misspell, an article you often drop) and remembers them as short rules. While it is off, Lint behaves exactly as before. The few memories that fit what you are writing (at most five short lines) are added to the end of the prompt sent to your model; with a local model that stays on your Mac.

- Everything stays on your Mac, in `~/Library/Application Support/Lint/LintLearning.sqlite` (readable only by you).
- Only abstracted rules are kept: a word, a short phrase or a template sentence, never the text around it. Numbers, addresses, paths, acronyms and capitalised names are left out. Lint cannot recognise Chinese names or names typed in lowercase, so a name you corrected can still end up in a memory; you can read and delete every memory under Settings → Learning → Manage Memories.
- What you did with a suggestion (replace, copy, rewrite) is logged as keyed hashes, not text; the key is in the Keychain.
- Memories fade when the pattern stops showing up: after a month without it the evidence halves every three months (every six for a general rule, every year for a core one), so a memory first drops out of the prompt and is eventually archived (never deleted). Pinned and disabled memories do not fade, and Enable brings an archived one back.
- **Memory organization** (Settings → Learning → Memory Organization): when several memories of one kind pile up, Lint can sum them up in one general rule (for now: a preposition you keep deleting after different verbs, such as "discuss about" and "mention about"). The rule is worded from a fixed template, so it never contains a word you wrote. The memories behind it are kept: they are marked as covered and left out of the prompt while the rule is in use, and they come back on their own once the rule fades, is disabled or is deleted; one whose own words are in your text still speaks for itself. Pinned, disabled and hand-edited memories are never combined, a rule you delete is not made again, and a rule that keeps proving itself for weeks becomes a core memory. It runs only on this Mac (no cloud, no model download), waits until you are not waiting on a suggestion, and starts by itself a minute after start-up (once a day), after enough new learning, or when you press Organize Memories Now.
- Under Settings → Learning → Manage Memories you can read, reword, pin, disable or delete every memory, see whether it is specific, general or core and which memories a rule was derived from, clear them all, or reset the whole database.

### Test

```sh
swift test
```

### License

[MIT](./LICENSE)

---

## 繁體中文

macOS 選單列 AI 寫作助手：全域快捷鍵擷取選取文字，送到 LLM，在浮動面板對比後覆蓋或複製。

### 下載

到 [GitHub Releases](https://github.com/davislinyd/Lint/releases) 下載最新的 `Lint-<版本>-macOS-arm64.dmg`。正式版以 Developer ID 憑證簽署並通過 Apple 公證，需要 macOS 14+ 與 Apple Silicon Mac。

> **預覽版：** 第一個公證版發佈之前，Releases 提供未簽章的預覽版（`Lint-<版本>-macOS-arm64-preview.dmg`，標示為 Pre-release）。第一次開啟時 macOS 會擋下：到 系統設定 → 隱私權與安全性 按「仍要打開」，或執行 `xattr -dr com.apple.quarantine /Applications/Lint.app`。每安裝一個新的預覽版，輔助功能都要重新允許。

1. 開啟 DMG，把 **Lint** 拖進 **Applications**。
2. 從「應用程式」開啟 Lint，選單列會出現鉛筆圖示。
3. 到 系統設定 → 隱私權與安全性 → 輔助功能，勾選 **Lint**。
4. 選用：在放有 DMG 與 `.sha256` 的資料夾執行 `shasum -a 256 -c Lint-<版本>-macOS-arm64.dmg.sha256` 驗證下載。

取代文字時，macOS 可能會詢問是否允許 Lint 控制「系統事件」。請允許：Lint 只用它把你原本使用的 App 帶回最前面，這樣在瀏覽器與 Electron App 裡取代才會穩定。

DMG 只含 Lint，不含模型。要在自己的 Mac 上跑模型，請在「設定 → 模型」選「本機 llama.cpp」：Lint 會先詢問，再用 Homebrew 安裝 `llama.cpp`（需已安裝 Homebrew），`llama-server` 會在第一次使用時下載模型。也可以改連 OpenAI 相容端點或雲端 provider。

要從原始碼建置，見下方「需求」與「啟動」。

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

### 學習與隱私（選用，預設關閉）

在「設定 → 學習」開啟後，Lint 會留意你反覆修正的寫作習慣（常拼錯的字、常漏掉的冠詞），記成簡短的規則。關閉時，Lint 的行為與以前完全相同。符合你正在寫的內容的少數記憶（最多五行短句）會加在送給模型的 prompt 結尾；使用本機模型時，這些都留在你的 Mac 上。

- 全部只存在你的 Mac：`~/Library/Application Support/Lint/LintLearning.sqlite`（僅你本人可讀）。
- 只保存抽象後的規則（一個字、一小段詞組或模板句），不保存周圍的文字。數字、網址、路徑、縮寫與大寫開頭的人名不會被記下。Lint 認不出中文人名或全小寫的英文名，被你修正過的名字仍可能進入記憶；可在「設定 → 學習 → 管理記憶」查看並刪除。
- 你對建議做了什麼（取代、複製、重寫）只以帶金鑰的雜湊記錄，不含文字；金鑰放在鑰匙圈。
- 太久沒再出現的記憶會淡出：超過一個月沒出現後，證據每三個月減半（一般規則每六個月、核心記憶每一年），先退出 prompt，最後被封存（不會刪除）。已釘選與已停用的記憶不會淡出，按「啟用」可把封存的記憶還原。
- **記憶整理**（「設定 → 學習 → 記憶整理」）：同一類的記憶累積多條時，Lint 可以把它們歸納成一條一般規則（目前只處理：你在不同動詞後反覆刪掉的介系詞，例如「discuss about」與「mention about」）。規則由固定模板寫成，不會含有任何你寫過的字。被歸納的記憶都會保留：規則使用中時它們標示為「已由一般規則涵蓋」並暫時不進 prompt，規則淡出、停用或被刪除後就自動恢復；文字裡出現它自己那個字時，它仍會單獨提醒。已釘選、已停用與你手動改寫過的記憶不會被歸納，你刪掉的規則不會再被重新產生，持續數週都證明有用的規則會升為核心記憶。整理只在這台 Mac 上進行（不連雲端、不下載模型），會等到你不在等建議時才開始，並在啟動後一分鐘（每天一次）、累積足夠新學習後自動進行，也可按「立即整理記憶」。
- 在「設定 → 學習 → 管理記憶」可以查看、改寫、釘選、停用或刪除每一條記憶，看到它是具體、一般還是核心、規則由哪些記憶歸納而來，也能全部清除或重設整個資料庫。

### 測試

```sh
swift test
```

### 授權

[MIT](./LICENSE)
