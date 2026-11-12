# 驗證：offline integration、CI、live授權與UI分開

## 目前驗收狀態

company-24 已附 24 張 SFHQ Part 2 CC0 合成肖像及逐圖證據；正式 Persona、rich 與 minimal 可做完整離線驗證。Existing 的公開 pack（`personas\m365-sample`、`personas\existing-template`）與配對範例（`examples\sample-rich`、`examples\sample-minimal`、`examples\existing-minimal`）同樣只做離線驗證；Existing 的帳號檢查／設定流程目前只有離線模型測試，**沒有任何真實人員被檢查或更新**。這不等於 tenant／Presenter UI 通過。缺素材與錯誤來源仍必須 fail-closed，不能補測試圖或略過驗證。

執行目錄為專案根目錄；使用既有`.venv`及uv。這些offline命令不讀私人config、不登入、不連Graph、不寄信、不修改tenant。沒有必要就不安裝／restore依賴。

## 1. 真正可成功的離線smoke（僅測試fixture）

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\tests\fixtures\scenario.json --personas .\tests\fixtures\personas.json
```

預期：`{"valid": true, "errors": []}`，exit `0`。

主入口的離線模式：

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\tests\fixtures\scenario.json -PersonaPackPath .\tests\fixtures\personas.json -NonInteractive
```

預期：`[Validated] Mode=Validate Exit=0`，但`actual UI/Copilot: NotVerified`。fixture的小JPEG只是測試作品，不是正式人物照或可live初始化的starter；不能複製進company-24來解除阻擋。

## 2. 完整正式資料包驗證

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --personas .\personas\company-24\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\rich-training\scenario.json --personas .\personas\company-24\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\minimal\scenario.json --personas .\personas\company-24\personas.json
```

預期各 exit `0`、`valid:true`、`errors:[]`。逐圖來源與權利依據見 `personas\company-24\ASSET-LICENSES` 文件；validator 核對實際檔案、雜湊與參照，人工另檢查肖像／權利，不以機器檢查替代。

Existing 的公開 pack 與配對範例（Persona 1.1 沒有肖像／授權，scenario 仍是 1.0；`scenario.personaPackId` 必須等於 pack 的 `packId`）：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --personas .\personas\m365-sample\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\sample-rich\scenario.json --personas .\personas\m365-sample\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\sample-minimal\scenario.json --personas .\personas\m365-sample\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\existing-minimal\scenario.json --personas .\personas\existing-template\personas.json
```

主入口：

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\examples\rich-training\scenario.json -PersonaPackPath .\personas\company-24\personas.json -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PersonaPackPath .\personas\company-24\personas.json -PersonasOnly -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\examples\sample-rich\scenario.json -PersonaPackPath .\personas\m365-sample\personas.json -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\examples\existing-minimal\scenario.json -PersonaPackPath .\personas\existing-template\personas.json -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PersonaPackPath .\personas\existing-template\personas.json -PersonasOnly -NonInteractive
```

預期 `[Validated] Mode=Validate Exit=0`；遇錯誤仍 exit `2`。需要逐筆 structured errors 時直接使用 Python validator；任何失敗不允許進入 Initialize 或 RunAll。

## 3. Scenario內容與builder驗證的隔離邊界

正式資料使用真實 starter 素材；離線負向測試仍只修改隔離副本，不刪除或覆寫正式肖像。
檢查 4 BU 各 5 人＋共享 4 人、主管樹、24 張不同 JPEG／權利證據及所有跨 pack 參照。
每故事 5 封郵件、至少 3 位作者、3 個跨日 Teams 主文、各 2 個實質回覆，
包含 mentions／比較表；數值與 workbook recipe 必須一致。
builder 以正式素材在兩個新的輸出目錄建置，核對逐檔相同；已完成的同目錄只能精確重用，
不以重新上傳或覆寫來湊通過。自然語言／視覺品質仍需人工核對。

## 4. 使用完整 starter 建置

以下命令使用正式 company-24 與 rich-training，不需要測試照片替代：

```powershell
if (-not (Test-Path -LiteralPath .\runs)) { New-Item -ItemType Directory -Path .\runs -ErrorAction Stop | Out-Null }
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\build_scenario.py --pack .\examples\rich-training\scenario.json --personas .\personas\company-24\personas.json --output .\runs\rich-prepared
```

成功才有`prepared:true`及完整manifest／COMPLETE。Output須是新目錄或與同來源、schema、builder完全相同的既存prepared；缺檔、多檔、partial或tamper不overwrite／repair。不要把測試副本prepared搬來冒充正式產物。

## 5. 離線 unit 與真正的跨工作負載 integration

已有依賴時不要 restore；以下不需要 Graph SDK、tenant secrets 或瀏覽器套件：

```powershell
uv run --offline --no-sync python -m pytest -q --tb=short
pwsh -NoProfile -File .\tests\powershell\Test-Unit.ps1 -Area All
pwsh -NoProfile -NonInteractive -File .\tests\powershell\Test-Integration.ps1
```

`Test-Unit.ps1 -Area Identity|Personas|Storage|Outlook|Teams|Console|All`
與 `-CaseName <regex>` 是既有選取器。Integration 也接受 `-CaseName`；
選到零個案例會失敗，不以空結果冒充通過。
舊 delegated SDK-only 案例已退休，由 `AppOnly.Tests.ps1` 替代：六種連線 Mode 的
token 身分／固定 roles／額外 grants、相同 handle 續取、capability 前失敗零傳輸，
以及實際 App transport 的底層 HTTP fixture（JPEG byte[]／image/jpeg／404／禁止 redirect）。
Personas 保留整批確認、寫入、Unknown 不重試等模型回歸，另驗續取失敗不建立 journal。
這些離線 fixture 不是實際登入、Graph 或 tenant 驗收。
`-ScratchRoot <local-directory>` 可將**本次唯一**的測試副本放在獲准的 session 目錄；
預設是 `tests\.scratch`，不是 OS temp。`finally` 只移除本次建立的 UUID 副本，
不清除其他人的檔案、正式素材、未知 run 或 remote resources。

Integration 不執行 area tests 當 proxy；只載入既有 fixture function definitions
重用離線遠端模型，真正呼叫 `Invoke-SeedConsole`：

- 同一 App-only 管理模式→完整人物／照片／SKU diff＋雙確認→真正
  `Invoke-InitializePersonas`→持久化 `Provisioned/NotVerified` binding。
  密碼只在測試 process 記憶體核對，不能出現在檔案、摘要或錯誤。
- **另一個** app-only session→binding 身分／profile read-back→selected services gate
  →builder→Storage／Outlook／Teams adapters→完整全域 GET-only preflight。
  全部操作事先列出，任何 workload Block 都讓其他 workload 零寫入。
- 精確 approval／durable Submit→Storage 真實模型的內容 read-back／AssetUrlMap
  →不同作者的郵件往返與 Presenter Inbox→Teams roots/replies／mentions／
  migration completion／owners/members→所有操作 Completed／完整 read-back／actual links。
- 同一 config／binding／runId 的**第二次 RunAll**及 Verify 都重新讀回、零遠端寫入，
  journal／binding bytes 不變；新的摘要不是重寫舊報告。
- 單獨四種 workload 使用各自的權限與 operations；欠席次、缺圖、碰撞、
  缺 profile／drift、服務未佈建、Presenter 保護、無 exact approval、未知 Create／
  已接受郵件 POST 但回應遺失都拒絕；部分／Unknown 保留且不續跑、不重送。
- **Existing（1.1）**：N 位既有帳號→有界 GET-only 帳號解析（精確 UPN 存在就沿用；只有 404 才查 public 提示，唯一完整精確匹配是提議，其餘由本機一次選擇）→整批唯讀檢查（身分、manager、snapshot；不查目標角色）→共用 renderer
  的警告與 `原指定 → 實際帳號`、Before→After→`DemoAccountAcknowledged`＋雙確認→逐人 `PATCH` 四個欄位與 manager `$ref`
  並讀回→整批最終讀回→`ConfiguredExisting/NotVerified` binding→只改 `accountMappings` 的本機保存→另一個 app-only session 的
  RunAll 只寫課程內容，人員欄位之外的寫入為 0，第二次 RunAll 與 Verify 零寫入。
  同一組案例覆蓋：一位、四位與整個 sample pack 的選取；選取人數少於 scenario 作者時，
  在任何內容寫入前 `Seed.Binding.Missing`；實際欄位漂移或缺欄阻擋 RunAll 而不修復；
  fake `Provisioned` binding 或缺失／被換掉的完成 journal 證據在 Graph 請求前被拒絕。
  Existing 單元測試另證明：任一人 Block 時整批零寫入、目標或主管持有直接／eligible／群組／directory 角色不會 Block
  也沒有任何目標角色或群組查詢（操作員缺有效角色仍被拒絕）、真實的主管問題與外部主管鏈循環仍被擋、
  Presenter／操作員不可入選、確認前後資料變動使整批失效、
  寫入中漂移／未知／被忽略的效果停止且不重試也不產生 binding，以及 null／缺欄位的 snapshot 在警告前驗證。
  解析器案例證明：存在的 UPN 不查名稱；404 加唯一完整全名或 alias 才提議（可能是不同 UPN／網域）；
  提示衝突、第二頁才出現的同名、同名多筆、只有前綴、零筆、不合格或已被使用的唯一匹配一律不自動選人且候選最多 20 筆；
  403／逾時不是「不存在」且不進名稱查找；選擇的 Presenter／操作員／重複／Guest／同步／停用／不存在帳號被拒絕；
  通用（無提示）pack 可輸入精確 UPN；已開始的初始化不再解析；確認後 fresh 檢查沿用已核准的固定 ID，不重跑名稱查找；
  方法與實際帳號進入 fingerprint，被改的預覽被拒絕；`Save-SeedResolvedAccountMappings` 只改 `accountMappings`、
  遇到被改過的檔案不覆寫並標 `LocalConfigSyncRequired`，下一次初始化只依完整 journal／binding 證據在登入前補存。
  Console 與 session runner 的測試另證明本機選人在獨立的確認之前只問一次，候選不出現在自動化輸出或報告。
  這些都是離線模型，不是實際人員檢查。
- Managed 的測試 config 來自 `tests\fixtures\managed-config.json`（synthetic 固定副本）；
  根目錄 `config.json.example` 現在是 Existing 占位範例，測試不再以它隱含 Managed 預設。

所有 HTTP／SDK 路徑明確注入；缺路由直接 throw，auth injection 不完整也拒絕，
**沒有 live fallback**。`NetworkAttempts=0` 只表示離線程式行為，
不是 Exchange／Teams／SharePoint／Presenter 服務驗收。

## 6. CI 與鎖定依賴

`.github\workflows\test.yml` 僅在 Windows hosted runner：

1. `uv venv`，以 `dev.lock`／`uv pip sync --require-hashes` 從官方
   `https://pypi.org/simple/` 還原 runtime＋pytest。
2. 解析所有 engine／tests／root PowerShell entry（需要 7.5+），Python compileall。
3. Python unit、PowerShell All、完整 offline integration。
4. 真正 CLI Validate fixture＋personas-only 成功；正式 rich／minimal 與 company-24
   也必須成功，另外只驗證 Existing 的配對（`sample-rich`／`sample-minimal`＋`m365-sample`、
   `existing-minimal`＋`existing-template`）。負向 unit tests 另外確保缺圖、不安全路徑／錯誤雜湊仍會停止。

CI 沒有 tenant secrets、Graph SDK 安裝、live verifier 執行、人物初始化或資料匯入。
Workflow 已交付但本機不代表 hosted CI 實跑；不能把 YAML 建立當綠燈。

工作站必須明列 proxy；lock 不內嵌 index，package versions／hashes 不因 registry 改變。
無 manifest 變更或缺依賴就不安裝。首次建置／更新命令見 root README。

`pyproject.toml` 的 **optional development group `live`** 才包含 Playwright，
`dev.lock` 不含瀏覽器／live dependencies。`live.lock` 已用以下命令透過核准的
工作站 registry 成功解析（exit 0）；沒有改官方 fallback、安裝套件或 browser binaries。
如需另經核准的實際驗證，可在獨立環境安裝：

```powershell
uv pip compile --group live --python-version 3.11 --generate-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/ --output-file .\live.lock
# 上一步成功並審核 lock 後，另建本機專用 .venv-live；不改目前 dev 環境
uv venv .venv-live
uv pip sync --python .\.venv-live\Scripts\python.exe --require-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/ .\live.lock
```

不要因上述說明自動安裝或啟動 live。採 CDP 連既有 browser，不執行
`playwright install`／自動下載或自動登入。

## 7. 分開 opt-in 的 live／Presenter UI

**本次沒有live授權，未執行**：token／SDK真實登入、tenant人員建立與修正、席次讀取／配置、真實寄信與Inbox、Teams migration、OneDrive／SharePoint上傳與服務policy、Presenter UI或Copilot readiness。

未來另獲授權後，按[操作指南](getting-started.md)逐步：起始認證→只讀inventory／service／global preflight→完整diff及雙／單項明確確認→durable journal→authoritative read-back→真人Presenter打開所有直接連結→另做搜尋／Copilot驗收。API accepted／Graph結構證據／雜湊／binding均不能取代這些步驟。

**三份授權不互通**：人員管理（Managed：確切 new UPN／field diff／JPEG／SKU／數量；Existing：確切既有 UPN、逐人 Before→After 與使用者本人輸入的 `DemoAccountAcknowledged`）、
資料匯入（確切 tenant/run 及副作用）、Presenter UI 只讀（確切帳號及 URL／已知 IDs）。
計畫核准／offline／任一份授權都不推導另一份。不得刪人或移除 license 清場。

`tests\live\verify_presenter.py` 是第三項的 opt-in helper，不做 live setup：

- 只連已由使用者登入、另行核准的本機 Chrome／Edge CDP session；
  endpoint 僅接受 `http://127.0.0.1:<port>`／`localhost`／`[::1]`，且只有一個 browser context。
  不開新 profile、不登入、不 consent、不點擊／寄信／貼文／改帳號、不匯出 cookies/storage/token。
- **只觀察使用者事先開啟並載入完成的 exact approved URL tab**，且每個 URL
  必須恰有一個 tab；只接受 M365 unsigned HTTPS。不 `goto`／reload／click／
  fetch／new_page，也不攔截或接管其他頁面的網路。
  因開郵件／Office viewer 可能自動改「已讀」等狀態，採純觀察而非由工具導覽，
  避免把「只發 GET」誤當無寫入保證。使用者須另行核准並親自開啟結果直接連結。
- 每頁先用獨立、唯一且可見的 account locator 核對 exact Presenter UPN，
  不相符便不讀內容。再核已知 actual ID、完整預期內容、實際 sender／post author，
  reply parent／mention／photo（有選取時）、文件與 List/item。
  不用封數／標題／subject 取代內容，不掃 directory 或整頁 HTML，不自動修復。
- UI 未提供 ID／帳號、selector 不唯一、tab 未開／重複／途中換頁、
  檔案沒開或 permission denied，均如實 `Blocked`，
  不改成 Graph-only 或標題 substring fallback。即使 all Verified 也只代表所列 checks，
  不證明租用戶其他內容、完整 ACL／搜尋索引／Copilot。

### 私有核准與 checks 格式

手動從**實際完成結果／journal／Presenter UI**取得 URL、resource ID 與窄範圍 locator，
不要猜 URL／ID，也不要把這些私有檔送給 AI。兩份 JSON 都不可混入 token／密碼。
下列為欄位示意；尖括號必須替換成已核准的實值，不能拿來直接執行：

```json
{
  "schemaVersion": "1.0",
  "scope": "PresenterReadOnly",
  "approvalId": "<人工核准編號>",
  "tenantId": "<actual tenant GUID>",
  "presenterUpn": "<exact Presenter UPN>",
  "approvedUrls": ["<actual unsigned resource URL>"],
  "requiredKinds": ["outlookMessage"]
}
```

```json
{
  "schemaVersion": "1.0",
  "tenantId": "<同一 actual tenant GUID>",
  "presenterUpn": "<同一 exact Presenter UPN>",
  "checks": [{
    "id": "mail-1",
    "kind": "outlookMessage",
    "resourceId": "<actual Presenter-local message ID>",
    "url": "<同一 actual unsigned resource URL>",
    "account": {"selector": "<可見帳號 selector>", "expected": "<exact Presenter UPN>"},
    "identity": {"selector": "<該資源 selector>", "attribute": "data-message-id", "expected": "<同一 actual ID>"},
    "sender": {"selector": "<實際 sender selector>", "expected": "<實際作者 UPN 或可見名稱>"},
    "content": [{"selector": "<此封完整決策內容 selector>", "expected": "<完整精確文字>"}]
  }]
}
```

`kind` 支援 `outlookMessage|teamsMessage|file|site|documentLibrary|list|listItem|personaPhoto`。
所有種類必須有 account／identity／非空 content；郵件與貼文必須 sender。
若列 `parentId`，還必須有 `parent:{selector,expected:<同一 parentId>}`；
`mention` 同樣是 assertion；`personaPhoto` 必須 `photo` assertion，另核可見 IMG
已載入且 naturalWidth>0。可選 `attribute` 僅限安全 data ID、href、title、
aria-label、alt、src；不採 `body`／`html`／`*` 全頁 selector。
`identity.expected` 必須等於 resourceId，URLs／requiredKinds 的集合必須與 checks 完全一致。
所有 site、default＋explicit library、List 應逐筆用結果直接連結列入；
每封不同作者／parent、每則貼文／reply、每個 Office 檔與所需 List/item 都應有各自 checks。
只列部分不得宣稱完整展示通過。實際前端未曝露穩定 IDs／帳號時保留人工／工具 blocked，
不要編造 selector。核准檔是受信任本機輸入，不是簽章／對抗惡意修改的 sandbox。

```powershell
# 只有另准 live UI、browser session／dependencies 已備妥時才執行；本次沒有執行
.\.venv-live\Scripts\python.exe .\tests\live\verify_presenter.py --opt-in --approval .\private\ui-approval.json --checks .\private\ui-checks.json --approval-id '<人工核准編號>' --presenter-upn '<exact Presenter UPN>' --cdp-url http://127.0.0.1:9222 --report .\private\ui-result-new.json
```

Report 使用 CreateNew，不覆寫既有結果；只存 check IDs／狀態／核准 URL，不抓原始內容、
screenshots 或 credentials。exit `0` 僅限選取 checks 全部 Verified；否則 exit `2`。
未 opt-in／缺 dependency／account 不符／browser 失敗均 blocked。
CDP 本身是高權限的本機 browser 管道；只用專用已核准的工作階段，不對外開 port。
使用者開頁／既有頁面／瀏覽器自身的背景行為不在此工具控制範圍；
本 helper 僅做 DOM 讀取，不宣稱全瀏覽器零網路或替使用者限制其他工具。
未真實操作的 Presenter／effective ACL／UI 與 Copilot 一律 NotVerified。

## 完成／未解項

- 已完成：原創資料與文件、離線結構／情境／資產一致性檢查、缺圖fail-closed及隔離builder驗證。
- Starter：24 張正式合成肖像與 CC0／來源證據已補齊，Persona／rich／minimal 驗證通過；不是 live 成功。
- T8：跨工作負載 integration、無憑證 CI 定義、opt-in readonly UI helper；
  最終實際驗證命令／結果見下方。Hosted CI／真實 Presenter 尚未執行；
  optional `live.lock` 已解析；未進行 live 安裝或驗收。
- 審查：Sonnet 5.5 Rubber Duck 與 GPT-6 Luna 定向 Council 均實際完成。
  Duck 找到 SDK enum 序列化與 SharePoint 新站台讀回等待兩項 Blocking，已修正，
  並由同一 Duck 定向複查解除；Council 無 Blocking。皆指定 `max`，執行 effort 未回報。
  非阻擋的文字提示／進度及文件細節建議保留，不重開已通過範圍。
- 延後：另經具體授權的 live／Presenter UI／Copilot 驗收；未自動 commit、push 或建立 PR。
  沒有超出 T8 的工具鏈或重構。

## 8. T8 本機實際證據（2026-10-31）

環境：Windows、PowerShell `7.6.9`、Python `3.14.7`、uv `0.11.14`。
以下為修正 Blocking 後由主代理重新執行的完整回歸；正式 starter 隨後亦由主代理驗證。
沒有進行 tenant 寫入或以測試 transport 冒充正式網路。

| 實跑指令／檢查 | 實際輸出 |
|---|---|
| `uv run --offline --no-sync python -m pytest -q --tb=short -p no:cacheprovider` | `92 passed in 12.70s`，exit0 |
| `uv run --offline --no-sync python -m pytest -q .\tests\python\test_presenter_verifier.py --tb=short`（最後版本） | `10 passed in 0.37s`，exit0 |
| `pwsh -NoProfile -NonInteractive -File .\tests\powershell\Test-Unit.ps1 -Area All` | `RESULT Passed=150 Failed=0 Area=All NetworkAttempts=0`，exit0 |
| `pwsh -NoProfile -NonInteractive -File .\tests\powershell\Test-Integration.ps1 -ScratchRoot '<已核准的 session 測試副本目錄>'` | frozen final：`RESULT Passed=11 Failed=0 Area=Integration NetworkAttempts=0`，exit0 |
| 全部 engine／tests PS1/PSM1、root entry／requirements.psd1 的 `Parser::ParseFile` | `PowerShellFiles=28 SyntaxErrors=0` |
| 全部 workflow run blocks 的 `Parser::ParseInput` | `WorkflowRunBlocks=6 SyntaxErrors=0` |
| `.\.venv\Scripts\python.exe -m compileall -q .\generator .\tests` | exit0 |
| 第1／2節的真正 CLI Validate | fixture＋personas-only exit0；正式 starter 隨素材補齊後改為 exit0 |
| rich／minimal 的 Python validator | 補齊正式素材後各 `valid:true,errors:[]`，exit0 |
| root config example 的 canonical JSON Schema＋FormatChecker | `ConfigSchemaErrors=0` |

Integration 的初版 fixture／預期碼問題均已修正後才跑上述 frozen final：
Presenter response 補真實契約所需 displayName、正確 `documentLibrary` kind、
依既有服務404 contract 驗 exit1（仍無 build／writes）、動態 Presenter route
以實際觸發 namespace／binding protection。不修改 engine 或弱化 validation。
Blocking 修正只改 SDK enum 正規化及 SharePoint Group／Library／List 的有界 GET-only
404 等待；保留原寫入確認、不重送 POST，403／身分／內容不符仍立即停止。
追加 enum-typed SDK context 與延遲／逾時／權限／漂移回歸；沒有 production refactor。

`NetworkAttempts=0`、fixture read-back／零寫入第二次 RunAll 不等於 live 授權。
Hosted CI、真實 Presenter account／site／Office／List／effective ACL、
搜尋與 Copilot **NotRun／NotVerified**；24 張正式肖像已交付，
optional `live.lock` 已在後續以核准 registry 解析成功，但沒有進行 live 安裝。
各作者自審與整體獨立審查是不同關卡，最後結果以主代理的實際審查紀錄為準。
