# M365DataGenerator — Persona 與跨工作負載展示資料

Python 入口提供公開 JSON 契約、離線驗證與 deterministic 資產準備；**不會登入、
建立帳號、連線租用戶、下載來源檔案、執行工作負載或產生 runner**。
`Invoke-M365Demo.ps1` 整合 `engine` 的明確認證／核准邊界；
不能把離線測試通過當作 live tenant readiness。
`tests\fixtures` 是極小的虛構測試資料；其中的純色 JPEG 只供測試，
不是正式 Persona Pack 或 24 人 starter。

**company-24 隨附 24 位虛構人物與 24 張寫實合成肖像。**
肖像來自 SFHQ Part 2 的 CC0 圖像資料，保留逐圖來源、處理及 SHA-256 證據，
不是真人照片或 sample-pack 照片。資料包可離線驗證；實際 tenant／Presenter UI 尚未驗收，
不可把離線成功稱為 live-ready。

人員有兩種來源，由私有 config **明確選擇**，不會自動掃描租用戶替你決定：
`Managed`（config／personas 1.0）建立受管人員，搭配 company-24；
`Existing`（1.1）採用你在本機 `personas.accountMappings` 逐一指定的既有 Demo 帳號（包含 Microsoft 365 sample pack），
只調整 jobTitle／department／companyName／officeLocation 與 manager，
不改姓名、UPN、照片、密碼、使用地區、授權或角色，不需要席次。
Existing 的公開起點是 `personas\m365-sample`（16 個公開示意姓名，只是提示，不是帳號證明）與
`personas\existing-template`（三個邏輯角色）。人數 N 是你這次選取的帳號數；整批 N 人全部檢查、讀回成功才算完成。
Existing 目前只有離線模型測試，**沒有任何真實人員被檢查或更新**。
教材內容與操作流程見 [getting-started](docs/getting-started.md)、
[data contract](docs/data-contract.md)、[learning guide](docs/learning-guide.md)。

## 快速開始：只做離線 fixture 驗證

在專案根目錄執行；需要 PowerShell **7.5+**、Python >=3.11、`uv`。
已有 `.venv` 且依賴齊備時**不安裝／不 restore**：

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\tests\fixtures\scenario.json -PersonaPackPath .\tests\fixtures\personas.json -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PersonaPackPath .\tests\fixtures\personas.json -PersonasOnly -NonInteractive
```

預期 exit `0`／`Validated`，UI／Copilot 仍 `NotVerified`。
相同命令也可選 `examples\rich-training\scenario.json` 與
`personas\company-24\personas.json`，驗證完整正式 starter，預期 exit `0`／`Validated`。
Existing 的公開配對同樣可離線驗證（pack 與 scenario 必須成對）：
`examples\sample-rich`／`examples\sample-minimal` 搭配 `personas\m365-sample`，
`examples\existing-minimal` 搭配 `personas\existing-template`。
缺圖、雜湊不符或不安全的素材仍會被阻擋，不會以測試圖補位。
`Validate` 不讀 config、SDK、secret 或登入；不要將 fixture 用於 live。

### 首次環境建置與回歸

只在首次缺依賴或 manifest 變更、且已允許套件網路存取後，於工作站執行：

```powershell
uv venv .venv
uv pip sync --python .\.venv\Scripts\python.exe .\dev.lock --require-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/
```

`requirements.lock` 是 runtime hash lock；`dev.lock` 包含 runtime 與 pytest。
lock 不內嵌 index；工作站使用上述 proxy，Windows hosted CI 明列官方
`https://pypi.org/simple/`，不改全域設定或靜默 fallback。
所有連線模式一律使用同一 App 的 client credentials；`requirements.psd1` 不再要求 Graph SDK。
secret 只從設定所指定的 process 環境變數讀取，不寫入 config。離線測試不需要 tenant secrets。

更新依賴時：

```powershell
uv pip compile .\pyproject.toml --python-version 3.11 --generate-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/ --output-file .\requirements.lock
uv pip compile .\pyproject.toml --group dev --python-version 3.11 --generate-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/ --output-file .\dev.lock
```

```powershell
uv run --offline --no-sync python -m pytest -q --tb=short
pwsh -NoProfile -NonInteractive -File .\tests\powershell\Test-Unit.ps1 -Area All
pwsh -NoProfile -NonInteractive -File .\tests\powershell\Test-Integration.ps1
```

Integration 真正呼叫 production Console／provisioning／全部 adapters，
僅使用隔離的 synthetic fixture **副本**與完整注入的離線模型；不連 tenant，
不以執行 area unit tests 代替整合。詳見 [測試、實際證據與 opt-in UI 邊界](docs/testing.md)。
加入 Existing 帳號來源（v1.1）後的本機離線回歸（Python 與 PowerShell 各 area 分別執行）：
Python `135 passed`；PowerShell Identity `62`、Personas `32`、Storage `27`、Outlook `13`、
Teams `16`、Console `34`，皆 0 失敗；Integration `16/0`；各 PS runner 均 `NetworkAttempts=0`。
28 份 PowerShell entry 解析零錯誤，正式 Persona／rich／minimal、Existing 公開配對與 CLI 驗證通過。
Hosted CI／真實 Presenter 未跑；optional Playwright 的 `live.lock` 已由核准的工作站
registry 解析產生，但未安裝或執行 live，不宣稱完整驗收或 starter 釋出成功。

先前 Managed 發行的獨立 Sonnet 5.5 Rubber Duck 及 GPT-6 Luna 定向 Council 已完成審查；
SDK enum context 與 SharePoint 佈建等待的兩項 Blocking 已修正並由同一 Duck 複查解除。
兩位皆指定 `max` effort，工具未回報實際 effort；這不代替真實 tenant／Presenter 驗收。
Existing 帳號來源只完成離線實作與測試：**尚未經獨立審查，沒有任何 live 驗證，也沒有任何真實人員被檢查或更新**。
同樣只有離線實作與測試的還有：移除「目標帳號持有目錄角色就拒絕」的規則，以及既有帳號的自動解析／本機一次選人／帳號更正保存；
上列回歸數字是加入 Existing 來源時的歷史結果，後續這些修改只重跑受影響的 Personas／Console／Identity（`admin|Existing`）／Integration（`Existing`）案例，未重算全部 area。

## 私有 config 與 live 前置條件

`Copy-Item .\config.json.example .\config.json` 只建立本機設定，不授權登入或寫入。
`config.json.example` 現在是 **Existing（`schemaVersion` 1.1）** 的占位範例；
Managed（1.0）的設定形狀見 [getting-started](docs/getting-started.md) 與 synthetic 的
`tests\fixtures\managed-config.json`。範例 GUID／`example.invalid` 都是佔位值；
需由管理者私下替換 tenant、seed app、既有 Presenter，並在 `personas.accountMappings`
逐一填入你選定、專用於 Demo 的既有帳號（Existing 不需要席次／SKU，也不改授權）。
Managed 另需已訂閱且有足夠餘額的實際 SKU 與合法人物素材（自訂其他公司時）。
Managed 的 `m365-demo` profile 對應 company-24；`standard` 僅供 tests fixture 的獨立 profile，
不是另一筆購買／配額，正式設定可移除未使用 profile。不要拿 tenant 帳號數推算可用席次。
`clientSecretEnvironmentVariable` 是 process 環境變數**名稱**，不是 secret；
不把私有 config／binding／journal／名冊／token 傳給 AI 或加入 Git。

填妥設定且**另獲精確 live 授權後**，管理模式與每日匯入分開：

```powershell
# 以下是操作方式，不是本次 live 實跑紀錄，也不是 live 授權
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode InitializePersonas -ConfigPath .\config.json
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Preflight -ConfigPath .\config.json -PackPath .\examples\rich-training\scenario.json
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode RunAll -ConfigPath .\config.json -PackPath .\examples\rich-training\scenario.json
```

上列 Preflight／RunAll 以 Managed 配對的 rich-training 為例；Existing 請改用配對的 scenario
（例如 `examples\sample-rich\scenario.json` 搭配 `personas\m365-sample`）。

Managed 的初始化必須另核准確切 UPN／field diff／JPEG／SKU／數量，並確認 target＋fingerprint；
Existing 則先處理帳號對應：你指定的 UPN 存在就沿用；不存在時以公開姓名／alias 提示做有界精確查找，
唯一完整匹配只是提議，多筆／相似／找不到則由你在本機**一次**明確選擇（這不是寫入同意）。
接著整批唯讀檢查全部 N 位帳號（身分、manager、既有 profile；不檢查也不修改目標帳號的目錄角色），
由共用 renderer 顯示修改提醒、`原指定帳號 → 實際帳號` 與逐人 `Before → After`，確認 target＋fingerprint，
**並由使用者本人輸入 `DemoAccountAcknowledged`**（`-DemoAccountAcknowledged`，表示你已核對並同意這批實際帳號的 profile 更新）後，
才逐人寫入四個欄位與 manager 並整批讀回；完整讀回後，經核准的帳號更正才存回私有 config 的 `accountMappings`
（只改這一欄，無法保存時標 `LocalConfigSyncRequired`，不重做遠端更新）。
任一人 Block、Unknown 或讀回不符，整批不標成功、不重試、不回滾。
Existing 的完成 binding 是 `ConfiguredExisting/NotVerified`，不當作工具建立的 `Provisioned`。
`Provisioned/NotVerified`／`ConfiguredExisting/NotVerified` 都不代表 mailbox／drive 已就緒。RunAll 使用獨立 app-only
認證、完整服務 gate／全域 preflight／`tenantId/runId` 確認，永不暗中初始化。
缺 secret、錯 mode／paths、無互動 stdin、確認不符、碰撞、未知 POST 都停止，
不自動 consent、重寄、補權限、刪人或移除 license 清場。
只完整相符的 Completed run 才唯讀 Skip／Verify；不要改 runId 來繞過 partial／unknown。
只有 actual read-back 連結才可作 site／library／List 入口；GraphStructural
不等於 Presenter effective ACL／UI／Copilot 已驗。

## CLI

### Console／PowerShell 入口（PowerShell 7.5+）

```powershell
# 無 Mode：數字選單；0 直接離開
pwsh -NoProfile -File .\Invoke-M365Demo.ps1
# 完全離線，不需要 config、SDK 或 secret；測試素材不代表正式 starter
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate -PackPath .\tests\fixtures\scenario.json -PersonaPackPath .\tests\fixtures\personas.json -NonInteractive
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Validate --personas-only -PersonaPackPath .\tests\fixtures\personas.json -NonInteractive
```

`Mode` 支援 `RunAll|InitializePersonas|InspectUsers|Validate|Preflight|Import|Verify`。
連線模式須明列本機 `-ConfigPath`；Presenter 在啟動時輸入／確認，也可用
`-PresenterUpn` 或 config 提供。只讀最低限度 config 後立即登入，才讀 Scenario、
驗照片、做 diff／素材建置。CLI 的 pack 路徑以目前目錄解讀；config 內的
`personas.packPath`／`bindingPath` 則以 **config 所在目錄**為基準，均採 literal path。

Config 1.0（Managed）的最小 schema 調整：root 僅共同要求
`schemaVersion/tenantId/presenterUpn`；各欄位的型別、巢狀 required 與未知欄位拒絕不變。
Config 1.1（Existing）以 `personas.accountSource:"Existing"` 與 `accountMappings`（personaId→既有 UPN）
取代 `accountPrefix/userDomain/usageLocation/licenseProfiles`，其餘共同欄位相同；
config 與 public pack 的來源必須一致，Existing 與 Managed 不會混用。
入口另外要求資料模式的 `clientId/clientSecretEnvironmentVariable/personas/runId`，
初始化要求完整 `personas`，Inspect 不要求 seed app／secret／人員素材。
`adminAuth` 可省略；省略 clientId 使用 pinned SDK 的真正預設 client，
省略 operator 則用選定的 Presenter，顯式 operator 不被替換。
Schema 改變會使先前 prepared package 的 schema fingerprint 不相符；不遷移或覆寫。

管理模式僅載入 `Microsoft.Graph.Authentication 2.36.1`，使用 process device code；
production 禁用 `-NonInteractive`。Existing 的管理 delegated scopes 是
`User.Read.All, User.ReadWrite.All, RoleManagement.Read.Directory`（Managed 另含照片、授權、網域 scopes）。
資料模式使用 app-only `.default`，先驗 token／
既有 Presenter，再依實際選取 workload 驗 application roles，絕不混用管理 token。
SharePoint 檔案的實際 `/drives` 寫入另外要求 `Files.ReadWrite.All`。
初始化必須確認完整 diff 的 `tenantId/instanceId` **及**當前 fingerprint（Existing 另須
`DemoAccountAcknowledged`）；
RunAll／Import 必須確認 `tenantId/runId`。非互動匯入須額外明列精確
`-ConfirmTarget`；`-NonInteractive` 只略過最後等待，並非同意寫入。

RunAll／Import 共用完整全域 preflight、Storage→Outlook→Teams、Completed Verify。
Preflight 不建 journal；Verify 必須有原 prepared／Completed journal。
只完整、精確、重新讀回的既有 run 能 Skip；partial／unknown 不自動續跑。
私有 journal 固定為 config 旁 `state\runs\<runId>\run-state.json`；
prepared 固定為 `runs\<runId>\prepared`，既有目錄只做精確比對。
每次呼叫在 `runs\reports\<unique-id>` 新建不可覆寫的 `summary.json/summary.md`。
新私有目錄 ACL 僅允許目前使用者與 SYSTEM；既有非私有目錄直接阻擋，不改其 ACL。

摘要逐 workload 列 Created／Skipped／Failed／Blocked／Unknown，保留每個實際
site／default 與 explicit library／List URL。SharePoint 的 GraphStructural 證據
不是 effective ACL 或真實 Presenter UI／Copilot readiness；不使用 GA shortcut。
Exit 0=所選模式完成、1=未造成已知部分寫入的執行失敗、2=輸入／確認／preflight
阻擋、3=部分寫入或結果未知。預設成功及失敗均先摘要再等 Enter；
無可互動 stdin 會在寫入前拒絕，必須明列適用的 `-NonInteractive`。

以下 Python 入口仍可獨立使用：

```powershell
.venv\Scripts\python.exe generator\validate_pack.py --personas tests\fixtures\personas.json
.venv\Scripts\python.exe generator\validate_pack.py --pack tests\fixtures\scenario.json --personas tests\fixtures\personas.json
New-Item -ItemType Directory -Force runs | Out-Null
.venv\Scripts\python.exe generator\build_scenario.py --pack tests\fixtures\scenario.json --personas tests\fixtures\personas.json --output runs\example
```

Validator 成功輸出 `{"valid":true,"errors":[]}`（exit 0）；失敗輸出
`{"valid":false,"errors":[{"path":"...","code":"...","message":"...","remediation":"..."}]}`（exit 2）。
`path` 是 `$personas` 或 `$scenario` 加 JSON Pointer；輸入／CLI 錯誤為 `$`／`$arguments`。
Builder 成功回傳 `prepared`、`output`、`fingerprint`，失敗為 `prepared:false` 與 `errors`（exit 2）。
兩個入口均可透過 Python subprocess 呼叫，不需要任何認證或環境密鑰。

## 契約

`schemas` 的五份 JSON Schema 均為 draft 2020-12；Managed 版本為 `"1.0"`，
Existing 的 personas／config／binding 為 `"1.1"`（同一份 schema 以 version 分支，scenario 與其餘仍是 `"1.0"`）。
所有物件皆關閉額外欄位；名稱索引的 map 僅透過受限 `patternProperties` 開放。
使用一般 JSON Schema validator 時須啟用 format checking。
跨物件參照、角色、時間、HTML、檔案與循環規則還需執行 `validate_pack.py`，
不能只用 JSON Schema 判斷有效。

* **personas**：`packId/version/company/businessUnits/people/avatarAssets`。
  `managerRef` 為 nullable persona ID；`avatarAssetId` 與 `licenseProfile` 是公開邏輯 ID。
  公開人物不能包含 UPN、password 或 tenant objectId。
  Portrait 的 SHA-256、相對路徑與解碼像素不可重複，rights 必須有本機 UTF-8 evidence。
  Existing（1.1）為 `packId/version/accountSource:"Existing"/company/businessUnits/people`，
  每人只有 `personaId`、可選 `identityHint`（姓名／alias 提示，非帳號證明；只在你指定的 UPN 不存在時用於有界精確查找，仍須你確認）、
  可選 `profile` 的四個文字欄位與 `managerRef`；沒有肖像、授權或帳號資料。
* **scenario**：`schemaVersion/scenario/roles/stories/assets` 與至少一個
  `outlook/teams/onedrive/sharepoint`。`Presenter` 為保留角色，不得出現在 `roles`，
  不得作為歷史訊息作者；執行時由私有 `presenterUpn` 解析。
  每個一般角色只對應一個不同 persona；business unit 必須存在。
* **Outlook**：唯一形狀是 `outlook.threads[].messages[]`，不是 `emails`。
  第一封 `action:send,parentId:null`；後續 `reply` 必須參照同 thread 先前訊息，
  作者必須是該 parent 的 To/CC 收件者。每封 To/CC 必須包含 Presenter。
* **Teams**：根訊息有 `replies`，reply 不得再巢狀回覆。
  `fromRole` 是實際作者；`createdDateTime` 必須包含 offset，
  不可晚於 `anchorDate` 在 IANA `timeZone` 的當日結束。
  root 與各回覆序列須嚴格遞增；reply 晚於 parent。
  mention 為 `{id,role,text}`，id 從 0 連續編號，
  `<at id="n">角色標籤</at>` 必須與陣列依序相符，`text` 等於 role key。
  downstream 應以 binding 解析真實身分，不可把顯示文字當作身分證據。
* **HTML/asset**：僅允許段落、表格、強調、清單、換行與安全 HTTP(S)/mailto/asset-token 連結；
  只有 Teams 可用 `at`。拒絕 script、event、img、任意 attribute 與不完整標記。
  `{{asset:id}}` 必須已宣告且列於該訊息 `assetRefs`。
  每個 asset 只有一個已宣告 upload destination，大小寫不敏感去重；
  OneDrive owner 不得重複，檔案路徑也不得同時是另一資產的父資料夾。
* **Workbook**：asset 選 `workbookId`，或選本機 `localPath+sha256`，兩者互斥。
  recipe 的每張 sheet 選 `rows` 或 `generate`。
  每個 column 明確指定 `string/number/integer/boolean/formula`；
  只有 formula column 可提供 `formula`，rows 中該欄以 null 佔位，
  模板僅代換 `{row}`。一般字串即使以 `=` 開頭也保持字串。
  generate 固定為 string/string/integer-or-number 三欄，
  使用 seed、dimensions、periods、min/max 與精確 overrides。
* **Lists**：column 有 `id/name/type`，choice 額外要求 choices；
  每個 item 的 `values` 必須恰好使用所有 column IDs，型別與 choice 值精確相符，
  不做字串／布林／數字轉型。整數限制於 JSON 安全整數範圍；
  number 必須有限且絕對值不超過 `1e308`。
* **Private config**：依 `config.json.example`（Existing 1.1）或 `tests\fixtures\managed-config.json`（Managed 1.0）；只引用
  `clientSecretEnvironmentVariable`，沒有明文 clientSecret。
  optional `adminAuth` 的 `clientId/adminOperatorUpn` 可分別省略，採上述模式預設值。
* **Private binding**：root 為
  `tenantId/packId/version/fingerprint/instanceId/users/status/serviceStatus`。
  `fingerprint` 是下述 Persona Pack fingerprint。
  `users[personaId]` 有 `objectId/upn/profile/photo/license/status/serviceStatus`。
  root 與 user 均固定 `Provisioned/NotVerified`：帳號證據不等於 workload readiness。
  Existing（1.1）binding 另有 `accountSource:"Existing"`、`approval`（計畫 fingerprint、
  `demoAccountAcknowledged`、journal fingerprint、時間），user 為 `source:"BindExisting"`，
  沒有 photo／license，狀態是 `ConfiguredExisting/NotVerified`；它只由已完成、讀回驗證的
  `BindExisting` journal 證據支持，不是工具建立的 `Provisioned`。
* **Run state**：`schemaVersion/runId/fingerprint/context/status/events/results`。
  context 包含 tenantId、clientId、presenterUpn 與 pack/binding/prepared 的精確 fingerprints，
  不把不同應用程式的執行視為同一 run。
  `Completed` 只能有非空、全數 `Verified` 的 results，每項須有 objectId 與 ReadBack evidence；
  存在 `Partial/Unknown` result 時 root 必須是 `Blocked`。
  downstream 必須另外比對本次精確 context、預定 result IDs、唯一性與權威 read-back；
  不能只憑檔案的 status 或 hash 視為 tenant 已驗證。

## Prepared 輸出與 fingerprints

輸出包含 `scenario.json`、`personas\personas.json`、原相對路徑的 portraits/rights、
`assets\<assetId>.<type>`、`prepared-manifest.json` 與最後寫入的 `COMPLETE.json`。
本機 asset 的 `localPath` 會改為 prepared 內部路徑；因此輸出可離開原始來源目錄驗證。
workbook asset 保留 `workbookId`，產生檔案以 manifest 的 `relativePath` 為準。

Canonical JSON 定義為 UTF-8、`ensure_ascii=False`、`sort_keys=True`、
compact `(",",":")`、不允許 NaN，尾端加一個 LF。
`generator.build_scenario.persona_fingerprint(path)` 對
`{"personas":公開文件,"files":{正規化相對路徑:檔案SHA256}}` 的 canonical bytes 做 SHA-256；
files 包含所有 portrait 與 rights evidence。
`schemaFingerprint` hash 所有 schema 檔名→原始 bytes SHA-256 map；
`builderFingerprint` 同法 hash 兩個 Python 入口。
`sourceScenarioFingerprint` 是原始 scenario 文件的 canonical hash。
manifest `fingerprint` 是排除自身 `fingerprint` 欄位後的 canonical hash。
`files` 列出其他 payload 的 hashes，不含 manifest 與 COMPLETE，避免自我參照。
COMPLETE 記錄 `schemaVersion/fingerprint/manifestSha256`。

新輸出只在驗證與所有 bytes 準備成功後建立；可捕捉的寫入失敗會清除本次新建目錄。
已存在目錄不覆寫、不修復；必須逐檔 bytes、目錄集合、manifest、completion marker
全部與本次重建結果相同才可唯讀重用。更換 schema/builder、來源、檔案內容或新增檔案皆會阻擋。
這是完整性檢查，不是數位簽章，也不授權任何 tenant 寫入。

`builderFingerprint` 涵蓋 `generator\build_scenario.py` 與 `validate_pack.py` 的實際 bytes，所以 builder 的任何修改
（例如移除 workbook 固定的 description 屬性）都會讓舊 builder 建立的 prepared 目錄不再相符；
Team 與文件庫可見名稱改版另會改變計畫 fingerprint，舊 journal／run proof 不能當作新計畫的完成證據。
Preflight／RunAll／Verify 會在任何內容寫入前阻擋（`Seed.Input.Prepared`），舊 prepared 與 journal 不遷移、不覆寫、不修復、不刪除，
工具也不會自動更換 `runId`；要用新版重新匯入，由你明確選擇新的 `runId`（新的 `runs\<runId>\prepared` 與 journal）。
要驗證舊 run，必須使用建立它的舊版程式碼與原 prepared／journal。

路徑拒絕 absolute/UNC、`..`、ADS、device 名稱及任何 reparse point；
JPEG 上限 4 MiB、8192 最大邊與 16 million pixels。
本機 assets 上限 32 MiB；Office archives 最多 10000 entries、解壓 64 MiB，
須具有正確 content type 與可解析 main XML；XLSX 另需能以 openpyxl 開啟。
不提供人臉辨識或感知相似度去重；不同裁切／重新壓縮的同一人物仍需人工審核。

Workbook ZIP 正規化參考 MS-4018 的 `seed-data\generator\build_scenario.py`；
MIT attribution 保留於程式碼與 `LICENSE`。未修改該來源專案。

## T3 Storage adapter

先依 T2 載入 Graph／journal／identity／preflight helpers，再 dot-source
`engine\Seed-OneDriveOwnership.ps1`、`engine\Invoke-SeedSharePoint.ps1`、
`engine\Invoke-UploadFiles.ps1`。載入本身不認證、不發送請求。

`Get-SeedStorageAdapter -Session -Scenario -PreparedPath -Context -RunId -StatePath`
要求已核對的 T2 identity／services 與完整 prepared package，回傳 session-bound handle：
`Operations`、`ResourceChecks`、初始 exact `Requests`、晚綁定 `RequestCheck`。
把所有 selected adapters 的 operations／checks 合併後，才呼叫
`Get-SeedOperationPlan`／global preflight、建立 journal、取得 exact tenant/run 確認，
並呼叫 `New-SeedWriteApproval`。任一 Block 都不開始匯入。

`Invoke-UploadFiles -Session -Adapter -Plan` 執行全部已核准的 Storage operations；
`Invoke-SeedSharePoint` 是同一個原子流程的入口別名，**不是 partial repair 模式**。
每個遠端寫入先 durable Submit，實際 GET 證實後才 Verify。只有完整相符的 Completed
journal 與新的遠端證據才 Skip；Unknown／Partial／失聯／碰撞不續跑、不刪除、不補權限。
新建 SharePoint Group／文件庫／List 的讀回僅對實際 Graph 404 輪詢，
每個資源最多等候 36 次、每次 5 秒（180 秒）；每輪重新驗證完整結構，不重送任何寫入。
403、擁有者／profile／sharing／schema 不符立即停止；逾時保留 Unknown 與已知遠端 ID。
重跑先用全域 operation 集合 `Get-SeedRunState`，再
`Set-SeedStorageRunState -Session -Adapter -RunState`，最後重新建立全域計畫。
`Test-SeedStorage -Session -Adapter` 是 GET-only Verify，不會取得寫入能力。

僅使用 Presenter 自己的 OneDrive 與 run-namespaced 新資料夾。SharePoint 只建立新的
Private Unified Group，原子設定實際 Presenter／selected actors 的 owners／members，
另外建立名為 `Project Documents` 的文件庫與 typed Lists；site 的 List 若與此名稱相同
（忽略大小寫與前後空白），建立 adapter 時即以 `Seed.Storage.Collision` 停止，早於任何遠端寫入。
檔案預設使用 Graph small-file PUT，URL 必須帶精確的
`@microsoft.graph.conflictBehavior=fail`；缺少此參數、replace／rename 或其他 query 均不能
取得檔案寫入能力。既有檔案衝突即停止，不覆寫。上限仍為 32 MiB；安全路徑額外拒絕 `%`／`#`。
低階 adapter 可明確指定 `-UseUploadSessions` 使用原 session 路徑，CLI 不會在失敗後自動切換，
也不重送 Unknown；preauthenticated URL 不寫入 journal／輸出。不提供 owned-group adoption。

回傳的 `AssetUrlMap` 是 asset ID → `{webUrl,targetWorkload,resourceId,sourceSha256,presenterVerified}`；
`ResourceLinkIndex` 包含每個 site、明確建立的文件庫／List，以及 Group site 自動建立的預設文件庫。
所有連結均來自實際 GET 的 unsigned `webUrl`。
Office 的 `Doc.aspx` canonical viewer URL 只允許固定參數，且文件 GUID／檔名／host
必須與實際檔案及父層讀回一致；不接受簽章、token、分享或未知參數，也不剝除 query 猜測連結。
Sharing evidence 只容許不授與新權限的唯讀 `existingAccess` copy link，且不保存其 URL；
其他分享 scope、invitation 或觀測到的權限漂移仍停止，並不以此聲稱已驗證完整 SharePoint ACL。
新 SharePoint 操作使用 `SharingEvidenceVersion=2`：比對 V2 主體類型／穩定 ID 與角色的完整配對，
不以佈建時會改變的 permission alias、名稱、email 或 loginName 判斷權限變更。
缺少主體 ID、矛盾 alias、重複授權、非支援版本或實際到期時間一律拒絕；
僅缺席／null／Graph 的 `DateTime.MinValue` sentinel 表示無到期日。
保留已回傳的 `inheritedFrom`，缺席時不推定為直接授權。舊版收據不重設或遷移。
欄位使用由 canonical column ID 決定的
`seed_<hash>` internal name；displayName 保留 canonical name，不以 Title／筆數判定相符。

**SharePoint 使用既有 Graph-only 認證／設定，不另需 REST audience、certificate 或 backend。**
只接受本工具在同 run 新建的 Private Unified Group site：
實際 `/groups/{id}/sites/root` 關聯、Group profile、完整 owners／members IDs
（Presenter 必須同時在兩者）、application content GET／schema／hash／完整 collections 都須相符。
新文件庫／Lists／子項目不設定個別權限，沿用建立時的預設繼承；
`StorageScope.PermissionModel` 與成功 exact create request／actual ID 的來源證據納入 read-back digest，
並由原 journal 的 plan／Submit／Verify history 綁定。完整重跑須重新讀回並比對這些證據，
缺失／改變／舊格式 receipt 不能 adoption 或 repair。

回傳 `PresenterProof:{Kind:'GraphStructural',ActualUiStatus:'Required',RemoteAclStatus:'NotProven',Limitation:...}`；
SharePoint `ResourceLinkIndex.presenterAccessStatus` 為 `StructuralVerified`。
`presenterVerified:true` 是相容的**結構檢查**旗標，`Verified:true` 只指 journal／application
read-back 驗證，**都不代表 Presenter 實際 UI 或 effective ACL 已通過**。
Graph `/sites/{id}/permissions` 不會列舉一般使用者 ACL，故不以它做證明。
Drive item sharing permissions 只用來拒絕已觀察到的 link／invitation 與偵測 receipt 漂移；
空集合或沒有 `inheritedFrom` 絕不當作繼承成立的依據。
Graph 無法完整觀察任意遠端 SharePoint ACL／繼承變更，這個缺口不會被標成通過：
**仍需實際 Presenter UI 開啟網站、文件庫、文件與 Lists**，也未證明 Conditional Access／Copilot readiness。
未知既有容器、可觀察的 unique sharing、身分／內容／建立證據不足一律停止，不補權限。

注入 Graph transport 時若有檔案，亦須提供
`UploadTransport`：`param($Url,$Bytes,$Headers)`；`Bytes:$null` 表示 GET session status，
否則為 exact PUT。它不得加 Graph Authorization、retry 或 redirect。
正常 app transport 已有 unauthenticated upload continuation 與有界 binary GET／redirect 處理。
這些 backend 是受信任的程式碼，不接受 public pack 提供。

離線驗證：

```powershell
pwsh -NoProfile -File .\tests\powershell\Test-Unit.ps1 -Area Storage
pwsh -NoProfile -File .\tests\powershell\Test-Unit.ps1 -Area All
```

可用 `-CaseName '<regex>'` 聚焦行為案例；不會啟用網路或認證。

## T4 Outlook adapter

在 T2 helpers 後 dot-source `engine\Invoke-SeedEmails.ps1`。載入不認證、不寄信。
`Get-SeedOutlookAdapter -Session -Scenario -PreparedPath -Context -RunId -StatePath`
核對 canonical prepared package、T2 實際身分／Inbox，回傳 authentic session-bound
`Operations`、`ResourceChecks`、初始 exact `Requests`、晚綁定 `RequestCheck`。
所有 mail writes（包括每封 reply）、原始 HTML／素材 SHA256、實際作者／完整收件者、
parent 關係與 context/run-unique subject 都在全域計畫及 journal 預先綁定。
不以 Presenter 代寄、不偽造歷史寄送時間。

有素材時先建立同 run 的 Storage adapter，再建立 Outlook adapter，合併完整 operations／
checks／initial requests 後才做全域 preflight、journal 與一次性 approval。
Storage 完成後，將它**原樣回傳的同一個** `AssetUrlMap` 傳給
`Invoke-SeedEmails -Session -Adapter -Plan -AssetUrlMap`（無素材時用 `@{}`）。
不接受 public pack URL、手工 map、複製／反序列化 map 或 caller-edited map。
執行時重新 GET 驗素材 ID／內容／Presenter access／URL／journal evidence，才解析
`{{asset:id}}`；缺 key、hash 不符或未解析模板一律先停止。
素材連結尚未知的首信，以預先列出的 Storage content operation 作 exact late-binding parent；
不在原核准計畫的內容不能臨時加入。

首信用實際作者的 `POST /users/{id}/sendMail`；回覆用實際作者 Inbox 的 mailbox-local
parent ID 呼叫 `POST /users/{id}/messages/{localParentId}/reply`。
只需 application `Mail.Read`／`Mail.Send`，不建立／PATCH draft、不要求 `Mail.ReadWrite`。
先以 Presenter 讀回的 `internetMessageId` 在作者信箱找 parent，**不假定各信箱
`conversationId` 相同**。每封明列 Presenter 在 To 或 CC。

`202 Accepted` 不算完成。每封須以真正 Inbox detail GET，驗完整 from／sender／To／CC、
Message-ID、首信 run header、reply 的 In-Reply-To／完整 References chain，以及完整
normalized HTML（含格式、表格、文字與連結）；另驗全部宣告收件者 Inbox 的同一 Internet ID。
HTML proof 只容許明列的伺服器 wrappers／presentation normalization，不接受內容子字串、
subject/count-only proof 或自動忽略引用文字；若伺服器改寫成不支援的格式，保守停止。
GET propagation polling 每次最多 31 輪、間隔 2 秒（最多等待 60 秒）；collection 最多 20 頁，
另沿用 T2 bounded transient GET retry。POST 永不重送。

回傳 `{Messages,Threads,Verified}`；逐封 evidence 含每個 mailbox-local ID／conversation ID、
Internet ID、完整 body／headers／recipient proof 與 parent 關係。
全域仍有其他工作未完成時 `Verified:false`，不宣稱整體完成。
只有全域 exact Completed journal 能 Skip；重跑／Verify 先以完整全域 operations
`Get-SeedRunState`，再 `Set-SeedOutlookRunState -Session -Adapter -RunState`。
`Test-SeedOutlook -Session -Adapter [-AssetUrlMap]` 是 GET-only；素材 Verify 可先由
`Test-SeedStorage` 取得 genuine map，或由同 context 的 Completed Storage adapter 唯讀解析。
額外／缺少郵件、錯誤內容、任何 partial／pending／Unknown 均阻擋；不 resume／repair／重寄。
已接受但回應遺失／讀回逾時的郵件保留 durable Unknown（或未能更新時的 Submitted）。
實際 live Graph／郵件服務／Presenter UI readiness 尚未驗證。

```powershell
pwsh -NoProfile -File .\tests\powershell\Test-Unit.ps1 -Area Outlook
```
### Teams adapter（T5，僅離線驗證）

先載入 T2 identity／service helpers，再 dot-source `engine\Invoke-SeedTeamsChannel.ps1`。
需要時會載入既有 Outlook 的 prepared-package／Storage provenance readers，
不執行郵件或認證流程。

* `Get-SeedTeamsAdapter -Session -Scenario -PreparedPath -Context -RunId -StatePath`
  回傳 authentic session-bound handle，含 `Operations`、`ResourceChecks.teams`、
  initial `Requests`、`RequestCheck`。
* `Set-SeedTeamsRunState -Session -Adapter -RunState` 只接受 T2 完整驗證的
  Planned 或全域 Completed durable journal。`Get-SeedRunState` 必須使用完整全域
  operations；不接受 partial／unknown resume。
* `Invoke-SeedTeamsChannel -Session -Adapter -Plan -AssetUrlMap` 消費既有 global approval。
  有素材時先執行 Storage，傳入它原樣回傳的 map。
* `Test-SeedTeams -Session -Adapter [-AssetUrlMap]` 是 GET-only，要求 exact 全域
  Completed journal。fresh asset Verify 同樣須先建立同 run 的 genuine Storage adapter；
  序列化／複製的 map 不是 provenance。

在 global preflight／approval 前合併所有 adapters 的 operations、checks、initial
requests；任一 Block 即整次停止。唯一 initial Teams request 是 exact `POST /teams`：
standard template、初始 migration mode、private visibility、歷史建立時間、
可見名稱 `<scenario.title> [<namespace 前 8 碼>]`，以及 description 內完整的
`M365Seed:<namespace>` 擁有權標記。任何既有同名 group（包括自己擁有的）
都是碰撞。不接受 arbitrary Team/channel、adoption、既有資源 migration、
beta fallback、repair、一般 write retry、consent 或 directory-write capability。

唯一寫入重試例外限同一 dispatch 內已核准、無 body 的 channel `completeMigration`：
遇 HTTP 502／503／504 時，先 GET 同一已驗證 channel 的 `id`／`migrationMode`。
讀回 `completed` 即不重送；只有 `inProgress` 才可在 2 秒間隔後有界重送，
總共最多 3 次 completion POST、共用一筆 durable Submit，最後一次失敗亦再核對狀態。
缺欄位、錯誤 ID、未知狀態或讀取失敗仍是 Unknown。
此例外不適用 team completion、訊息、郵件、會員、檔案或人員操作，
也不恢復任何已結束的 Unknown run。

`scenario.title` 直接成為 Team 顯示名稱，沒有固定的「Demo Team」前綴。schema 的 text 上限是 65536 字，
不足以代表 Team 名稱，所以 adapter 在任何寫入前另外要求 title 為 1–200 字、與 `Trim()` 後相同
（前後無空白）、不含控制／格式／行分隔字元，否則以 `Seed.Input.TeamName` 停止（不改寫、不截斷）。
名稱後綴只讓相同 title 的不同 run 彼此區分；擁有權仍由完整 namespace、journal 與 read-back 決定，不由名稱決定。
同名查找把單引號加倍後再 percent-encode，CJK 或含 `'` 的標題不需額外處理。

每個 custom standard channel、root／reply、每個 channel（含 intrinsic primary／General）
的 completion、team completion、Presenter group owner、Presenter Team owner，
以及 Presenter 與其他 actual actors 各自的 directory group membership／Teams membership，
都在首次寫入前列入完整計畫。每位人物先對同一新 group 明確加入 `members/$ref` 並完整讀回，
再加入 Teams；不假設 Teams roster 或 group ownership 會自動產生 directory membership。
未知 parent ID 只能在 fresh GET evidence 等於 Verified journal receipt 後晚綁定。
全程使用同 application/client 與 run context。Standard channels 繼承 Team 的 actor
聯集與 Presenter；`memberRoles` 不是 private-channel ACL，也不必顯式列出 Presenter。

僅使用 Graph v1.0 的初始 `teamCreationMode`／`channelCreationMode` annotations、
channel `messages`／`replies`、channel 然後 team `completeMigration`、
`groups/{id}/owners/$ref`、`teams/{id}/members`。Application roles：
`User.Read.All`（T2 identity）、`Team.Create`、`Teamwork.Migrate.All`、
`Group.ReadWrite.All`、`TeamMember.ReadWrite.All`、`Team.ReadBasic.All`、
`Channel.ReadBasic.All`、**`ChannelMessage.Read.All`**。Storage 權限另外沿用；
沒有新增 endpoint wildcard。

作者使用 actual mapped IDs，不讓 Presenter 或顯示文字冒充作者。Mention HTML 以
目前已驗證的 actual displayNames 重新產生並 HTML-escape，逐項讀回 mention identities、
IDs／labels。歷史時間不得超過 canonical reference anchor 或 current wall clock，
最多毫秒精度；不支援的精度直接拒絕，不截斷。Actual team／channel 建立時間亦讀回，
channel 必須早於匯入訊息。驗證完整 root／reply ID 集合、actual parents、作者／時間、
完整 normalized safe HTML／links、mentions、standard channel identity、
actual group／Team membership／ownership 及 authoritative unsigned Teams links。

Channel completion receipt 必須以 v1.0 GET 讀回同一 channel 的 `migrationMode=completed`，
並保留完整 resource/content evidence；正常 ACK 與上述限定 gateway 恢復使用相同證據形狀。
Team completion 仍要求單次成功回應及 actual post-migration membership 讀回，
不假造 team 的完成屬性。完整驗證的 Completed rerun **零寫入**，含零 completion／membership calls。

輸出 `{Team,Messages,ResourceLinkIndex,Verified}`。Index 沿用 Storage 形狀，
`kind:team|channel`、`presenterAccessStatus:'Verified'`；所有網址只取自實際 resource GET。
缺連結／內容／membership 就 Verify 失敗或保留 Unknown，不猜網址、不恢復操作。
GET propagation polling 最多 31 輪、間隔兩秒，只限尚未可見的資源／404／純缺預期訊息 ID；
內容或權限錯誤立即停止。離線測試不代表 live tenant／policy／UI／Copilot readiness。
