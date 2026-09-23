# 發版流程（維護者）

推送 `vX.Y.Z` tag 後，GitHub Actions（[`.github/workflows/release.yml`](../.github/workflows/release.yml)）會自動：驗證 tag → 跑測試 → 建置 → Developer ID 簽章（Hardened Runtime + 安全時間戳）→ 簽 DMG → 送 Apple 公證 → staple → 驗證 → SHA-256 → 建立 **Draft** GitHub Release。使用者只需要從 Releases 下載 DMG。Apple 若在等待時間內沒處理完，這次 run 會以 **NOTARIZATION PENDING** 結束並保留原封不動的 DMG，之後用 [`resume-release.yml`](../.github/workflows/resume-release.yml) 完成（見下方「公證還在處理中（PENDING）」）。

[`Scripts/release.sh`](../Scripts/release.sh) 是同一條流程的腳本，也能在本機 Mac 上跑（它不會建立 GitHub Release）；本機正式發版用 [`Scripts/formal-release.sh`](../Scripts/formal-release.sh)。

## 兩件互不影響的事：日常開發與正式發版

- **日常開發**：照常在主要的 checkout 工作、切分支、改檔案、`swift build`、`swift test`、`./Scripts/package-app.sh`、`LINT_PREVIEW_BUILD=1 ./Scripts/release.sh`、`LINT_SKIP_NOTARIZE=1 ./Scripts/release.sh`。這些照舊使用 `dist/`、`dist/release/`，每次建置都會清掉 `dist/release/`，所以那裡**永遠不會**放送審過的 DMG（要公證的建置不准輸出到 `dist/release/`）。
- **正式發版**：從不可變的 tag（或本機測試時明確指定的 commit）建置，在**獨立的 git worktree**（detached，固定在那個 commit）裡跑，產物放在**持久的發版目錄**。發版開始後就記下確切的 commit SHA，之後的 resume 與驗證都以它為準，不看主要 checkout 的內容；公證等幾個小時或幾天都不影響你繼續開發下一版（例如 v0.3.1 在等 Apple 時照常開發 v0.3.2）。

## 前置條件

- **付費的 Apple Developer Program**：Developer ID 憑證與 Team API Key 都需要。
- 一台 Mac：產生 CSR，憑證的私鑰會留在這台 Mac 的鑰匙圈裡。

## 還沒有 Apple 憑證時：未簽章預覽版

Apple Developer Program 核准之前發不出正式版（Developer ID + 公證），這段期間用**預覽版**：

- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 在每個 pull request 與每次推送到 `main` 時跑 `swift test`，並用 `LINT_PREVIEW_BUILD=1 ./Scripts/release.sh` 組出 `Lint-<版本>-macOS-arm64-preview.dmg`（含 `.sha256`）。到該次 run 頁面的 **Artifacts** 下載（保留 14 天）。它不使用任何 secrets，只有唯讀權限。
- 本機也能組：`LINT_PREVIEW_BUILD=1 ./Scripts/release.sh`，產物在 `dist/release/`。

預覽版是 ad-hoc 簽章（外層 App 仍啟用 Hardened Runtime，執行環境與正式版一致；內建的 llama.cpp 也是 ad-hoc 簽章，但不帶 Hardened Runtime，理由見上一節），沒有公證，所以：

- 第一次開啟 macOS 會擋：系統設定 → 隱私權與安全性 → 找到 Lint 被阻擋的訊息 → **仍要打開**；或執行 `xattr -dr com.apple.quarantine /Applications/Lint.app`。
- 每換一個新的預覽 DMG，macOS 都會當成新的程式，**輔助功能**等授權要重新允許。
- 檔名固定帶 `-preview`，不會被當成正式版。正式版的流程、驗證與 secrets 完全不受影響。

### 發佈預覽版 pre-release

預覽版手動發佈，tag 用 `v<版本>-preview.<n>`：有後綴的 tag 不會觸發 `release.yml`，只有恰好是 `vX.Y.Z` 的 tag 才走正式流程。DMG 直接取 `main` 上該 commit 的 CI artifact（不在本機另外建），tag 打在同一個 commit：

```sh
gh run download <run-id> --repo davislinyd/Lint -n Lint-preview-<n> -D /tmp/lint-preview
```

```sh
git tag -a v0.2.0-preview.1 <commit> -m "Lint 0.2.0 preview 1" && git push origin v0.2.0-preview.1
```

```sh
gh release create v0.2.0-preview.1 /tmp/lint-preview/*.dmg /tmp/lint-preview/*.sha256 --verify-tag --prerelease --generate-notes --title "Lint 0.2.0 preview 1 (unsigned)"
```

Release 說明要寫明未簽章、怎麼開啟、以及每個預覽版都要重新允許輔助功能。

核准之後：照下方「一次性設定」補上憑證與 6 個 secrets，先在本機跑 `LINT_SKIP_NOTARIZE=1 ./Scripts/release.sh` 確認簽章，再用 `v` tag 走正式流程。不需要改任何程式。

## 內建的 llama.cpp 執行環境

官方 DMG 內含固定版本的 llama.cpp（`llama-server` 與它需要的 dylib），放在 `Lint.app/Contents/Resources/LlamaRuntime/<arch>/`。**模型不在 App 裡**，由使用者同意後在 App 內下載到 `~/Library/Application Support/Lint/Models`。

- **版本固定：**[`Resources/LlamaRuntimeManifest.json`](../Resources/LlamaRuntimeManifest.json) 記錄上游 tag／commit、每個架構的資產檔名、下載網址與 SHA-256。不用 `latest`，也不在發版時下載別的東西。
- **取得與驗證：**[`Scripts/fetch-llama-runtime.sh`](../Scripts/fetch-llama-runtime.sh) 由 `package-app.sh` 呼叫。它用 HTTPS 下載、**先驗 SHA-256（快取的檔案也每次重驗）** 才解壓縮，檢查 `llama-server` 的架構與 rpath，用 `otool -L` 沿著相依關係只收集需要的 dylib（有解不開的非系統相依就失敗），連同授權文件與 `runtime-info.json` 放進暫存目錄。這一步從不執行下載來的程式，也不需要 Homebrew。
- **巢狀簽章（由內而外）：**[`Scripts/sign-llama-runtime.sh`](../Scripts/sign-llama-runtime.sh) 先簽每個 dylib、再簽 `llama-server`，用與 App 相同的 Developer ID 身分，正式版帶 Hardened Runtime 與安全時間戳；最後才簽外層 `Lint.app`（不使用 `--deep` 簽章）。Hardened Runtime 的 library validation 要求同一個 Team ID，所以整組一起簽。開發版（Apple Development 或 ad-hoc）刻意不加 Hardened Runtime：ad-hoc 的 dylib 在 library validation 下載不進來（已實測）。
- **公證涵蓋它：**執行環境在 App 簽章與 DMG 公證之前就已放進 `Lint.app`，所以 Apple 的公證涵蓋出貨的每個可執行檔。首次啟動之後不會有任何未簽章的可執行檔被下載。
- **架構：**執行環境依 Lint 執行檔的架構選擇，兩者不一致就失敗。目前只出 arm64；manifest 也釘了 x86_64，但只驗過雜湊、沒有執行過。
- **授權：**上游 `LICENSE`、manifest 釘住的 `LICENSE-jsonhpp`（同樣驗雜湊）與 `NOTICE-Lint.txt` 放在 `.../licenses/`，也可從「設定 → 關於」開啟。
- **更新：**V1 的執行環境只隨 Lint 更新，沒有獨立自我更新的可執行檔（維持簽章、公證與回滾的簡單）。模型是資料，日後可以獨立提供選用的新版本；現有的模型不會被自動取代。

### 升級 llama.cpp 版本

1. 在 <https://github.com/ggml-org/llama.cpp/releases> 選一個 tag，記下 commit。用 `gh api repos/ggml-org/llama.cpp/releases/tags/<tag> --jq '.assets[] | select(.name|test("macos")) | "\(.name) \(.size) \(.digest)"'` 取得資產。
2. 自己下載 `llama-<tag>-bin-macos-arm64.tar.gz`（與 `x64`），用 `shasum -a 256` 算雜湊，**確認與 GitHub 回報的 digest 相同**，再寫進 manifest（`tag`、`build`、`commit`、`reportedVersion`、每個架構的 `assetName`／`url`／`sha256`／`size`、`licenses` 的 commit 與雜湊）。
3. `swift test`（`RuntimeScriptTests` 會檢查 manifest 的形狀），再跑 `./Scripts/package-app.sh debug`。
4. 冒煙測試：用實際的 `dist/Lint.app/Contents/Resources/LlamaRuntime/arm64/llama-server` 載入一個模型（`-m`），確認 `/v1/models` 與一次 chat completion 正常，預設的額外參數（`--jinja --no-skip-chat-parsing -ngl 99 -fa on …`）仍被接受。
5. `LINT_PREVIEW_BUILD=1 ./Scripts/release.sh` 確認巢狀簽章檢查通過。

## 手動驗收（每次發版前，在另一台乾淨的 Mac）

自動測試涵蓋不到簽章、Gatekeeper 與真實網路，所以 Draft Release 的 DMG 要在**沒有 Homebrew、llama.cpp、Ollama 的 Apple Silicon Mac**（或全新的使用者帳號）上照這份走一遍：

1. 下載 DMG、拖進 Applications、開啟：Gatekeeper 不擋。
2. 「設定本機 AI」視窗自動出現；執行環境顯示「Lint 內建 · llama.cpp <tag>」，模型顯示未安裝。
3. 同意頁列出大小與所需空間；按「下載並安裝」**之前**不能有任何下載。
4. 下載中按「取消下載」，再按「繼續下載」：從原進度接續。中途直接結束 Lint 再開，partial 仍在、可以接續。
5. 完成後依序是驗證、安裝、啟動：`curl http://127.0.0.1:8000/v1/models` 回 200，`lsof -nP -iTCP:8000 -sTCP:LISTEN` 只監聽 `127.0.0.1`；輔助功能步驟能引導、授權後自動更新；校對成功。
6. 對安裝後的 App 跑 `codesign --verify --deep --strict` 與 `spctl --assess --type execute`；`codesign -dvv .../LlamaRuntime/arm64/llama-server` 應是 Developer ID、Hardened Runtime、有時間戳、與 App 同一個 Team ID。
7. 在設定移除模型後按 `⌥⌘K`：應顯示「本機 AI 尚未設定」與按鈕，不出現 Connection refused。
8. 全程沒有安裝或提到 Homebrew。

### 在自己的 Mac 上試新版而不動到真實資料

`UserDefaults` 與 Application Support 都不受 `HOME` 影響（Foundation 用 `getpwuid`），所以要這樣隔離：複製 `dist/Lint.app`，用 `plutil -replace CFBundleIdentifier -string app.lint.assistant.e2e` 改 bundle id 並重新簽章（設定就是獨立的網域），設 `LINT_APP_SUPPORT_DIR=<資料夾>` 讓模型與下載落在別處，並用 `defaults write app.lint.assistant.e2e app.lint.localServer.port -int 8127` 換一個埠，避免碰到正在跑的 Lint 與它的 llama-server。若要看未授權輔助功能的畫面，用 `open -n -g --env LINT_APP_SUPPORT_DIR=<資料夾> <App>` 啟動（直接執行二進位檔會繼承終端機的授權）；隔離的副本一旦有授權，會在你打字時監看輸入，先 `defaults write <bundle id> app.lint.liveWatchWhileTyping -bool false`。這些只是本機試用的手段，發版驗收仍以上面的清單為準。

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

Resume Release（`resume-release.yml`）也在 `release` 環境執行（從 `main` 手動觸發），只用得到 `APPLE_TEAM_ID`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`、`APPLE_API_KEY_P8_BASE64`，不碰 Developer ID 憑證。

設好後把本機的 `.p12` / `.p8` 收進密碼管理器或刪除。它們不能進 repo、issue 或聊天。

## 發版（GitHub Actions）

1. `Resources/Info.plist` 的 `CFBundleShortVersionString` 是唯一的版本來源；確認它就是要發的版本，並已合併進 `main`。
2. 在 `main` 上打 tag 並推送：

```sh
git switch main && git pull
git tag -a v0.2.0 -m "Lint v0.2.0"
git push origin v0.2.0
```

   tag 必須是 `vMAJOR.MINOR.PATCH`、與 Info.plist 版本相同、指向 `main` 上的 commit，否則 workflow 會在載入任何金鑰之前就失敗。沒有 `v` 前綴的 tag（例如早期本機的 `0.2.0`）不會觸發 workflow。
3. Actions → **Release** 跑完後（Apple 沒在時間內處理完則是 PENDING，見下節），Releases 頁會出現 **Draft**，內含 `Lint-<版本>-macOS-arm64.dmg` 與 `.sha256`。`CFBundleVersion` 會是這次 run 的編號。
4. 在**另一台 Mac** 下載並測試：開啟 DMG、拖進 Applications、啟動、輔助功能授權、LLM、Learning 資料庫。
5. 沒問題就在 GitHub 上按 **Publish release**。等流程穩定幾次之後，才考慮把 workflow 的 `--draft` 拿掉。

重跑：Actions → Release → *Run workflow* → 輸入既有的 tag。同一個 tag 若已有 Draft，先刪掉它（`gh release create` 不會覆蓋）。**公證 PENDING 時不要重跑 Release**：workflow 會先檢查這個 tag 有沒有未過期的 `pending-release-<tag>` artifact，有就拒絕建置，請改用 Resume Release。

同一個 tag 同一時間只會有一條發版流程（Release 與 Resume Release 共用 `release-<tag>` concurrency group）；其他 tag、`ci.yml`、推到 `main` 的 commit 都不會被卡住。

### 公證還在處理中（PENDING）

`release.sh` 先上傳 DMG（不等待），拿到 submission ID 後**立刻**把 ID、DMG 的 SHA-256、commit 等寫進 `release-state.json`，然後才用 `notarytool wait --timeout 45m` 等。

- **notarytool 等到逾時（exit code 124）不等於公證被拒。** 逾時只代表這台電腦不等了；Apple 那邊還在處理。腳本會再用 `notarytool info` 問一次狀態，仍是 `In Progress` 就以 **PENDING**（exit code 75）結束：不刪 DMG、不重建 DMG，狀態檔保留。
- 只有 Apple 回 `Invalid`（或 `Rejected`）才是被拒（exit code 65）：印出並保存 `notarytool log`（`notarization-log.json`），狀態記為 `invalid`，這個 DMG 永遠不會被 staple 或發佈。
- 上傳失敗、沒拿到 submission ID（exit code 1，狀態 `submission-failed`）：Apple 那邊沒有任何待處理的東西，檢查 API key 與網路後重新開始一次發版。
- 已有 submission ID 但查不到狀態（網路、401/403，exit code 69）：送審紀錄與 DMG 都保留，修好之後 resume。

在 GitHub Actions 上，PENDING 時 Release run 會：

1. 把**送審的那個 DMG**、`release-state.json`、`notarization-submit.json` 上傳成 artifact `pending-release-<tag>`（不壓縮，保留 30 天）；
2. 立刻把 artifact 下載回來，用 `cmp` 逐位元組比對原檔，並確認 SHA-256 等於送審時記錄的值（GitHub artifact 是 zip 封裝，內容不變；download-artifact 另外會驗 artifact 的 digest）；
3. 在 run 的 Summary 顯示 **NOTARIZATION PENDING**、submission ID、送審的 SHA-256，以及 resume 指令。Job 本身是成功的（這不是失敗）。

之後（Apple 處理完再跑，太早跑只會再回 PENDING、不改任何東西）：

```sh
gh workflow run resume-release.yml --repo davislinyd/Lint -f tag=v0.3.1 -f run_id=<Release run 的 ID> -f dmg_sha256=<Summary 上的 SHA-256>
```

Resume Release 只做這些：確認 `run_id` 是 Release workflow 的 run → checkout 該 tag → 從那個 run 下載 `pending-release-<tag>` → 確認狀態檔的 tag、commit 與 tag 相同、`dmgSHA256` 等於你給的 `dmg_sha256` → `resume-release.sh` 重算 DMG 的 SHA-256 並要求**完全相等** → `notarytool info` →

- `Accepted`：staple **那個** DMG → `stapler validate` → `hdiutil verify` → 掛載檢查 `Lint.app` 簽章、內建 llama.cpp、Gatekeeper → 重新產生最終 `.sha256` → 建立 Draft Release；
- `In Progress`：什麼都不動，run 顯示 PENDING，之後用同樣的參數再跑；
- `Invalid`：印出 log、上傳診斷資料、失敗，不發佈。

它不建置、不簽章、不重新送審，也不需要 Developer ID 憑證（只用 API key）。

**永遠不要為了 resume 重建 DMG。** 重建出來的 DMG 是不同的檔案（SHA-256 不同），舊的 submission ID 的票證不屬於它；`resume-release.sh` 看到 SHA-256 不符會直接停止、不 staple。原始 DMG 若遺失，就只能重新發一次版（新的建置、新的送審）。

## 本機正式發版（隔離的 worktree 與持久目錄）

[`Scripts/formal-release.sh`](../Scripts/formal-release.sh) 在本機做同一件事，而且不依賴你的工作目錄：

```sh
Scripts/formal-release.sh start v0.3.1
```

它會確認 tag 是 `vMAJOR.MINOR.PATCH`、存在、在 `origin/main` 上（先 `git fetch origin --tags`）、該 commit 的 `Info.plist` 版本相同；然後在 `~/Library/Application Support/LintRelease/`（可用 `LINT_RELEASE_ROOT` 改）建立：

```text
~/Library/Application Support/LintRelease/
  v0.3.1/
    <commit-sha>/
      worktree/                          detached checkout，固定在該 commit；建置在這裡跑
      artifacts/
        Lint-0.3.1-macOS-arm64.dmg       送審的那個 DMG（finalize 後是 staple 過的版本）
        Lint-0.3.1-macOS-arm64.dmg.sha256  finalize 後才產生
        release-state.json
        notarization-submit.json         notarytool 上傳的回覆
        notarization-log.json            只有 Invalid 時
      logs/
        start-<時間>.log、resume-<時間>.log
```

環境變數與 `release.sh` 相同：`CODESIGN_IDENTITY`、`APPLE_API_KEY_PATH`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`、`APPLE_TEAM_ID`、`LINT_BUILD_NUMBER`、`LINT_NOTARY_TIMEOUT`（預設 `45m`）。`.p8`／`.p12` 不會被複製進發版目錄，狀態檔也不含任何金鑰或密碼。本機測試未打 tag 的 commit：`Scripts/formal-release.sh start --commit <rev>`（狀態檔的 `tag` 是空字串）。

同一個版本已有未完成（`built`／`pending`／`finalizing`）的發版時，`start` 會拒絕；同一個 commit 的 `artifacts/` 已有東西也會拒絕，永遠不覆蓋。

查狀態（只讀本機檔案，不連 Apple）：

```sh
Scripts/formal-release.sh status
```

Resume（用發版 worktree 裡、也就是 tag 那個 commit 的腳本執行；worktree 不在了會從 git 重建）：

```sh
Scripts/formal-release.sh resume v0.3.1
```

也可以直接跑 `Scripts/resume-release.sh <release-state.json>`（需要能找到該 commit 的 git repo）。驗證所用的 entitlements、runtime manifest、語系清單都用 `git archive` 從**送審的 commit** 取出，所以主要 checkout 之後的修改不會影響 resume。

結束代碼：`0` 完成、`75` PENDING、`65` Invalid、`69` 查不到狀態、`1` 其他錯誤（包括 DMG 遺失或 SHA-256 不符，這兩種在連 Apple 之前就停止）。

Finalize 的細節：先把送審的 DMG 複製到 `artifacts/.finalize/` 並驗證雜湊，在副本上 staple 與做完所有檢查，才用同一目錄內的 rename 換掉原檔；中途失敗時原檔仍是送審時的位元組。狀態檔先記下 `finalizing` 與最終 SHA-256 再 rename，所以就算在那一瞬間中斷，下次 resume 也認得出來。

清理（明確執行才會刪）：

```sh
Scripts/formal-release.sh cleanup v0.3.1 --worktree-only
```

```sh
Scripts/formal-release.sh cleanup v0.3.1
```

`--worktree-only` 只移除 worktree（finalize 之後就可以刪，會同時 `git worktree prune`），DMG、狀態與 log 保留到你自己清。不加參數會刪除 `v0.3.1/` 底下的整個發版目錄；只要還有 `built`／`pending`／`finalizing` 的發版就拒絕，除非加上 `--discard-pending`（放棄那次送審）。`--commit <sha>` 只處理其中一個 commit。它只會動 `LINT_RELEASE_ROOT/<版本>/` 底下，不會碰其他版本。

### release-state.json

所有值都是字串（未知時為空字串），另有整數 `schemaVersion`。以原子方式寫入（同目錄暫存檔 + rename）。

| 欄位 | 內容 |
|------|------|
| `schemaVersion` | `1` |
| `version`、`tag`、`commit`、`architecture`、`buildNumber` | 發版身分；`commit` 是完整 SHA |
| `dmgFileName`、`dmgPath`、`dmgSHA256`、`dmgCreatedAt` | 送審的 DMG 與它的 SHA-256（resume 以同目錄的 `dmgFileName` 為準） |
| `submissionID`、`submissionCreatedAt`、`notarizationStatus`、`lastCheckedAt` | 公證：`In Progress`／`Accepted`／`Invalid`／`Rejected` |
| `releaseStatus` | `built` → `pending` → `finalizing` → `finalized`；或 `invalid`、`submission-failed`；演練為 `unnotarized`、`preview` |
| `finalSHA256`、`finalizedAt` | staple 後最終 DMG 的 SHA-256 |

## 本機演練（不送 Apple）

```sh
LINT_SKIP_NOTARIZE=1 ./Scripts/release.sh
```

需要本機鑰匙圈有 Developer ID Application 憑證。產物在 `dist/release/`，檔名帶 `-unnotarized`，不能發佈。設 `LINT_RELEASE_OUTPUT_DIR=<絕對路徑>` 可以改輸出到一個新的（或空的）目錄，並多產生 `release-state.json`；`dist/release/` 仍是預設。要在本機真的公證，用上面的 `Scripts/formal-release.sh`（`release.sh` 公證時一定要有 `LINT_RELEASE_OUTPUT_DIR`，不接受 `dist/release/`）。

日常開發與本機安裝不受影響：`./Scripts/package-app.sh`（含 `release` 引數）照舊用 Apple Development 憑證簽章；只有 `LINT_RELEASE_BUILD=1` 才走嚴格的 Developer ID 路徑。

## 流程檢查了什麼

- 工作流程：tag 格式、tag 存在且就是 checkout 的 commit、commit 在 `main` 上、tag 版本 = Info.plist 版本、這個 tag 沒有 PENDING 的送審、6 個 secrets 都在、`swift test` 通過。`release.sh` 公證前還要求 checkout 乾淨且就是該 tag 的 commit。
- `release.sh`：只接受**恰好一個** `Developer ID Application` 憑證（不 fallback 到 Apple Development 或 ad-hoc）；簽章有 `runtime` flag、安全時間戳、`app.lint.assistant`、`TeamIdentifier` 符合 `APPLE_TEAM_ID`、entitlements 與 `Resources/Lint.entitlements` 一致且沒有 `get-task-allow`；DMG 只含 `Lint.app` 與 `Applications` 連結、已簽章；公證必須 `Accepted` 才 staple（`In Progress` 為 PENDING、`Invalid` 印出 `notarytool log` 並失敗，兩者都不刪 DMG）；resume 前重算 SHA-256 必須等於送審時的值；`stapler` 附上並驗證票證；`hdiutil verify`；掛載最終 DMG 對裡面的 app 做 `codesign` 與 `spctl` 驗證；產出並自我驗證 SHA-256。
- 內建的 llama.cpp（`release.sh` 對建置出的 App 與 DMG 裡的 App 各檢查一次）：`LlamaRuntime/<arch>/` 存在、`runtime-info.json` 的架構與 tag／SHA-256 等於 manifest、授權文件在；`Lint.app` 裡**每一個**非主程式的 Mach-O 都是薄的、與 App 同架構、簽章有效，正式版還要求是 Developer ID、Hardened Runtime、安全時間戳、與 App 同一個 Team ID（`codesign --deep` 不會檢查 `Resources` 裡的程式，所以逐一檢查）；SwiftPM 資源 bundle、`Localizable.strings`、圖示與 `PkgInfo` 都在。
- 預覽版（`LINT_PREVIEW_BUILD=1`）：ad-hoc 簽章、`runtime` flag、entitlements、版本與 build number、DMG 內容、SHA-256；不呼叫任何 Apple 服務，DMG 不簽章。

## 疑難排解

| 症狀 | 原因與處理 |
|------|-----------|
| `Version mismatch` | tag 與 Info.plist 版本不同；改 Info.plist 或換 tag |
| `not reachable from main` | 先把該 commit 合併進 `main` 再打 tag |
| `secret … is missing or empty` | `release` 環境缺 secret（名稱見上表），或 workflow 沒有進到 `release` 環境（檢查 Deployment branches and tags） |
| `no valid 'Developer ID Application' code signing identity` | `.p12` 沒包含私鑰、憑證過期或被撤銷、密碼錯誤；訊息會列出鑰匙圈裡實際有的憑證 |
| `NOTARIZATION REJECTED … Invalid` | 看 log（`notarization-log.json`）裡的 `issues`。常見：缺 Hardened Runtime、沒有安全時間戳、未簽章的可執行檔、`get-task-allow`。修好後發新的一版 |
| `NOTARIZATION PENDING` | 不是錯誤：Apple 還在處理（等待逾時 exit 124 也是這個）。稍後 resume，不要重建 |
| `the DMG was changed or replaced after it was submitted` | 送審後 DMG 被改過或換掉；停止，不 staple。找回原檔，或重新發版 |
| `the submitted DMG is missing` | 同上；不要重建來頂替 |
| `already has a pending notarization`（Release workflow） | 這個 tag 已有 PENDING 的送審；用 Resume Release。確定要放棄時才刪掉那個 artifact |
| `a notarized release needs its own directory` | 公證的建置要 `LINT_RELEASE_OUTPUT_DIR`；本機用 `Scripts/formal-release.sh` |
| `notarytool` 回 401 / 403 | Key ID / Issuer ID / `.p8` 不成對，或不是 **Team** key（Access 至少 Developer） |
| `stapler` Error 65 | 公證通過後票證要一點時間才會出現在 Apple 的 CDN；腳本會重試 5 次，仍失敗就再 resume（不要重建） |
| `hdiutil … Resource busy` | Spotlight／XProtect 短暫占用剛掛載的磁碟區；腳本已用分步建立與必要時 `-force` 卸載處理 |

## 憑證輪替

- Developer ID 憑證到期或私鑰外洩：到 Apple Developer 撤銷、重做 CSR → 憑證 → `.p12`，更新 `APPLE_DEVELOPER_ID_P12_BASE64` 與 `APPLE_DEVELOPER_ID_P12_PASSWORD`。
- API Key 外洩：在 App Store Connect 撤銷，建立新的 Team key，更新 `APPLE_API_KEY_ID`、`APPLE_API_KEY_P8_BASE64`（Issuer ID 不變）。

## 已知限制

- 只出 **arm64**；檔名由實際的執行檔架構決定（`lipo -archs`），不會標示成 universal。Universal 2 留待日後（內建的執行環境是單一架構的，`package-app.sh` 遇到 universal 執行檔會直接失敗，不會硬拼）。
- 打包需要連到 github.com 下載固定版本的 llama.cpp（`ci.yml` 與 `release.yml` 的 runner 都可以）；下載會被快取在 `.build/llama-runtime/cache`，但每次都會重驗雜湊。
- 這台機器上 Developer ID 簽章、Hardened Runtime 下的 llama-server 只用 Apple Development 身分（同一個 Team ID）實測過能載入 dylib 並用 Metal 推論；真正的 Developer ID 簽章、公證與 Gatekeeper 驗證要等第一次正式發版才能確認。
- 預覽版 DMG 約 15 MB（壓縮後；其中 llama.cpp 解壓縮約 24 MB，`Lint.app` 約 34 MB）。
- 只公證並 staple **DMG**，DMG 裡的 app 本體沒有另外 staple：使用者首次啟動需要能連到 Apple 查詢票證（離線首次啟動可能被 Gatekeeper 擋下）。
- `ci.yml`（pull request 與 `main` 的測試和預覽版）刻意不使用任何 secrets，也不用 `pull_request_target`；日後不要在裡面加任何 release secrets。
- 從 Apple Development 版換成 Developer ID 版時，macOS 會視為不同的簽章身分：輔助功能與「系統事件」自動化授權需重新允許一次，鑰匙圈也可能再問一次「永遠允許」。
- macOS 27 的 `hdiutil create` 已標示為 deprecated（仍可用）；日後系統移除時需改用 `diskutil image`。
