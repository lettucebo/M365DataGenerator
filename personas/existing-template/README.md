# existing-template：任何既有 Demo 帳號的邏輯角色範本

公開 Persona Pack 1.1（`accountSource: "Existing"`）。只有三個**邏輯角色**：`demo-lead`、`demo-analyst`、`demo-coordinator`（後兩者向 `demo-lead` 報告）。沒有真人姓名、肖像、授權、UPN 或租用戶資料。

## 如何使用

1. 選出你租用戶中要拿來做 Demo 的既有帳號（不能是 Presenter 或舊設定明示的保護帳號；工具以 App-only 連線，不檢查也不修改目標目錄角色，請自行確認這些帳號適合被更新四個欄位與 manager）。
2. 在私有 `config.json` 的 `personas.accountMappings` 逐一映射，例如 `"demo-lead": "<你選定的 UPN>"`。這份映射只留在本機，不放進 public 檔案、不交給 AI。
3. 每位被選人物的 manager 也必須被選取；這次只想用其中幾位也可以（例如 `examples\existing-minimal` 只需 `demo-lead` 與 `demo-analyst`）。
4. `InitializePersonas` 會先解析帳號（此 pack 沒有姓名提示，所以指定的 UPN 不存在時，改由你在本機從候選選號碼，或輸入 `replace:<精確 UPN>`），再整批唯讀檢查，顯示完整 `原指定帳號 → 實際帳號` 與 `Before → After` 後由你確認；只調整 jobTitle／department／companyName／officeLocation 與 manager。

需要更多人或不同角色時，複製此 pack 另存為自己的 1.1 pack、修改 `packId` 並增加 `people`；**不要把真實名冊、姓名或 UPN 寫進公開檔案**。

## 配對範例與離線驗證

`examples\existing-minimal`（一封首信與一次回覆）：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --personas .\personas\existing-template\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\existing-minimal\scenario.json --personas .\personas\existing-template\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。這只代表公開資料格式與參照正確；沒有任何真實帳號被檢查或更新，也不代表 live-ready。
