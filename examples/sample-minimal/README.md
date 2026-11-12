# sample-minimal：sample 人物的最小 canonical 範例

與 `examples\minimal` 同形狀：兩個固定角色、一封首信與一次真正 parent reply，沒有檔案、Teams 或 SharePoint 副作用。人物改引用 `personas\m365-sample`（Existing 1.1）的 `megan-bowen` 與 `adele-vance`；`adele-vance` 向 `megan-bowen` 報告，所以只需選取這兩位。

使用前須在私有 config 的 `personas.accountMappings` 把這兩位 persona 明確映射到你選定的既有 Demo 帳號；sample 姓名只是提示，不是帳號證明。

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\sample-minimal\scenario.json --personas .\personas\m365-sample\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。這是離線驗證，不代表任何真實人員被檢查或 live-ready。
