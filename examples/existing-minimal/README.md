# existing-minimal：任何既有帳號的最小 canonical 範例

兩個邏輯角色（`Lead` → `demo-lead`、`Analyst` → `demo-analyst`）、一封首信與一次真正 parent reply，沒有檔案、Teams 或 SharePoint 副作用。引用 `personas\existing-template`（Existing 1.1），不含任何真人姓名。

使用前須在私有 config 的 `personas.accountMappings` 映射 `demo-lead` 與 `demo-analyst` 到你選定、專用於 Demo 的既有帳號；若選了 `demo-analyst`，其 manager `demo-lead` 也必須被選取（本範例正好兩位）。

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\existing-minimal\scenario.json --personas .\personas\existing-template\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。這是離線驗證，不代表任何真實人員被檢查或 live-ready。
