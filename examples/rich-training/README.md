# 澄流：跨 BU 的三道閘門

**原創虛構、可離線驗證的完整範例。** `company-24`已附24張不同CC0寫實虛構肖像與逐張證據，正式validator通過；所有故事、recipes、文字文件及Lists維持原有內容。沒有測試圖或免驗模式，離線成功不代表live授權或服務／UI就緒。

## 課程 brief

- 公司：晨澄實業集團（虛構）；製造／資訊／金融營運／電信 4 BU 與共享服務。
- 語言：繁體中文（台灣）；時區 `Asia/Taipei`。
- 資料期間：2026-10-19 至 2026-10-26；anchorDate `2026-10-26`。10/27–28 是**待辦期限**，不是已完成的未來訊息。
- 學習目標：從不同職責的異議與證據追蹤決策、分辨分母／百分點、辨識依賴與條件核准，不把漂亮摘要誤當完成證明。
- 公開人物固定引用 `company-24`，使用 12 位 persona；不含 Presenter 身分。金融 BU 的工作為內部資金營運，無對外金融商品或法規宣稱。

## 三條相關故事

| storyId | 演進 | 核心差異／保留項 |
|---|---|---|
| quality-gate | 品質初驗 → 分母異議 → 同組複測 → 只放行 A 批 | 120 台中 118 台合格，但只讓 A 批 40 台試點；78 台合格待排程、2 台隔離 |
| integration-gate | 固定 40 台 → 切換鍵值爭議 → 兩輪比較 → 採邊緣去重 | 每輪 240 筆輸入；最後 237 唯一可用、3 筆隔離；技術條件通過不等於付款驗收 |
| funding-gate | 淘汰超額全面案 → 分包報價 → 驗收口徑 → 條件核准 | 48 萬元擬約定、33.6 萬元證據齊備、14.4 萬元待驗收、12 萬元保留；無實際付款 |

每條 5 封郵件，4 位以上實際業務作者；Presenter 每封都在 To 或 CC。每條另有 3 則跨日期 Teams 里程碑主文，各 2 則增加資訊的回覆，含可核對表格及真正 role mentions。Teams 作者是 persona，不能把 Presenter 當歷史作者。

## 資產與位置

| assetId | 來源 | 目的地 |
|---|---|---|
| quality-data | `quality-book` recipe：批次觀測、口徑與來源 | Presenter OneDrive，`Chengliu\Quality-Observations.xlsx` |
| integration-data | `integration-book` recipe：受控測試、判讀與待辦 | 新 SharePoint site，`Chengliu\Integration-Observations.xlsx` |
| budget-data | `budget-book` recipe：分包驗收、預算條件 | 同 site，`Chengliu\Budget-Acceptance.xlsx` |
| quality-decision | `assets\quality-decision.txt` | 同 site |
| integration-runbook | `assets\integration-runbook.txt` | 同 site |
| funding-decision | `assets\funding-decision.txt` | 同 site |

Excel 是型別化的**原始觀測／驗收狀態台帳**，不是預測或付款計算模型，沒有公式或尚未重算的計算欄；來源、分母、單位及限制在第二張工作表。由既有 builder／openpyxl 生成，不新增 Office 依賴或外部連結。決策文字檔為實際本機資產，SHA-256 已宣告。

兩份 Lists：

- `chengliu-actions`／「澄流行動與閘門」：6 項未結案工作，owner、deadline、狀態及 `done:false`。
- `chengliu-decisions`／「澄流決策基準」：3 項不同狀態的決策，不用單一「完成」掩蓋保留項。

資產連結使用 `{{asset:id}}`，只有真正上傳及讀回 URL 後才解析。site／Lists 直接連結取自執行結果，不能預先拼 URL。SharePoint 的 `StructuralVerified` 仍須 Presenter UI 開啟確認，詳見 [操作指南](..\..\docs\getting-started.md)。

## 教學查證

請見 [問題與證據索引](..\..\docs\learning-guide.md)。此索引描述應可找到的資訊，不保證 Copilot 使用特定措辭，也不保證索引／搜尋傳播立即完成。

正式離線驗證（不需要config或登入）：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\rich-training\scenario.json --personas .\personas\company-24\personas.json
```

預期`{"valid": true, "errors": []}`、exit 0。肖像圖片的CC0授權與來源見`personas\company-24\ASSET-LICENSES.md`；[操作指南](..\..\docs\getting-started.md)仍要求另外核准live副作用，不把離線教材稱作live-ready。
