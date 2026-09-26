# Security

## Reporting a vulnerability

Report vulnerabilities through [GitHub Security Advisories](https://github.com/davislinyd/Lint/security/advisories/new) for this repository. There is no bug-bounty program.

請透過這個 repository 的 [GitHub Security Advisories](https://github.com/davislinyd/Lint/security/advisories/new) 回報漏洞。沒有漏洞獎金。

## What Lint can read

Lint uses Accessibility to read text in the app you are using: the selection, and the focused field only when live check is on. Live check is off by default. Secure fields are skipped. Password managers (1Password, Bitwarden, KeePassXC) and the system Passwords and Keychain Access apps are not read. A banking page open in a browser is not on that list. Text you ask Lint to check goes to the model you chose. A local model stays on this Mac. A cloud provider receives what you send. With live check off, Lint does not watch the focused field and does not send it.

Lint 用輔助功能讀取你正在使用的 App 裡的文字：選取範圍，以及只有打開即時檢查時才讀焦點欄位。即時檢查預設關閉。安全輸入框會略過。密碼管理器（1Password、Bitwarden、KeePassXC）以及系統的「密碼」與「鑰匙圈存取」不會被讀取。開在瀏覽器裡的網頁銀行不在這份名單上。你要求檢查的文字會送到你選的模型。本機模型留在這台 Mac。雲端 provider 會收到你送出的內容。即時檢查關閉時，Lint 不會監看焦點欄位，也不會把它送出去。
