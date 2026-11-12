# sample-rich：sample 人物版的「澄流」三道閘門

保留 [rich-training](..\rich-training\README.md) 的完整品質：同樣的三條相關故事（quality-gate、integration-gate、funding-gate）、每條 5 封郵件與 4 位以上業務作者、每條 3 則跨日 Teams 主文與各 2 則實質回覆、三份 workbook recipe、三份文字決策資產與兩份 Lists，數據與敘事結構相同。**差異只有人物與呈現措辭**：改引用 `personas\m365-sample`（Existing 1.1）的 sample 人物（公司為 Contoso），並同步改文字中的姓名（郵件與 Teams 內文以英文名稱呼同事）；匯入的郵件主旨／內文、Teams 頻道名稱與訊息、SharePoint site／Lists、文字文件及 workbook 儲存格不再帶「虛構」「示範」等標記，`北辰示範廠` 改稱 `北辰廠`。原創虛構的聲明只保留在本 README 與不匯入的 `stories.facts`。Team 顯示名稱取自 `scenario.title`（此 title 已不含 sample／示範字樣），實際為 `澄流計畫：從製造品質到連線證據與預算閘門 [8碼 run 後綴]`；SharePoint 另建的文件庫固定叫 `Project Documents`；workbook 檔案屬性只剩 builder 的 creator 與固定時間，不再寫入 description。`examples\rich-training` 與 company-24 仍原樣保留。

## 角色與人物

| 角色 | persona | 單位 |
|---|---|---|
| MfgLead／QualityLead／ProductionPlanner | `megan-bowen`／`adele-vance`／`alex-wilber` | Smart Manufacturing |
| InfoLead／DataEngineer | `diego-siciliani`／`grady-archie` | Information Services |
| FinanceLead／Controller | `lee-gu`／`lidia-holloway` | Financial Operations |
| TelecomLead／NetworkEngineer | `miriam-graham`／`nestor-wilke` | Telecommunications Services |
| ProgramLead／Procurement／SecurityLead | `henrietta-mueller`／`isaiah-langer`／`joni-sherman` | Group Shared Services |

12 位作者的 manager 鏈還包含 `patti-fernandez`，因此要完整執行需選取 **13 位**既有 Demo 帳號並在私有 config 的 `personas.accountMappings` 逐一映射。選取少於所需時，RunAll 在任何內容寫入前以 `Seed.Binding.Missing` 阻擋並列出缺幾人，不會用 Presenter 假扮作者。sample 姓名只是提示，不是帳號證明；Existing 只調整四個文字欄位與 manager。

## 資產

三份決策文字檔位於 `assets\`，其 SHA-256 已依實際內容宣告（沿用 rich-training 的 Windows CRLF 位元組慣例）；workbook 由既有 builder／openpyxl 依 recipe 生成。連結只用 `{{asset:id}}`，上傳後才由執行結果提供 site／Lists 直接連結。

## 既有 prepared 的相容性

本資料檔的 title 已更新，且 builder 不再寫入 workbook description（`builderFingerprint` 隨之改變），因此以舊內容或舊 builder 準備過的 `sample-rich` prepared 目錄與 journal 都不再相符：Preflight／RunAll／Verify 會在任何內容寫入前停止（`Seed.Input.Prepared`）。工具不覆寫、不刪除舊檔，也不自動更換 `runId`；要重新匯入，請自行指定新的 `runId`。

## 離線驗證

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\sample-rich\scenario.json --personas .\personas\m365-sample\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。這是離線驗證，不代表任何真實人員被檢查、不保證 Copilot 措辭，也不是 live-ready；詳見 [操作指南](..\..\docs\getting-started.md)。
