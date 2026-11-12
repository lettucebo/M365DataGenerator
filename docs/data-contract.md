# T1 canonical shape 快查

權威：`schemas\personas.schema.json`、`schemas\scenario.schema.json` 與 `generator\validate_pack.py`。Managed 的 personas／config／binding 與 scenario 版本為 `"1.0"`；Existing 另用 `"1.1"` 的 personas／config／binding，scenario 仍是 `"1.0"`。所有物件禁止未宣告欄位。這份文件不新增第二套格式；完整實例見 `examples\minimal\scenario.json`／`examples\rich-training\scenario.json`（Managed）與 `examples\sample-rich\scenario.json`／`examples\existing-minimal\scenario.json`（Existing）。

## Public Persona Pack

```text
root: packId,version,company,businessUnits,people,avatarAssets
company: id,name,industry,locale
businessUnits[]: id,name
people[]: personaId,alias,displayName,jobTitle,department,companyName,
          officeLocation,managerRef,avatarAssetId,licenseProfile
avatarAssets[]: id,path,mediaType:"image/jpeg",sha256,
                rights:{license,source,attribution,evidencePath}
```

`managerRef` 為既有 personaId 或 `null`，不能自指／循環；每人恰好一張不重複肖像。`path`／`evidencePath` 相對於 personas JSON 目錄，不能是絕對路徑、`..`、UNC、symlink／reparse point。public 不含 UPN、objectId 或密碼。SHA-256 必須為實際檔案 64 字元小寫 hex；company-24已使用`avatars`內24張正式JPEG的真實hash與逐張CC0證據，沒有占位值或例外。

## Public Persona Pack 1.1（Existing；沒有肖像、授權或帳號資料）

```text
root: packId,version:"1.1",accountSource:"Existing",company,businessUnits,people
people[]: personaId（唯一必填）,identityHint?:{displayName?,alias?},
          profile?:{jobTitle?,department?,companyName?,officeLocation?},managerRef?
```

沒有 `avatarAssets`、`avatarAssetId`、`licenseProfile`，也沒有 UPN／密碼／使用地區：Existing 不碰照片、授權與帳號識別。`identityHint` 是給人閱讀的姓名／alias 提示（不得含 `@` 或 GUID），**不是帳號 provenance，也不單獨決定帳號**；實際帳號由私有 config 的 `personas.accountMappings` 指定。只有指定的 UPN 不存在（404）且尚未綁定時，初始化才以它做有界精確查找（完整姓名或 alias 相等；不做拼音／模糊）並**提議**更正，仍須使用者在整批預覽確認；多筆／相似／找不到由使用者在本機選擇。`profile` 省略的欄位表示不修改；存在的欄位是 1–128 字元、無控制字元的文字。`managerRef` 為 personaId，或省略／`null` 表示不修改 manager（Existing 不會移除既有主管）；被指名的人必須也在同批所選人員內，工具不自動擴大名單。

`personas\m365-sample` 的 16 個姓名／alias 取自 Microsoft Learn 的公開示意圖，**不承諾任何租用戶的名單相同**；`personas\existing-template` 只有三個邏輯角色。兩者都不含照片。`identityHint`／`profile` 的職稱與部門是本工具的 Demo 設計，不是 Microsoft 官方 profile。

## Scenario root

```text
required: schemaVersion,scenario,roles,stories,assets
scenario: id,title,locale,anchorDate,timeZone,learningObjectives,personaPackId
roles: {roleKey:{personaId,businessUnitId,responsibility},...}
stories[]: {id,title,facts:[{id,text},...]}
optional: workbooks,outlook,teams,onedrive,sharepoint
```

至少一個 outlook／teams／onedrive／sharepoint；`workbooks` 單獨不算工作負載。角色映射到不同、既有 persona；businessUnitId 必須存在。`Presenter` 不得是 roles 的 key，僅作執行時 target。ID 是 logical ID，不是任何 Graph 遠端 ID。

有 `teams` 時，`scenario.title` 直接成為匯入 Team 的顯示名稱前段：實際名稱是 `<title> [<run namespace 前 8 碼>]`，沒有固定的 Demo 前綴。schema 的 text 上限（65536 字）不是 Team 名稱規則；Teams adapter 另在任何寫入前要求 title 為 1–200 字、與 `Trim()` 後相同（前後無空白）、不含控制／格式／行分隔字元，否則以 `Seed.Input.TeamName` 停止，不改寫、不截斷。所以 title 要寫成 Presenter 實際想看到的自然名稱，不放 demo／sample／虛構這類標記。

### Outlook：唯一欄位是 `outlook.threads`

```json
{
  "id": "mail-example",
  "action": "send",
  "parentId": null,
  "fromRole": "MfgLead",
  "toRoles": ["QualityLead"],
  "ccRoles": ["Presenter"],
  "subject": "【虛構】品質確認",
  "bodyHtml": "<p>請確認試點範圍。</p>",
  "assetRefs": []
}
```

此物件放入 `outlook:{threads:[{id,storyId,messages:[...]}]}`。首封 `send`／null；後續 `reply` 的 parentId 指向**同串先前**訊息，作者必須在 parent 的 To／CC。每封收件角色不得重複，Presenter 必須在 To 或 CC；fromRole 不得是 Presenter。不同 thread 的 mail IDs 也不能重複。郵件沒有 `createdDateTime` 欄位，不要自加；敘事日期寫正文。

### Teams：roots 與 replies 不同形狀

```text
teams:{channels:[{
  id,displayName,memberRoles,
  messages:[{
    id,storyId,createdDateTime,fromRole,bodyHtml,mentions,assetRefs,
    replies:[{id,storyId,createdDateTime,fromRole,bodyHtml,mentions,assetRefs}]
  }]
}]}
mention:{id:0,role:"QualityLead",text:"QualityLead"}
bodyHtml:<p><at id="0">QualityLead</at> 請核對批次。</p>
```

mention id 從 0 連續，順序／文字精確對上 HTML；text 就是 roleKey，不是姓名或 UPN。執行時才換成 binding 的真實 ID／姓名。作者及 mentions 都必須是 channel members；reply.storyId 等於 parent，不能再巢狀 replies。每 channel roots 及每組 replies 時間嚴格遞增，reply 晚於 parent；含 offset、不晚於 anchorDate 當日結束。Teams adapter 另拒絕 wall-clock 未來及超過毫秒精度。

### HTML／素材 token

允許 `p,br,strong,em,b,i,u,table,thead,tbody,tr,th,td,a,ul,ol,li`；只有 Teams 可加 `at`。僅 `a.href`、`at.id` attributes 可用，不可 CSS、img、script、event、comments。連結是安全完整 HTTP(S)／mailto 或完整 `{{asset:id}}`。

```html
<p>請見 <a href="{{asset:quality-data}}">品質台帳</a>。</p>
```

該訊息 `assetRefs` 必須含 `"quality-data"`；資產須已宣告。不能預先猜上傳網址，不能放 signed／秘密連結。Graph 實際 body 若有不支援的改寫，engine 可停止，不保證任何 HTML 都可 live 通過。

## Assets 與 workbook recipe

```text
asset:{id,mediaType,destination:{workload,containerId,folder,name},...}
二選一：
  localPath + sha256（相對scenario JSON目錄的真實檔案）
  workbookId（mediaType固定XLSX，引用本scenario的recipe）
workbooks:[{id,sheets:[{name,table,columns,rows OR generate}]}]
columns:[{name,type},...]  type=string|number|integer|boolean|formula
formula column另必填formula:"=B{row}*2"，對應row cell用null
rows:[[精確對應各欄的值,...],...]
generate:{seed,dimensions,periods,min,max,overrides:[{dimension,period,value}]}
```

`generate` 固定 string/string/integer-or-number 三欄。不得同時 rows／generate；型別不能 coercion。一般字串即使以 `=` 開頭也不會自動成公式。所有選取 workbook 必須有 uploaded asset；不能聲稱 recipe 自身已是檔案或已上傳。

`destination.workload` 是 `onedrive` 或 `sharepoint`，containerId 指向對應 drive/site；資產必須也列在**唯一目的地容器**的 assetRefs。訊息可以跨容器引用資產，但不能重複宣告上傳到別的容器。folder 是安全非空相對路徑；name 是單一檔名。

支援 mediaType：XLSX、DOCX、PPTX 的標準 OOXML MIME，`application/pdf`、`text/plain`、`image/jpeg`。JSON 與 builder 不提供任意下載或腳本執行。需要 Word／PDF 等時，必須是真實可驗檔案及真實 hash；本例使用 Excel recipe 與原創文字，沒有額外安裝。

## OneDrive／SharePoint／Lists

```text
onedrive:{drives:[{id,ownerRole,assetRefs}]}
sharepoint:{sites:[{
  id,displayName,alias,ownerRoles,memberRoles,assetRefs,
  lists:[{id,displayName,columns:[...],items:[...]}]
}]}
list column:{id,name,type}  type=text|number|integer|boolean|dateTime|choice
choice另必填choices:[字串,...]；其他type禁止choices
item:{id,values:{columnId:scalar,...}}
```

OneDrive ownerRole 不得重複；本例明用 Presenter drive。每 site.ownerRoles 必含 Presenter。item.values 的 keys 必須**恰好**涵蓋所有宣告 column IDs，型別／choice 精確；dateTime 要含 offset。此處 `ownerRole` 是 Lists 的普通文字欄位時不會自動形成 Graph person 欄。

引擎會替每個 site 另外建立一個名為 `Project Documents` 的文件庫，因此同一 site 的 `lists[].displayName` 不可等於它（忽略大小寫與前後空白）。validator 不檢查這點；Storage adapter 在任何遠端寫入前以 `Seed.Storage.Collision` 停止。

## 私有 config／binding／journal 的兩種版本

這些檔案只在本機，不交給 AI；下列只是形狀速查，權威是 `schemas\config.schema.json`、`schemas\persona-binding.schema.json`。

```text
config 1.0 (Managed): schemaVersion,tenantId,presenterUpn,clientId,clientSecretEnvironmentVariable,runId?,adminAuth?,
  personas:{packPath,instanceId,accountPrefix,userDomain,usageLocation,bindingPath,licenseProfiles}
config 1.1 (Existing): 同上共同欄位，
  personas:{accountSource:"Existing",packPath,instanceId,bindingPath,accountMappings:{personaId:UPN,...}}
  （沒有 accountPrefix／userDomain／usageLocation／licenseProfiles）

binding 1.0: version:"1.0",status:"Provisioned",users[personaId]:{objectId,upn,profile,photo,license,...}
binding 1.1: version:"1.1",accountSource:"Existing",status:"ConfiguredExisting",serviceStatus:"NotVerified",
  approval:{planFingerprint,demoAccountAcknowledged:true,journalFingerprint,acknowledgedAt},
  users[personaId]:{objectId,upn,source:"BindExisting",profile,status,serviceStatus}
  （沒有 photo／license；profile 的四個文字欄位與 usageLocation 可為 null，如實記錄當時值）

journal 1.0: createdIds（工具建立的人員）
journal 1.1: accountSource:"Existing",boundIds,events[kind:"BindExisting"]（只記錄採用的既有 ID，沒有 createdIds）
```

`accountMappings` 的 key 必須存在於 pack，值是你明確指定的既有 UPN；同一 UPN 不得映射兩人，Presenter／登入操作員不得入選。指定的 UPN 不存在時，帳號解析（精確 UPN → 404 才查提示 → 唯一匹配提議／本機選擇）的結果，連同「原指定 → 實際帳號」與方法（`ExactUpn`／`UniqueExactHint`／`UserSelectedCandidate`／`UserSelectedReplacement`），記在經核准的 preview（進入 fingerprint 與 journal）；完整讀回後，工具只把 `accountMappings` 該筆改成實際 UPN 存回本機 config（`LocalConfigSyncRequired` 表示尚未存回，RunAll 會因設定與 binding 不符而拒絕）。Existing 的 binding 只能由已完成、經讀回驗證的 journal 證據支持：fake `Provisioned` binding、缺少／被改過的 journal、更換 ID 或 UPN，都在 Graph 請求之前被拒絕。新的選取名單必須使用新的 `instanceId`／`bindingPath`，不能把舊 binding 擴大、縮小或改綁。

## 不混淆完成狀態

Public JSON、private binding、prepared manifest、run-state 是不同契約。Binding 的 `Provisioned/NotVerified`（Managed）或 `ConfiguredExisting/NotVerified`（Existing）都不代表 mailbox／Teams／UI 可用；`ConfiguredExisting` 也不是工具建立人員的證據，不能當作 createdIds 或 `Provisioned`。prepared `COMPLETE.json` 只代表離線產物完整；HTTP accepted 不代表遠端 Verified。private config／binding／journal／run-state 不交給 AI，僅由本機受信任 runner／engine 處理。

舊 prepared 的相容性：`prepared-manifest.json` 的 `builderFingerprint` 對應 `generator\build_scenario.py`／`validate_pack.py` 的實際 bytes。builder 或可見命名改版（移除 workbook 固定 description、Team 名稱改為 `<title> [8碼]`、文件庫改為 `Project Documents`）後，舊 builder 建立的 prepared 目錄、`COMPLETE.json` 與依其 fingerprint 綁定的 run-state／proof 都不再相符，不能 Skip、Verify 或續跑。工具不遷移、不覆寫、不刪除這些舊檔，也不會自動更換 `runId`；要用新版匯入，須由使用者明確指定新的 `runId`。
