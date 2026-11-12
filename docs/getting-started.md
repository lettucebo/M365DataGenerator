# 操作指南：先設定與認證，再初始化或執行課程

## 目前能做什麼

人員有兩種**明確選擇**的來源，不自動掃描租用戶後替你決定：

| 租用戶狀況 | 選用路徑 | 要點 |
|---|---|---|
| 只有 Presenter／管理帳號，沒有 Demo 人員 | `Managed`（`config` 1.0、`personas` 1.0） | 由 `InitializePersonas` 建立所選 Persona Pack 需要的人員；建立前檢查可用 SKU 席次，不足即停止，不把唯一帳號當所有作者 |
| 已有其他可用的專用 Demo 帳號 | `Existing`（`config` 1.1、`personas` 1.1） | 你在私有 config 以 `accountMappings` 逐一指定 persona → 既有 UPN；只可調整 jobTitle／department／companyName／officeLocation 與 manager，不碰姓名、UPN、照片、密碼、使用地區、授權、角色 |
| 已有 Microsoft 365 sample pack | `Existing` + `personas\m365-sample` | sample 人物只是**姓名／alias 提示，不是 provenance 證明**；實際名單／alias 可能不同，你仍須明確映射，工具不會單憑姓名認領帳號（指定的 UPN 不存在時，姓名／alias 只用於有界精確查找與提議，仍須你確認） |

`personas\company-24`（Managed 的 CC0 肖像 starter）保留，可離線通過驗證，**不是 live-ready**；`personas\m365-sample`（16 個公開示意姓名）與 `personas\existing-template`（3 個邏輯角色、不含真人姓名）是 Existing 的起點，皆沒有肖像、授權或帳號資料。人數不是固定值：Existing 的 N 是本次 `accountMappings` 的人數，Managed 的 N 是所選 pack 的人數。**一批 N 人全部檢查通過、全部讀回成功才算完成；任何一人 Block 或未完成，整批零寫入或停止，不標成功**。

入口是專案根目錄 `Invoke-M365Demo.ps1`。不帶 Mode 有導引式選單；CLI 的 Mode 是 `RunAll`、`InitializePersonas`、`InspectUsers`、`Preflight`、`Verify`、`Validate`、`Import`。**沒有 `Prepare` Mode**；builder 是另一個離線 Python 入口。兩種來源共用同一組 Mode，沒有新增模式或框架。

以下路徑從專案根目錄執行。live 命令只是操作說明，**本次未獲授權執行，也未驗證真實租用戶可用性**。

## 1. 第一個設定入口：config.json.example

先閱讀根目錄 `config.json.example`（現為 Existing 的公開占位範例），不要向 AI 索取／提供真實設定或密碼。範例 GUID、domain 只是無效占位，不能直接登入。

```powershell
if (Test-Path -LiteralPath .\config.json) { throw 'Existing private config: do not overwrite.' }
Copy-Item -LiteralPath .\config.json.example -Destination .\config.json -ErrorAction Stop
```

在本機私下編輯，**不提交到 Git、不貼給 AI**：

- `tenantId`：你獲授權的租用戶；`presenterUpn`：已存在、啟用的 Member 帳號，不是要設定的 Demo 人員之一。
- `clientId`：seeding application；`clientSecretEnvironmentVariable` 只填環境變數**名稱**，secret 本體只由本機安全機制放入當次 process，不寫 JSON、prompt 或命令歷史。不要啟用包含敏感內容的 transcript／debug。
- 新設定不需要 `adminAuth`。舊 optional `adminAuth.clientId` 必須等於頂層 `clientId`，不符即停止並要求明確遷移；`adminOperatorUpn` 只保留為不可修改的保護帳號，不代表 App 已登入為該使用者。
- `personas.accountSource`：Existing 固定寫 `"Existing"`（`schemaVersion` 為 `"1.1"`）。
- `personas.packPath`：選用的 public personas JSON；Existing 可用 `personas\m365-sample\personas.json`、`personas\existing-template\personas.json` 或自己的 1.1 pack。
- `personas.accountMappings`：**你本機明確提供**的 `personaId → 既有 UPN` 精確清單，只此處的帳號會被檢查／設定；可只選 pack 的子集合，但每位所選人物的 `managerRef` 必須也被選取，工具不自動擴大名單。Presenter／登入操作員不能被選。範例的 `selected-person-N@example.invalid` 只是占位。某個 UPN 不存在時，初始化會先做有界精確查找並請你在本機一次選擇；完整讀回後，經核准的更正才由工具只改這一欄存回（不需要你手改 JSON）。
- `personas.instanceId`、`personas.bindingPath`：私人狀態位置，例如 `private\demo-company.binding.json`；parent 目錄與報告位置須滿足 runner 的私人 ACL 檢查，不放共用資料夾。Existing **不需要** `accountPrefix`、`userDomain`、`usageLocation`、`licenseProfiles` 或任何新席次。
- `runId`：課程執行識別；同一批人物維持 instanceId，新課程使用新 runId。已完成 run 只能精確比對後 Skip；修改內容不能沿用舊完成證據。

config 內 packPath／bindingPath 相對於 config 所在目錄；CLI 的 `-PackPath`／`-PersonaPackPath` 相對目前工作目錄。完整路徑可減少混淆。不把私人 config 複製進 public prepared／examples。

### Managed 設定（建立受管人員）

只有 Presenter、沒有可用 Demo 人員時才選 Managed。把 `schemaVersion` 設為 `"1.0"`，`personas` 改為下列形狀（占位值；仍須管理者提供實際已訂閱 SKU）：

```json
"personas": {
  "packPath": "personas\\company-24\\personas.json",
  "instanceId": "training01",
  "accountPrefix": "demo-",
  "userDomain": "example.invalid",
  "usageLocation": "TW",
  "bindingPath": "private\\training01.binding.json",
  "licenseProfiles": { "m365-demo": {"skuIds": ["33333333-3333-4333-8333-333333333333"]} }
}
```

- `accountPrefix`、`userDomain`、`usageLocation`：固定受管命名空間、已驗證 Managed domain、實際使用地；不使用真實名冊推測。
- `licenseProfiles.m365-demo` 對應 company-24；`skuIds` 必須由租用戶管理者選定實際已訂閱且足夠的 SKU GUID；不要複製占位GUID，不猜產品名等於SKU。company-24 的 Managed 仍要求完整 CC0 肖像與權利證據。

### 席次不是 tenant 人數（Managed）

新建24位、每位需要同一SKU且尚未持有時，該SKU需24個可用新增席次；既有 Presenter 不算第25個新增需求。多SKU逐一計算 `prepaidUnits.enabled - consumedUnits` 與新增需求，不用「已有25個user」推估席次。已有SKU、群組授權、錯誤／pending、額外授權或容量不明會停止，不回收他人license、不購買、不更改服務方案來湊數。Profile名稱也不保證每人有 mailbox、Teams 或 Copilot 功能。

**Existing 不查席次、不呼叫 assignLicense**：它沿用帳號現有授權（包含群組授權或停用方案），只把服務標為 `NotVerified`；缺服務時由後續 RunAll 的 workload preflight 阻擋，不能為了通過而配授權。

## 2. 本機 prerequisites 與依賴

Windows、PowerShell **7.5+**（使用 `-DateKind String`）、Python 3.11+、uv。既有鎖檔與 `requirements.psd1` 是依賴依據；不要為教材另裝AI／影像服務。

全新本機環境才需要：

```powershell
uv venv .venv
uv pip sync --python .\.venv\Scripts\python.exe requirements.lock --require-hashes --index-url https://packagefeedproxy.microsoft.io/pypi/simple/
```

這是地端套件來源；不要改全域設定或靜默換官方來源。已有可用環境不必重裝。執行 Python 測試才另需 dev.lock。所有連線模式皆不需要 Graph SDK，不使用 device login；啟動工具的同一 PowerShell process 安全提供 secret：

```powershell
$env:M365_DEMO_CLIENT_SECRET = Read-Host -MaskInput 'App client secret'
```

## 3. 起始認證：統一 Application，能力仍依 Mode 隔離

| 用途 | 起始認證 | 不代表 |
|---|---|---|
| Validate／Python validator／builder | 離線；不讀config、不登入 | 不代表live授權 |
| InspectUsers／InitializePersonas | 同一 App 的 client credentials，核對 tenant／client／audience／issuer／期限與必要 Application roles | App 不是個人操作員；登入不是人員寫入確認 |
| RunAll／Preflight／Import／Verify | seeding application 的app-only登入，核對token及選用工作負載權限，再讀回既有Presenter | **不是Presenter登入**，也不是用管理者token讀所有信箱 |

互動啟動會先顯示／確認既有 Presenter，再認證正確用途的身分，接著做身分／選用服務檢查及完整資料驗證。不要等到寄信一半才補登入。Presenter 的使用者UI檢查在最後仍需本人登入。

目前 engine 的保守權限矩陣（不是宣稱所有 endpoint 的絕對最小權限）：

- App 基礎：`User.Read.All`；Outlook：`Mail.Read, Mail.Send`；OneDrive：`Files.ReadWrite.All`。
- Teams：`Team.Create, Teamwork.Migrate.All, TeamMember.ReadWrite.All, Group.ReadWrite.All, Team.ReadBasic.All, Channel.ReadBasic.All, ChannelMessage.Read.All`。
- SharePoint：`Group.ReadWrite.All, Sites.ReadWrite.All`。application權限可相當廣，應由租用戶管理者審核；工具自身的allowlist不能改變服務端權限範圍。
- Inspect Application：`User.Read.All`。
- Initialize Application（Managed）：`User.ReadWrite.All, ProfilePhoto.ReadWrite.All, LicenseAssignment.ReadWrite.All, LicenseAssignment.Read.All, Domain.Read.All`。只加入已訂閱且足夠的授權，不購買或回收。
- Initialize Application（Existing）：`User.ReadWrite.All`；不要求照片、授權或網域 roles。

固定官方 Application 替代：`User.ReadWrite.All` 滿足讀人員、照片與指派授權條件；`LicenseAssignment.ReadWrite.All` 滿足 `LicenseAssignment.Read.All`，`Domain.ReadWrite.All` 滿足 `Domain.Read.All`。不以任意 `Directory.ReadWrite.All` 作 fallback。內容維持：`Mail.ReadWrite` 滿足 `Mail.Read`；`Group.ReadWrite.All` 滿足 `Team.ReadBasic.All`／`Channel.ReadBasic.All`；`Teamwork.Migrate.All` 只滿足 exact migration body 的 `Team.Create`。**`ChannelMessage.Read.All` 仍獨立必要**。不補寫 token roles、不重複新增已滿足的 grants。

實際執行只查當次 Mode／所選 workload 的必要 roles，額外 grants 靜默忽略，不擴充 Mode／capability。拒絕 Delegated `scp`、錯誤 tenant／Client／audience／issuer、過期 token 或缺項。初始化只取得人員能力；RunAll／Import 不能寫人員，InspectUsers／Preflight／Verify 唯讀。Validate 保持離線。

工具不建立app registration、不grant consent／role、不開通服務。缺權限／policy／服務讀回證據時停止，不自動升權。Global cloud v1.0為現有範圍，不提供任意host／beta fallback。

### 同一 App 的設定步驟（僅操作說明，不代表已變更或授權）

由有權管理者先核對既有設定／指派及其他使用方式，列出這次差異並取得明確確認；無法核對影響就停止，不先廣泛 consent：

1. 在既有同一 Client ID 核對上表全功能的 **Application** 權限與實際 admin consent，包含 Managed 的 `Domain.Read.All`／`LicenseAssignment.Read.All`；不要使用 Delegated scopes 代替。
2. 必須由有權管理者明確審核必要差異；工具不建立 App、不 consent、不移除 grants，不變更 MFA／Conditional Access／public client 設定或使用者角色。
3. 頂層 tenant／client 設定與 process 環境變數供應同一 App 的有效 secret；不放 config、argv、source 或測試 fixture。
4. 初始化先整批 GET-only 計畫，再由本人預覽與確認；Managed 額外讀 verified domain／訂閱席次，Existing 不查席次。
5. 確認等待後，工具在 capability／Pending／新 journal 前依需要續取並驗證同 App token，一次失敗即停止。尚未送出不標 Unknown、不消耗 capability；送出後結果不明仍 Unknown，絕不自動重送寫入。
6. 已完成 binding／journal 保留，不因認證遷移重新初始化或換帳號。Application 權限可能涵蓋全 tenant，工具 allowlist 不是 Entra 服務端限縮；單一 App 較簡單但 secret 外洩影響較大。

同一 App 不會要求逐一登入各 workload；Presenter 網站檢查仍需本人瀏覽器登入，不保證免除 MFA。缺必要 Application roles 只列缺項；其他認證錯誤安全停止，不輸出 token／secret／原始 provider exception。新預覽與 approval 記錄 `Actor.Type=Application`，本機輸入確認者不是經 Graph 驗證的個人操作員。舊 approvedBy／journal context 不改寫。

官方依據：[client credentials](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)、[人員](https://learn.microsoft.com/en-us/graph/api/user-update?view=graph-rest-1.0)、[照片](https://learn.microsoft.com/en-us/graph/api/profilephoto-update?view=graph-rest-1.0)、[授權](https://learn.microsoft.com/en-us/graph/api/user-assignlicense?view=graph-rest-1.0)、[席次](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0)、[網域](https://learn.microsoft.com/en-us/graph/api/domain-list?view=graph-rest-1.0)、[郵件](https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0)、[Teams](https://learn.microsoft.com/en-us/graph/api/team-post?view=graph-rest-1.0)。

## 4. 首次或明確修正人物：獨立 InitializePersonas

**先完成素材／權利（Managed）或帳號選擇（Existing）、offline驗證，並另外取得live授權後，才執行下列命令。** 離線通過不授權任何租用戶變更。

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode InspectUsers -ConfigPath .\config.json
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode InitializePersonas -ConfigPath .\config.json
```

InspectUsers 是唯讀inventory；輸出包含私人身分資料，不貼AI。`InitializePersonas` 依 config 的來源分流：

### Managed

顯示全批profile／manager／photo／license before-after及逐SKU席次，再要求**精確 tenantId/instanceId 與計畫 fingerprint 兩項確認**。照片／席次／namespace不明時在第一個寫入前停止。

它會建立／修正受管人員、主管、照片及明選新增授權；不改Presenter、不採用未證明的同名帳號、不重設既有人密碼、不刪人、不回收license。新初始密碼僅runtime處理且下次登入需變更，不回傳／寫檔，也不交給AI。完成binding是 `Provisioned/NotVerified`。若 Update 會修改先前受管人員，仍先列「檢查後提醒、確認前零寫入」的 Before → After。

### Existing

1. **帳號對應（唯讀）**：先對 `accountMappings` 的每個 UPN 精確讀取。存在就沿用，不因姓名不同而換人；只有確認 **404** 且尚未綁定時，才用 public `identityHint` 的完整姓名／alias 做有界 GET 精確查找（OData 字串逸出、每頁最多 20 筆；403、逾時或讀取失敗不是「不存在」，直接停止，不配對）。精確查找結果會合併所有頁與兩種提示：**只有一位完整、合格（啟用的雲端 Member、非 Presenter／操作員、本批不重複）的精確匹配**時，才是「提議」，並列在整批預覽內；多筆（含第二頁才出現的同名）、只有相似姓名、找不到、或唯一匹配不合格時，**不自動挑人**，改由本機**一次**列出受限（最多 20 筆）的候選，你輸入號碼，或用 `replace:<精確 UPN>` 指定另一位（標 `UserSelectedReplacement`；替代者保留自己的真實姓名與照片，不冒充原人物）。查無匹配不證明帳號已被刪除；沒有 hint 的通用 pack 也用同一個 `replace:<精確 UPN>` 輸入。選人只決定身分，**不是寫入同意**；不選或取消即零寫入停止。已有完成 binding 的初始化不再依名稱重配。
2. **整批唯讀檢查**：對解析後的**全部 N 位**以固定 object ID 讀回，必須是啟用的雲端 Member（Guest、同步帳號、停用、Presenter／操作員一律 Block）。**不檢查也不修改目標帳號的目錄角色或 PIM**：持有角色不是拒絕條件，若 Graph 伺服器端仍拒絕（403／租用戶 policy）會如實停止。同時驗證主管關係（含外部既有鏈的循環；主管不存在、未被選入或形成循環才 Block）與將存入 binding 的 snapshot；有任一人 Block，其他人也不寫入。
3. **提醒與完整 diff**：檢查完成後、確認前，共用的 renderer 先顯示修改警告與 `原指定帳號 → 實際帳號`（方法為 `ExactUpn`／`UniqueExactHint`／`UserSelectedCandidate`／`UserSelectedReplacement`），再逐人列 `Before → After`（包括只改 manager）；沒有任何變更時顯示「將沿用既有人員，不修改 profile」，不顯示修改警告。有 Block 時只顯示阻擋原因，不提供確認。實際 UPN／Before／After 與候選只在本機顯示，不貼 AI；自動化輸出只含邏輯人物、變更欄位名稱、解析方法與計數、人數與安全錯誤碼。
4. **確認**：除 tenantId/instanceId 與計畫 fingerprint 外，另須明確輸入 `DemoAccountAcknowledged`（直接參數為 `-DemoAccountAcknowledged`），表示你已核對本批實際帳號與逐人 `Before → After`，並同意以此 fingerprint 更新這些帳號的 profile；工具不檢查也不修改它們的目錄角色。`-NonInteractive` 不是同意。
5. **寫入**：核准後再次 fresh 讀取並比對身分與快照（只用已核准的固定 object ID，不再做姓名查找或選人），才開始；只允許對已核准帳號的 `PATCH /users/{id}`（四個欄位）與指向同批已核准人員的 `PUT /users/{id}/manager/$ref`，每筆都有 durable pending 與讀回。不呼叫 create、photo、assignLicense、password，不改姓名／UPN／使用地區／授權／角色。
6. **完成**：全部 N 人最後整批讀回一致後才寫 binding（`version 1.1`、`status ConfiguredExisting`、`serviceStatus NotVerified`），並以 `BindExisting` journal 事件記錄首次選取（含各人「原指定 → 實際帳號」與方法），不把既有 ID 當成工具建立的 ID。接著把經核准的帳號更正存回私有 config 的 `accountMappings`：重新讀取原始檔、以讀取時的 SHA-256 保護，只 patch 這一欄，不把 runtime 預設值（絕對路徑、`adminAuth`）存回；檔案被外部改過就不覆寫，標 `LocalConfigSyncRequired`（結束碼 3；遠端更新已完成、不重送，RunAll 也會因設定與 binding 不符而拒絕）。下一次 `InitializePersonas` 會在登入前的本機準備階段，只在完整 binding／journal 證據證明、且差異恰好是已核准的「原指定 → 實際」時補存，不重新選人。任何一人失敗或 Unknown 就保留 journal、不產生 binding、不重試或回滾；要調整必須再進初始化看新的 diff。換選取名單須明確使用新的 `instanceId`／`bindingPath`，不會自動繞過。

完成binding只代表人員設定讀回，不是 mailbox／drive／Teams／UI／Copilot readiness。人物初始化不是每堂課必跑；同pack／instance精確相符重跑應零寫入。部分／Unknown不自動續跑。Scenario 需要的不同作者超過已選取人數時，RunAll 會在任何內容寫入前以 `Seed.Binding.Missing` 阻擋並列出缺幾人；不會用 Presenter 假扮作者。

## 5. 每堂課：RunAll，並不是重新初始化人物

先準備使用已核准人物的新課程scenario，選好新的runId。正式rich與company-24已可離線驗證；live仍需完整可信binding、服務可讀回與明確授權。**以下命令沒有在本次live執行，不能解讀為租用戶服務已驗成功**：

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Preflight -ConfigPath .\config.json -PackPath .\examples\rich-training\scenario.json -PersonaPackPath .\personas\company-24\personas.json
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode RunAll -ConfigPath .\config.json -PackPath .\examples\rich-training\scenario.json -PersonaPackPath .\personas\company-24\personas.json
```

Preflight的**遠端請求是唯讀**，仍有認證、完整驗證及本機prepared／報告寫入；不是離線dry-run。RunAll認證後檢查binding與選用服務、驗證來源、建立／精確比對prepared、列全域Create／Skip／Block與副作用，確認後依序上傳檔案、寄信、匯入新Team（名稱是 `scenario.title` 加 8 碼 run 後綴）並完成migration，最後讀回Verify。

範例的 scenario 與 persona pack **必須成對**（scenario 的 `personaPackId` 等於 pack 的 `packId`），RunAll 只消費已完成、可驗證的 binding：

| scenario | persona pack | 來源 |
|---|---|---|
| `examples\rich-training`、`examples\minimal` | `personas\company-24` | Managed |
| `examples\sample-rich`、`examples\sample-minimal` | `personas\m365-sample` | Existing（sample 人物，需自行映射帳號） |
| `examples\existing-minimal` | `personas\existing-template` | Existing（任何其他專用帳號，只用邏輯角色） |

`sample-rich` 保留 `rich-training` 的故事規模、數據與作者數，只把人物換成 sample 人物；不會替換原 Managed 範例。其他帳號的 AI brief 只描述邏輯角色與職責，不放真實名冊。

RunAll不呼叫InitializePersonas。**真實寄信不可當作可撤回的測試**；郵件作者是真實受管persona，Presenter每封收件。Teams是新建private Team的歷史匯入，不接管任意現存Team。看到任何Block，整批不核准，不讓其他工作負載先寫。

Team顯示名稱就是 scenario 的 `title` 加 ` [8碼 run 後綴]`，沒有固定的「Demo Team」前綴，所以 `title` 要寫成你希望 Presenter 看到的自然名稱：1–200 字、前後無空白、不含控制／格式／行分隔字元；不合規會在任何寫入前以 `Seed.Input.TeamName` 停止，工具不會改寫或截斷。SharePoint 另建的文件庫固定叫 `Project Documents`，同一 site 的 List 不可使用相同名稱（忽略大小寫與前後空白），否則在寫入前以 `Seed.Storage.Collision` 停止。

互動執行確認精確 `tenantId/runId`；`-NonInteractive` 只是無stdin／結束不等待，**不是同意**。InitializePersonas 仍拒絕 production NonInteractive，因必須由本人預覽／確認；InspectUsers 可唯讀 NonInteractive。內容寫入仍需當次 `-ConfirmTarget`，不要讓 AI 代填確認值。

已完成run的唯讀檢查：

```powershell
pwsh -NoProfile -File .\Invoke-M365Demo.ps1 -Mode Verify -ConfigPath .\config.json -PackPath .\examples\rich-training\scenario.json -PersonaPackPath .\personas\company-24\personas.json
```

需原本完整prepared與journal，重新讀回精確內容／作者／收件／關聯／會員／資產。Unknown／Partial／pending或來源漂移不resume、不force、不重寄、不刪遠端資源作補救；保留報告供有權人員判讀。

升級舊版後：`generator\build_scenario.py` 的 bytes 納入 `builderFingerprint`，本次更新（移除 workbook 固定 description、Team／文件庫可見名稱改版）會使舊 builder 建立的 `runs\<runId>\prepared` 與其 journal 不再相符，Preflight／RunAll／Verify 會在任何內容寫入前停止（`Seed.Input.Prepared`）。工具不覆寫、不修復、不刪除舊目錄，也不會自動更換 `runId`；要用新版匯入，請自行指定新的 `runId`；要驗證舊 run，只能用建立它的舊版程式碼與原 prepared／journal。

## 6. 完成畫面：直接開 site／Lists，不從信中找入口

畫面與私人 `summary.json`／`summary.md` 提供Created／Skipped／Failed／Blocked／Unknown、報告／journal位置及 `ResourceLinkIndex`。實際行格式由runner輸出：

```text
kind | displayName | webUrl | Presenter=presenterAccessStatus
```

對本rich情境，應有 site、預設及明列文件庫、`澄流行動與閘門`／`澄流決策基準`兩份List，以及Team／三個channel的直接連結。**此處不填假租用戶URL或偽裝成功畫面**；只有真正read-back的 `webUrl` 才能顯示。JSON中List logicalId為 `chengliu-site/chengliu-actions`、`chengliu-site/chengliu-decisions`，可據此定位實際連結。

SharePoint `StructuralVerified` 只證明tool-created private Group／會員／預設繼承來源與application內容讀回；`RemoteAclNotProven`，不是effective ACL或Presenter UI已通過。實際Presenter須逐一打開site、文件庫、文件與兩份Lists／items。Teams也需本人看見內容及作者。最後另外驗證搜尋／Copilot索引與回覆，不能以API成功或binding代替。

互動完成會保留結果等Enter，避免畫面立刻關閉。Exit：`0` 該模式完成（Validate不代表live完成）、`1` 執行失敗、`2` 輸入／驗證／preflight阻擋、`3` Partial／Unknown需人工處理。本次只做離線內容驗證，未宣稱上述live流程成功。
