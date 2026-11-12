# m365-sample：Microsoft 365 sample 人物的 Existing 起點

公開 Persona Pack 1.1（`accountSource: "Existing"`）。**沒有肖像、授權、UPN、objectId 或任何租用戶資料**，只定義邏輯人物、可選的四個文字 profile 目標與 manager 關係。

## 來源與限制

- 16 個姓名／alias 取自 Microsoft 官方公開的 sample pack 示意圖（[說明](https://learn.microsoft.com/en-us/office/developer-program/install-sample-packs)、[圖 1](https://learn.microsoft.com/en-us/office/developer-program/images/content-packs-07.png)、[圖 2](https://learn.microsoft.com/en-us/office/developer-program/images/content-packs-08.png)），只放在 `identityHint`，是給人閱讀的**提示**，不是帳號 provenance。
- 官方文件只是示例版本，**不承諾你的租用戶名單、alias 或 UPN 相同**，也可能被修改或刪除。工具不會單憑姓名認領帳號；每位要使用的人，你仍須在私有 config 的 `personas.accountMappings` 明確指定 Demo 帳號。若指定的 UPN 不存在，初始化會用這些 `identityHint` 做有界精確查找：唯一完整匹配只是提議（須你確認），多筆／相似／找不到由你在本機一次選擇；找不到同一人時可選另一位當替代者（保留其自己的姓名與照片）。
- 不複製或再散布官方照片、截圖、郵件或 profile 表格。`profile` 的職稱、部門、公司與辦公室是**本工具的原創 Demo 設計**，不是 Microsoft 官方資料；公司名稱 `Contoso` 是 Microsoft 文件常用的虛構公司名，這裡只當作文字使用，人物、辦公室與其關係都是合成資料；16 不是人數限制。
- Existing 只調整 jobTitle／department／companyName／officeLocation 與 manager，不改姓名、UPN、照片、密碼、使用地區、授權或角色，也不需要席次。

## 結構

公司 `Contoso`（`company.name` 與 16 位 `profile.companyName` 完全一致），五個英文事業單位：`Smart Manufacturing`、`Information Services`、`Financial Operations`、`Telecommunications Services` 與 `Group Shared Services`；`jobTitle`／`department` 一律使用英文。`patti-fernandez`（Group Chief Executive Officer）是多位事業群主管與共享服務人員的 manager；`megan-bowen` 沒有 manager，因此 `megan-bowen`、`adele-vance`、`alex-wilber` 可自成一組（config 範例即選這三位）。

辦公室（`officeLocation`）分布在亞洲樞紐，共 8 個城市、7 個國家／地區；同一單位集中在少數城市，不需要每人一個城市：

| officeLocation | 定位 | 人物 |
|---|---|---|
| `Singapore` | 區域總部、金融營運 | `patti-fernandez`、`lee-gu`、`lidia-holloway`、`henrietta-mueller`、`joni-sherman` |
| `Taipei, Taiwan` | 智慧製造管理 | `megan-bowen` |
| `Taichung, Taiwan` | 智慧製造生產與品質 | `adele-vance`、`alex-wilber` |
| `Tokyo, Japan` | 資訊服務 | `diego-siciliani`、`grady-archie` |
| `Seoul, South Korea` | 資訊服務 | `johanna-lorenz`、`lynne-robbins` |
| `Hong Kong` | 管理會計 | `pradeep-gupta` |
| `Bangkok, Thailand` | 電信服務 | `miriam-graham`、`nestor-wilke` |
| `Kuala Lumpur, Malaysia` | 集團採購 | `isaiah-langer` |

**選取規則**：你只需映射這次要用的人，但每位被選人物的 `managerRef` 也必須被選取，工具不會自動擴大名單；Presenter 與登入操作員不能被選。

## 配對範例

| scenario | 需要的人數 | 說明 |
|---|---|---|
| `examples\sample-minimal` | 2（`megan-bowen`、`adele-vance`） | 一封首信與一次回覆 |
| `examples\sample-rich` | 13（12 位作者＋manager `patti-fernandez`） | 與 `rich-training` 同規模的三道閘門 |

scenario 的不同作者角色多於選取人數時，RunAll 會在任何內容寫入前以 `Seed.Binding.Missing` 阻擋。

## 離線驗證

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --personas .\personas\m365-sample\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\sample-rich\scenario.json --personas .\personas\m365-sample\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。這只代表公開資料格式與參照正確；沒有任何真實帳號被檢查或更新，也不代表 live-ready。
