# 最小 canonical 範例

`scenario.json` 只有兩個固定角色、一封首信及一次真正 parent reply；沒有檔案、Teams 或 SharePoint 副作用。它示範 T1 的**實際資料形狀**，不套 rich 的長文／24 作者標準。

它引用正式`company-24`：24張CC0寫實虛構肖像與逐張來源／權利證據已附，可直接做離線驗證。這不是測試圖替代方案，也不代表有live初始化或寄信授權。

從專案根目錄執行：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\minimal\scenario.json --personas .\personas\company-24\personas.json
```

預期`{"valid": true, "errors": []}`、exit `0`。來源與圖片授權見`personas\company-24\ASSET-LICENSES.md`，與程式碼MIT分開。

只要測試fixture本身、不測正式starter時，可明確選用既有離線fixture：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\tests\fixtures\scenario.json --personas .\tests\fixtures\personas.json
```

預期 `{"valid": true, "errors": []}`、exit `0`。`tests\fixtures` 的小圖只是測試作品，**不是人物肖像、不是正式 starter、不可用來 InitializePersonas 或 live 寄信**。不會將這些圖片複製到發布範例。詳見 [測試邊界](..\..\docs\testing.md)。
