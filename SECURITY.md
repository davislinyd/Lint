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

Lint 用輔助功能讀取你正在使用的 App 裡的文字。預設設定下：

- 你選取文字（8 個字以上）時，Lint 會在背景先為它準備建議。
- 即時檢查會在你打字時讀取焦點欄位；以英文為主的文字，停頓片刻後會在背景準備建議。
- `⌥⌘K` 會讀焦點欄位，檢查其中的選取或游標所在的段落。欄位讀不到文字時，會全選並複製整個欄位。`⌥⌘L` 讀取選取範圍，輔助功能讀不到時用 ⌘C 複製。

兩種背景監看都可以在「設定 → 一般」關閉，快捷鍵照常可用。安全輸入框會略過。密碼管理器（1Password、Bitwarden、KeePassXC）以及系統的「密碼」與「鑰匙圈存取」不會被讀取。開在瀏覽器裡的網頁銀行不在這份名單上。被檢查的文字，包含在背景準備的，會送到你選的模型。本機模型讓文字留在這台 Mac；在其他地方執行的模型會收到這些文字。

## Update checks

Lint asks the GitHub API for the latest release, every week by default or when you choose **Check for Updates…**; none of your text is sent. An update is installed only if the downloaded DMG matches the published SHA-256 and the app inside it is Lint (`app.lint.assistant`) signed with Lint's Developer ID (team `N964GDJY6A`) and Hardened Runtime. Settings → General → Updates can be set to only check.

Lint 會向 GitHub API 查詢最新的正式版，預設每週一次，或在你按「檢查更新…」時查詢，不會送出你的任何文字。只有在下載的 DMG 符合公布的 SHA-256，而且裡面的 App 是以 Lint 的 Developer ID（team `N964GDJY6A`）簽署、啟用 Hardened Runtime 的 Lint（`app.lint.assistant`）時，才會安裝更新。「設定 → 一般 → 更新」可以設成只檢查。
