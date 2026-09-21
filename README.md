# Lint

[English](#english) | [繁體中文](#繁體中文)

---

## English

A macOS menu-bar AI writing assistant. Press a global hotkey to capture the selected text, send it to an LLM, compare the suggestion in a floating panel, then replace or copy it.

### Install

#### Recommended: the official DMG (no Homebrew)

Get the latest `Lint-<version>-macOS-arm64.dmg` from [GitHub Releases](https://github.com/davislinyd/Lint/releases). Official releases are signed with a Developer ID certificate and notarized by Apple. They need macOS 14+ on an Apple Silicon Mac.

> **Preview builds:** until the first notarized release, Releases carries unsigned previews (`Lint-<version>-macOS-arm64-preview.dmg`, marked Pre-release). macOS blocks a preview the first time you open it: go to System Settings → Privacy & Security and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Lint.app`. Allow Accessibility again after installing each new preview.

1. Open the DMG and drag **Lint** into **Applications**.
2. Launch Lint from Applications. A pencil icon appears in the menu bar and the **Set Up Local AI** window opens.
3. It reports the Local AI runtime as ready, because llama.cpp is already inside Lint. The AI model is the one thing still missing: Lint shows its size (about 4.7 GB) and where it is stored, and starts downloading only after you click **Download and Install**. It shows progress, verifies the download, then starts the local server.
4. Allow **Lint** under System Settings → Privacy & Security → Accessibility (the setup window guides you and updates when it is on).
5. Optional: verify the download with `shasum -a 256 -c Lint-<version>-macOS-arm64.dmg.sha256`, run in the folder that holds both files.

While replacing text, macOS may ask whether Lint may control "System Events". Allow it: Lint uses it only to bring your previous app back to the front, which makes Replace reliable in browsers and Electron apps.

What is inside the app and what is downloaded:

- **Bundled in the official DMG:** a pinned llama.cpp runtime (`llama-server` and its libraries, MIT-licensed, build b11046; its license notices are in the app). It is signed and notarized together with Lint, so nothing executable is downloaded after you install. Runtime updates arrive with Lint updates.
- **Downloaded after you agree:** the GGUF model. It is not in the DMG. It is checked against a pinned SHA-256 and stored under `~/Library/Application Support/Lint/Models`; you can remove it in Settings → Model. The network is only needed for this download.
- **Not needed:** Homebrew, Python, CMake, Ollama, or a llama.cpp of your own.

#### Developer / source install (no Homebrew)

```sh
git clone https://github.com/davislinyd/Lint.git && cd Lint    # or download the ZIP from GitHub and unzip it
./Scripts/install.sh
```

Needs macOS 14+ and Apple's Command Line Tools (`xcode-select --install`; the script tells you if they are missing). Homebrew is **not** required. The script downloads the pinned llama.cpp runtime over HTTPS and verifies its SHA-256, builds Lint in release mode, installs it to `~/Applications/Lint.app` (no `sudo`; `./Scripts/install.sh --system` installs to `/Applications`), and opens it. The same in-app setup then continues with the model download. `./Scripts/install.sh --dry-run` only checks the prerequisites.

A source build is signed with your Apple Development identity if you have one, otherwise ad-hoc. It is not the notarized release, and macOS may ask you to allow Accessibility again after a rebuild.

#### Advanced: your own backend

Settings → Model → Advanced lets you point Lint at another `llama-server` (a Homebrew or self-built one), or at a Hugging Face model that `llama-server` downloads itself (`-hf`). You can also choose an OpenAI-compatible endpoint (Ollama, LM Studio, custom) or a cloud provider as the model source. None of this is needed for the default setup.

### Requirements

- macOS 14+
- To build from source: Apple's Command Line Tools with a Swift 6.1+ toolchain (Xcode also works)
- An LLM backend: by default nothing extra, since Lint bundles llama.cpp and downloads its own model. Alternatively an OpenAI-compatible endpoint (default `http://127.0.0.1:8000/v1`, e.g. `llama-server`, Ollama, LM Studio), or OpenAI / Anthropic / Gemini

### Run

```sh
# Optional: store the API key in Keychain (reads the gitignored .env.local)
# .env.local content: LINT_API_KEY=...
chmod +x Scripts/*.sh
./Scripts/seed-keychain.sh
./Scripts/run-dev.sh
```

A pencil icon appears in the menu bar. Packaging fetches the pinned llama.cpp runtime on first use (`Scripts/fetch-llama-runtime.sh`, hash-verified, cached under `.build/`); to try a development build without touching your real models, set `LINT_APP_SUPPORT_DIR` to another folder.

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
- Local llama.cpp: pick it as the source in Settings → Model. The same page shows the bundled runtime, the model (download / remove / show in Finder) and the server (start / stop / restart, port); Advanced holds the runtime source (automatic or a custom `llama-server`), the model source and extra arguments. The server only listens on `127.0.0.1`.

### Local AI notes

- **Not set up yet:** if you ask for a suggestion before the model is installed, Lint shows "Local AI has not been set up yet" with a **Set Up Local AI** button (and a shortcut to pick another model source) instead of a connection error. The menu-bar item **Set Up Local AI…** reopens the setup window at any time; **Later** on the first-run screen only stops it from opening by itself.
- **Downloads are safe to interrupt:** cancel, lose the connection or even quit Lint, and the partial file stays under `~/Library/Application Support/Lint/Downloads`; downloading again continues from where it stopped. A file that fails its size, GGUF-header or SHA-256 check is deleted and never used, and the model only appears under `Models/` once every file has passed, in one step.
- **Disk space:** before downloading, Lint checks for about 1.2× what is still missing and tells you how much it needs and how much the Mac has.
- **Slow first start:** loading a 4–5 GB model can take minutes on a Mac that is short of memory. Lint waits up to 10 minutes and, if the server is still loading, leaves it running instead of starting over. If it fails, Settings → Model → Details shows the last lines it printed.
- **Upgrading:** a model that is already in the Hugging Face cache (from `llama-server -hf`) keeps being used, so nothing is downloaded twice. The old Homebrew `llama-server` paths in Settings switch to the built-in runtime; a path you chose yourself stays as a custom runtime.

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

Downloading a model is never done by the tests. `LINT_LIVE_DOWNLOAD=1 swift test --filter LiveModelDownloadTests` additionally downloads a 1.2 MB public file from Hugging Face to check redirects and resume against the real service.

### License

[MIT](./LICENSE). The bundled llama.cpp runtime is MIT-licensed as well; its license files are inside the app (`Contents/Resources/LlamaRuntime/<arch>/licenses`, also reachable from Settings → About).

---

## 繁體中文

macOS 選單列 AI 寫作助手：全域快捷鍵擷取選取文字，送到 LLM，在浮動面板對比後覆蓋或複製。

### 安裝

#### 建議：官方 DMG（不需要 Homebrew）

到 [GitHub Releases](https://github.com/davislinyd/Lint/releases) 下載最新的 `Lint-<版本>-macOS-arm64.dmg`。正式版以 Developer ID 憑證簽署並通過 Apple 公證，需要 macOS 14+ 與 Apple Silicon Mac。

> **預覽版：** 第一個公證版發佈之前，Releases 提供未簽章的預覽版（`Lint-<版本>-macOS-arm64-preview.dmg`，標示為 Pre-release）。第一次開啟時 macOS 會擋下：到 系統設定 → 隱私權與安全性 按「仍要打開」，或執行 `xattr -dr com.apple.quarantine /Applications/Lint.app`。每安裝一個新的預覽版，輔助功能都要重新允許。

1. 開啟 DMG，把 **Lint** 拖進 **Applications**。
2. 從「應用程式」開啟 Lint，選單列會出現鉛筆圖示，並開啟「設定本機 AI」視窗。
3. 視窗會顯示本機 AI 執行環境已就緒，因為 llama.cpp 已經在 Lint 裡面。還缺的只有 AI 模型：Lint 會列出大小（約 4.7 GB）與存放位置，按下**下載並安裝**之後才開始下載，並顯示進度、驗證檔案，再啟動本機服務。
4. 到 系統設定 → 隱私權與安全性 → 輔助功能，勾選 **Lint**（設定視窗會引導，開啟後自動更新）。
5. 選用：在放有 DMG 與 `.sha256` 的資料夾執行 `shasum -a 256 -c Lint-<版本>-macOS-arm64.dmg.sha256` 驗證下載。

取代文字時，macOS 可能會詢問是否允許 Lint 控制「系統事件」。請允許：Lint 只用它把你原本使用的 App 帶回最前面，這樣在瀏覽器與 Electron App 裡取代才會穩定。

App 裡有什麼、之後才下載什麼：

- **官方 DMG 內建：**固定版本的 llama.cpp 執行環境（`llama-server` 與其函式庫，MIT 授權，build b11046；授權文件在 App 內）。它和 Lint 一起簽署並公證，所以安裝之後不會再下載任何可執行檔。執行環境隨 Lint 更新一起更新。
- **同意後才下載：**GGUF 模型。它不在 DMG 裡，下載後會以固定的 SHA-256 驗證，存放在 `~/Library/Application Support/Lint/Models`，可在「設定 → 模型」移除。只有這一步需要網路。
- **不需要：**Homebrew、Python、CMake、Ollama，或自行安裝的 llama.cpp。

#### 開發者／從原始碼安裝（不需要 Homebrew）

```sh
git clone https://github.com/davislinyd/Lint.git && cd Lint    # 或從 GitHub 下載 ZIP 並解壓縮
./Scripts/install.sh
```

需要 macOS 14+ 與 Apple 的 Command Line Tools（`xcode-select --install`，缺少時腳本會告訴你）。**不需要** Homebrew。腳本會以 HTTPS 下載固定版本的 llama.cpp 執行環境並驗證 SHA-256、以 release 模式建置 Lint、安裝到 `~/Applications/Lint.app`（不需要 `sudo`；`./Scripts/install.sh --system` 則安裝到 `/Applications`），然後開啟它。接著由 App 內的同一套設定畫面繼續下載模型。`./Scripts/install.sh --dry-run` 只檢查前置條件。

原始碼建置會用你的 Apple Development 憑證簽署，沒有的話用 ad-hoc。它不是公證過的正式版，重新建置後 macOS 可能要求再次允許輔助功能。

#### 進階：使用自己的後端

「設定 → 模型 → 進階」可以改用另一個 `llama-server`（Homebrew 或自行編譯的版本），或改用由 `llama-server` 自己下載的 Hugging Face 模型（`-hf`）。也可以把 OpenAI 相容端點（Ollama、LM Studio、自訂）或雲端 provider 當作模型來源。預設設定完全用不到這些。

### 需求

- macOS 14+
- 從原始碼建置：Apple 的 Command Line Tools，含 Swift 6.1+ 工具鏈（裝 Xcode 也可以）
- LLM 後端：預設不需要額外安裝，Lint 內建 llama.cpp 並自行下載模型。也可以改用 OpenAI 相容 API（預設 `http://127.0.0.1:8000/v1`，例如 `llama-server`、Ollama、LM Studio），或 OpenAI / Anthropic / Gemini

### 啟動

```sh
# 可選：把 API Key 寫進 Keychain（讀取 gitignored 的 .env.local）
# .env.local 內容：LINT_API_KEY=...
chmod +x Scripts/*.sh
./Scripts/seed-keychain.sh
./Scripts/run-dev.sh
```

選單列會出現鉛筆圖示。組包時第一次會下載固定版本的 llama.cpp 執行環境（`Scripts/fetch-llama-runtime.sh`，驗證雜湊後快取在 `.build/`）；想試用開發版又不動到真正的模型，可把 `LINT_APP_SUPPORT_DIR` 設成別的資料夾。

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
- 本機 llama.cpp：在「設定 → 模型」選擇該來源。同一頁會顯示內建的執行環境、模型（下載／移除／在 Finder 顯示）與服務（啟動／停止／重啟、埠）；「進階」有執行環境來源（自動或自訂 `llama-server`）、模型來源與額外參數。服務只監聽 `127.0.0.1`。

### 本機 AI 補充說明

- **尚未設定：**還沒安裝模型就要求建議時，Lint 會顯示「本機 AI 尚未設定」與「設定本機 AI」按鈕（以及改用其他模型來源的捷徑），而不是連線錯誤。選單列的「設定本機 AI…」可隨時重新開啟設定視窗；首次畫面按「稍後」只是不再自動彈出。
- **下載可以安全中斷：**取消、斷線甚至結束 Lint，已下載的部分都會留在 `~/Library/Application Support/Lint/Downloads`，再次下載會從中斷處接續。大小、GGUF 標頭或 SHA-256 任一項驗證失敗的檔案會被刪除、絕不使用；所有檔案都通過之後，模型才會一次出現在 `Models/`。
- **磁碟空間：**下載前會檢查是否有「還缺的部分 ×1.2」的可用空間，並告訴你需要多少、這台 Mac 有多少。
- **第一次啟動較慢：**在記憶體吃緊的 Mac 上，載入 4–5 GB 的模型可能要數分鐘。Lint 最多等 10 分鐘，若伺服器仍在載入，會讓它繼續跑而不是重來。失敗時，「設定 → 模型 → 詳細資訊」會顯示它最後印出的幾行。
- **升級：**已在 Hugging Face 快取（`llama-server -hf` 下載的）裡的模型會繼續使用，不會重複下載。設定裡舊的 Homebrew `llama-server` 路徑會改為使用內建執行環境；你自己選的路徑則保留為自訂執行環境。

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

測試不會下載模型。`LINT_LIVE_DOWNLOAD=1 swift test --filter LiveModelDownloadTests` 會另外從 Hugging Face 下載一個 1.2 MB 的公開檔案，用真實服務檢查轉址與續傳。

### 授權

[MIT](./LICENSE)。內建的 llama.cpp 執行環境同為 MIT 授權，授權文件在 App 內（`Contents/Resources/LlamaRuntime/<arch>/licenses`，也可從「設定 → 關於」開啟）。
