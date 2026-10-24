# Security

## Reporting a vulnerability

Report vulnerabilities through [GitHub Security Advisories](https://github.com/davislinyd/Lint/security/advisories/new) for this repository. There is no bug-bounty program.

請透過這個 repository 的 [GitHub Security Advisories](https://github.com/davislinyd/Lint/security/advisories/new) 回報漏洞。沒有漏洞獎金。

## What Lint can read

Lint uses Accessibility to read text in the app you are using. With the default settings:

- When you select text (8 characters or more), Lint prepares a suggestion for it in the background.
- Live check reads the focused field while you type and, for mostly-English text, prepares a suggestion in the background after a short pause.
- `⌥⌘K` reads the focused field and checks the selection in it or the paragraph at the caret. If the field exposes no text, it selects and copies the whole field. `⌥⌘L` reads the selection, copying it with ⌘C when Accessibility cannot read it.

Both background watches can be turned off in Settings → General; the hotkeys keep working. Secure fields are skipped. Password managers (1Password, Bitwarden, KeePassXC) and the system Passwords and Keychain Access apps are not read. A banking page open in a browser is not on that list. Text that is checked, including text prepared in the background, goes to the model you chose. A local model keeps it on this Mac. A model that runs anywhere else receives it.

**Observation mode** (Settings → Memory; off by default, and it needs Memory to be on): after Lint has made a suggestion in a field, it keeps reading that one field every 100 ms until its text is sent (the field empties), the field goes away, Lint makes a suggestion in another field, or nothing has changed in it for 10 minutes. It does this to learn whether the suggestion was used and which of its changes you did not want. What it reads is compared in RAM and dropped when it stops following the field; it is never written to disk and never sent to a model. What is kept, in `LintLearning.sqlite`: for each app, under its bundle ID, a count of how often a suggestion was used or not, which fades with time; four more such counts, of how often you kept your own way of writing where a suggestion would have changed it (contractions, a period at the end, a capital at the start); for each app and tone, a count of the suggestions in that tone that were used there, and what was learned from these counts per app (the bundle ID, whether suggestions are still prepared there on their own, and the name of a tone); for a suggestion that was opened and not used, or written and then edited in the field, an event of keyed hashes without any text; and memories of the same kind as the others, a word or short phrase to leave alone, which you can read and delete under Manage Memories. Only proofreading suggestions are followed, and secure fields and the apps listed above are never read. Turning the mode off stops the reading at once, and Reset Memory Database deletes the counts.

Lint 用輔助功能讀取你正在使用的 App 裡的文字。預設設定下：

- 你選取文字（8 個字以上）時，Lint 會在背景先為它準備建議。
- 即時檢查會在你打字時讀取焦點欄位；以英文為主的文字，停頓片刻後會在背景準備建議。
- `⌥⌘K` 會讀焦點欄位，檢查其中的選取或游標所在的段落。欄位讀不到文字時，會全選並複製整個欄位。`⌥⌘L` 讀取選取範圍，輔助功能讀不到時用 ⌘C 複製。

兩種背景監看都可以在「設定 → 一般」關閉，快捷鍵照常可用。安全輸入框會略過。密碼管理器（1Password、Bitwarden、KeePassXC）以及系統的「密碼」與「鑰匙圈存取」不會被讀取。開在瀏覽器裡的網頁銀行不在這份名單上。被檢查的文字，包含在背景準備的，會送到你選的模型。本機模型讓文字留在這台 Mac；在其他地方執行的模型會收到這些文字。

**觀察模式**（「設定 → 記憶」；預設關閉，且需先啟用記憶）：Lint 在某個輸入框給過建議後，會每 100 毫秒繼續讀取那一個輸入框，直到文字送出（輸入框清空）、輸入框消失、Lint 在另一個輸入框給了建議，或 10 分鐘沒有變動為止，用來了解建議有沒有被採用、哪些改動你不想要。讀到的文字只在記憶體裡比對，停止追蹤時就丟棄；不會寫入磁碟，也不會送給模型。保存在 `LintLearning.sqlite` 的只有：各 App（以 bundle ID 為鍵）採用與未採用建議的次數，會隨時間淡出；另外四個同樣的計數，記錄建議想改而你保留自己寫法的次數（縮寫、結尾句點、開頭大小寫）；各 App 各語氣被採用的建議次數，以及由這些次數學到的各 App 調整（bundle ID、是否還自動準備建議、一個語氣名稱）；「打開後沒有採用」或「取代後又在輸入框裡修改」的建議的帶金鑰雜湊事件，不含任何文字；以及和其他記憶同一種的記憶（要保留的一個字或一小段詞組），可在「管理記憶」查看並刪除。只追蹤校對的建議；安全輸入框與上面列出的 App 一律不讀。關閉觀察模式會立刻停止讀取，「重設記憶資料庫」會刪除這些次數。

## Update checks

Lint asks the GitHub API for the latest release, every week by default or when you choose **Check for Updates…**; none of your text is sent. An update is installed only if the downloaded DMG matches the published SHA-256 and the app inside it is Lint (`app.lint.assistant`) signed with Lint's Developer ID (team `N964GDJY6A`) and Hardened Runtime. Settings → General → Updates can be set to only check.

Lint 會向 GitHub API 查詢最新的正式版，預設每週一次，或在你按「檢查更新…」時查詢，不會送出你的任何文字。只有在下載的 DMG 符合公布的 SHA-256，而且裡面的 App 是以 Lint 的 Developer ID（team `N964GDJY6A`）簽署、啟用 Hardened Runtime 的 Lint（`app.lint.assistant`）時，才會安裝更新。「設定 → 一般 → 更新」可以設成只檢查。

## Local model

Lint's own llama-server listens only on `127.0.0.1` and only answers Lint: it is started with a random key that Lint makes each time it starts, passes on standard input and never shows or logs, and it sends no CORS headers that would let a web page read its answers. Settings → Model → **Other Apps** (off by default) opens a second port, also on `127.0.0.1` only, for other apps and web pages on this Mac. It needs its own key (kept in the Keychain), accepts only `Host: 127.0.0.1` or `localhost`, lets a web page in only if its site is on the allowed list (pages on this Mac by default), and passes on only the OpenAI chat, completion and model-list requests. The diagnostic log records only counts, status codes and times for these requests, never their text, their keys or the sites that sent them.

Lint 自己的 llama-server 只監聽 `127.0.0.1`，而且只回應 Lint：啟動時帶著 Lint 每次開啟時產生的隨機金鑰，經由標準輸入傳入，從不顯示或寫進記錄；它也不送出會讓網頁讀到回應的 CORS 標頭。「設定 → 模型 → **其他 app 使用**」（預設關閉）會為這台 Mac 上的其他 app 與網頁開第二個埠，同樣只監聽 `127.0.0.1`。它需要自己的金鑰（存在鑰匙圈）、只接受 `Host: 127.0.0.1` 或 `localhost`、只讓允許清單上的網站的網頁使用（預設是這台 Mac 上的網頁），而且只轉送 OpenAI 的對話、補全與模型清單請求。診斷記錄對這些請求只記次數、狀態碼與時間，不記內容、金鑰，也不記是哪個網站送來的。

## Diagnostic log

Lint keeps a log of what it did and how it went in `~/Library/Logs/Lint/lint.log`: captures and replaces, requests to the model (engine, model, character counts, time taken, the output check's verdict), the local server and errors, with app names, error codes and counts. It never contains the text you check, the model's answers or your memories. The log stays on this Mac and Lint never sends it; you can read, copy or clear it in Settings → Diagnostics. When the file reaches 1 MB it becomes `lint.1.log` and a new one starts, so at most two files, about 2 MB, are kept.

Lint 會在 `~/Library/Logs/Lint/lint.log` 記錄它做了什麼、結果如何：擷取與取代、模型請求（引擎、模型、字數、耗時、輸出檢查的結果）、本機伺服器與錯誤，內容是 App 名稱、錯誤碼與數字。記錄裡絕不會有你檢查的文字、模型的回答或你的記憶。記錄只存在這台 Mac，Lint 不會送出；可以在「設定 → 診斷」查看、拷貝或清除。檔案滿 1 MB 會改名為 `lint.1.log` 並開始新檔，所以最多保留兩個檔案，約 2 MB。
