# 發版流程（維護者）

推送 `vX.Y.Z` tag 後，GitHub Actions（[`.github/workflows/release.yml`](../.github/workflows/release.yml)）會自動：驗證 tag → 跑測試 → 建置 → Developer ID 簽章（Hardened Runtime + 安全時間戳）→ 簽 DMG → Apple 公證 → staple → 驗證 → SHA-256 → 建立 **Draft** GitHub Release。使用者只需要從 Releases 下載 DMG。

[`Scripts/release.sh`](../Scripts/release.sh) 是同一條流程的腳本，也能在本機 Mac 上跑（它不會建立 GitHub Release）。

## 前置條件

- **付費的 Apple Developer Program**：Developer ID 憑證與 Team API Key 都需要。
- 一台 Mac：產生 CSR，憑證的私鑰會留在這台 Mac 的鑰匙圈裡。

## 一次性設定

### 1. Developer ID Application 憑證 → `.p12`

1. 鑰匙圈存取 → 憑證輔助程式 → 向憑證授權機構要求憑證…，選「儲存到磁碟」，得到 `.certSigningRequest`。
2. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) → Certificates → **+** → Developer ID → **Developer ID Application**（需要 Account Holder），上傳 CSR，下載 `.cer` 並雙擊安裝。
3. 鑰匙圈存取 → 我的憑證：展開 `Developer ID Application: …`，確認底下有私鑰；選取它並「輸出」成 `DeveloperID.p12`，設一組強密碼。

### 2. App Store Connect Team API Key → `.p8`

App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys** → 新增，Access 選 **Developer**。記下 **Key ID** 與 **Issuer ID**，下載 `AuthKey_XXXXXXXXXX.p8`（**只能下載一次**）。

要用 Team key（不綁個人帳號）。Developer ID 私鑰（給 `codesign`）與 API key（給 `notarytool`）是兩套獨立的憑證，分開存放，日後撤銷、輪替與除錯都比較清楚。

### 3. GitHub Environment 與 secrets

1. Settings → Environments → **New environment**，名稱 `release`。
2. 該環境的 **Deployment branches and tags** 選 *Selected branches and tags*，加入 branch `main` 與 tag `v*.*.*`（可再加 Required reviewers，讓每次發版都要你按核准）。
3. 在 `release` 環境加入下列 6 個 secrets。用管線把檔案直接送進 `gh`，值不會出現在 shell 歷史或剪貼簿：

```sh
base64 -i DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_P12_BASE64 --env release --repo davislinyd/Lint
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set APPLE_API_KEY_P8_BASE64 --env release --repo davislinyd/Lint
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD --env release --repo davislinyd/Lint   # 互動輸入
gh secret set APPLE_TEAM_ID --env release --repo davislinyd/Lint
gh secret set APPLE_API_KEY_ID --env release --repo davislinyd/Lint
gh secret set APPLE_API_ISSUER_ID --env release --repo davislinyd/Lint
```

| Secret | 內容 |
|--------|------|
| `APPLE_DEVELOPER_ID_P12_BASE64` | `DeveloperID.p12` 的 Base64（憑證 + 私鑰） |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | 匯出 `.p12` 時設的密碼 |
| `APPLE_TEAM_ID` | Apple Developer 帳號的 Team ID（10 碼）；簽章的 `TeamIdentifier` 必須與它相同 |
| `APPLE_API_KEY_ID` | Team API Key 的 Key ID |
| `APPLE_API_ISSUER_ID` | Issuer ID（UUID） |
| `APPLE_API_KEY_P8_BASE64` | `AuthKey_XXXXXXXXXX.p8` 的 Base64 |

設好後把本機的 `.p12` / `.p8` 收進密碼管理器或刪除。它們不能進 repo、issue 或聊天。

## 發版

1. `Resources/Info.plist` 的 `CFBundleShortVersionString` 是唯一的版本來源；確認它就是要發的版本，並已合併進 `main`。
2. 在 `main` 上打 tag 並推送：

```sh
git switch main && git pull
git tag -a v0.2.0 -m "Lint v0.2.0"
git push origin v0.2.0
```

   tag 必須是 `vMAJOR.MINOR.PATCH`、與 Info.plist 版本相同、指向 `main` 上的 commit，否則 workflow 會在載入任何金鑰之前就失敗。沒有 `v` 前綴的 tag（例如早期本機的 `0.2.0`）不會觸發 workflow。
3. Actions → **Release** 跑完後，Releases 頁會出現 **Draft**，內含 `Lint-<版本>-macOS-arm64.dmg` 與 `.sha256`。`CFBundleVersion` 會是這次 run 的編號。
4. 在**另一台 Mac** 下載並測試：開啟 DMG、拖進 Applications、啟動、輔助功能授權、LLM、Learning 資料庫。
5. 沒問題就在 GitHub 上按 **Publish release**。等流程穩定幾次之後，才考慮把 workflow 的 `--draft` 拿掉。

重跑：Actions → Release → *Run workflow* → 輸入既有的 tag。同一個 tag 若已有 Draft，先刪掉它（`gh release create` 不會覆蓋）。

## 本機演練（不送 Apple）

```sh
LINT_SKIP_NOTARIZE=1 ./Scripts/release.sh
```

需要本機鑰匙圈有 Developer ID Application 憑證。產物在 `dist/release/`，檔名帶 `-unnotarized`，不能發佈。要在本機真的公證，改設 `APPLE_API_KEY_PATH`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`（不設 `LINT_SKIP_NOTARIZE`）。

日常開發與本機安裝不受影響：`./Scripts/package-app.sh`（含 `release` 引數）照舊用 Apple Development 憑證簽章；只有 `LINT_RELEASE_BUILD=1` 才走嚴格的 Developer ID 路徑。

## 流程檢查了什麼

- 工作流程：tag 格式、tag 存在且就是 checkout 的 commit、commit 在 `main` 上、tag 版本 = Info.plist 版本、6 個 secrets 都在、`swift test` 通過。
- `release.sh`：只接受**恰好一個** `Developer ID Application` 憑證（不 fallback 到 Apple Development 或 ad-hoc）；簽章有 `runtime` flag、安全時間戳、`app.lint.assistant`、`TeamIdentifier` 符合 `APPLE_TEAM_ID`、entitlements 與 `Resources/Lint.entitlements` 一致且沒有 `get-task-allow`；DMG 只含 `Lint.app` 與 `Applications` 連結、已簽章；公證必須 `Accepted`（否則印出 `notarytool log` 並失敗）；`stapler` 附上並驗證票證；`hdiutil verify`；掛載最終 DMG 對裡面的 app 做 `codesign` 與 `spctl` 驗證；產出並自我驗證 SHA-256。

## 疑難排解

| 症狀 | 原因與處理 |
|------|-----------|
| `Version mismatch` | tag 與 Info.plist 版本不同；改 Info.plist 或換 tag |
| `not reachable from main` | 先把該 commit 合併進 `main` 再打 tag |
| `secret … is missing or empty` | `release` 環境缺 secret（名稱見上表），或 workflow 沒有進到 `release` 環境（檢查 Deployment branches and tags） |
| `no valid 'Developer ID Application' code signing identity` | `.p12` 沒包含私鑰、憑證過期或被撤銷、密碼錯誤；訊息會列出鑰匙圈裡實際有的憑證 |
| `notarization failed … Invalid` | 看 log 裡的 `issues`。常見：缺 Hardened Runtime、沒有安全時間戳、未簽章的可執行檔、`get-task-allow` |
| `notarytool` 回 401 / 403 | Key ID / Issuer ID / `.p8` 不成對，或不是 **Team** key（Access 至少 Developer） |
| `stapler` Error 65 | 公證通過後票證要一點時間才會出現在 Apple 的 CDN；腳本會重試 5 次，仍失敗就重跑 |
| `hdiutil … Resource busy` | Spotlight／XProtect 短暫占用剛掛載的磁碟區；腳本已用分步建立與必要時 `-force` 卸載處理 |

## 憑證輪替

- Developer ID 憑證到期或私鑰外洩：到 Apple Developer 撤銷、重做 CSR → 憑證 → `.p12`，更新 `APPLE_DEVELOPER_ID_P12_BASE64` 與 `APPLE_DEVELOPER_ID_P12_PASSWORD`。
- API Key 外洩：在 App Store Connect 撤銷，建立新的 Team key，更新 `APPLE_API_KEY_ID`、`APPLE_API_KEY_P8_BASE64`（Issuer ID 不變）。

## 已知限制

- 只出 **arm64**；檔名由實際的執行檔架構決定（`lipo -archs`），不會標示成 universal。Universal 2 留待日後。
- 只公證並 staple **DMG**，DMG 裡的 app 本體沒有另外 staple：使用者首次啟動需要能連到 Apple 查詢票證（離線首次啟動可能被 Gatekeeper 擋下）。
- 沒有針對 pull request 的 CI workflow。若日後要加（例如只跑 `swift test`），不可帶任何 release secrets，也不要用 `pull_request_target`。
- 從 Apple Development 版換成 Developer ID 版時，macOS 會視為不同的簽章身分：輔助功能與「系統事件」自動化授權需重新允許一次，鑰匙圈也可能再問一次「永遠允許」。
- macOS 27 的 `hdiutil create` 已標示為 deprecated（仍可用）；日後系統移除時需改用 `diskutil image`。
