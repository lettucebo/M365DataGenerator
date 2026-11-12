# 澄流課程：問題與證據索引

所有事實皆原創虛構。以下是應可查到的資訊及logical ID，不承諾Copilot的特定措辭、搜尋召回或立即索引。正式starter已附24張CC0寫實虛構肖像與證據並可離線驗證；下表仍只是內容驗收，不是live可用證明。

`examples\sample-rich`（Existing 的 sample 人物版）的問題、數據與訊息／資產／List ID 與本表相同；只有表中的人物姓名依 `personas\m365-sample` 的 sample 人物替換，角色對應見[該範例說明](..\examples\sample-rich\README.md)。

| 教學問題 | 預期可找到的資訊 | 對應證據 |
|---|---|---|
| 為什麼 118 台合格，卻只部署 40 台？ | A批40台進受控試點；B/C合格78台待排程，2台隔離；後續技術與資金閘門未自動解除 | `quality-gate/pilot-scope`；`q-mail-3`～`q-mail-5`；`q-post-3`；`quality-data` 批次觀測；`quality-decision`；List `quality-decision-row` |
| 品質提升是 5% 嗎？還有誰未結案？ | 同組120台，112→118，93.33%→98.33%，+5個百分點；陳承翰10/27 17:00交2台原因分析 | `quality-gate/quality-counts`；`q-mail-4`；`q-post-3-reply-1`；`quality-data` 口徑與來源；List `quality-root-cause` |
| 收到 240 筆可否說有 240 筆有效產出？ | 不可；兩輪皆240輸入，最後237唯一可用、3隔離；原鍵保留，不手動補數 | `integration-gate/same-cohort`；`i-mail-1`、`i-mail-3`；`i-post-3`、`i-post-3-reply-1`；`integration-data`；`integration-runbook` |
| 為何沒有採外送雲端？改善能算 SLA 或單一因果嗎？ | 資料邊界未核准，沒有已驗證雲端比較數字；探測190/200→198/200，+4pp；受控窗口非SLA，連線與程式同改不能推定單一因果 | `integration-gate/network-counts`、`integration-decision`；`i-mail-2`～`i-mail-5`；`i-post-2-reply-2`；`integration-data` 判讀與待辦；`integration-runbook` |
| 預算、證據齊備、待驗收與保留如何對回？ | 上限60萬；約定48萬＝33.6萬證據齊備＋14.4萬待驗收；保留12萬未動支；沒有實際付款，不混加口徑 | `funding-gate/budget-cap`、`acceptance`；`f-mail-3`；`f-post-3`；`budget-data` 分包驗收觀測及預算條件；`funding-decision` |
| 誰可讓整合款跨過付款閘門？ | 雅雯10/27 16:00交撤銷證據，奕傑10/28 12:00補包，昱辰10/28 17:00覆核；未過維持待驗收、不先付款；不是任何人回「同意」就結束 | `funding-gate/funding-action`；`i-mail-4`；`f-mail-4`、`f-mail-5`；`f-post-3-reply-1`；`funding-decision`；List `access-revocation`、`acceptance-package`、`payment-gate` |
| 請整理三條故事的共同風險與 owner | 2台設備隔離、3筆事件隔離、切換鍵、撤銷演練、補包及付款覆核仍各有責任／期限；條件核准非全部完成 | `q-mail-5`、`i-mail-5`、`f-mail-5`；三個末次Teams主文；三份文字文件；`chengliu-actions`全部6項與`chengliu-decisions`全部3項 |

## 建議課堂節奏

1. 先讓學員只看郵件摘要，寫出「已知／未證明」兩欄。
2. 用 Teams 的異議與比較表找出摘要遺失的分母、範圍與條件。
3. 開 Excel 原始觀測／驗收快照及決策文字，重算加總；不要從一個「綠燈」反推全部通過。
4. 從實際執行結果的直接連結打開 site／Lists，逐項檢查 owner、deadline、done 與 dependencies。
5. 要求答案附訊息／資產來源；找不到的資訊標「未提供」，不能把未來演練結果補寫成成功。

## 人工內容審查紀錄

本次逐故事對照 facts、15封郵件、9主文／18回覆、3本 workbook recipe、3份文字文件與2份 Lists：初提案、反對理由、縮小範圍、最後決策及未結案工作一致。隔離副本另外核對台數、事件數、金額加總與 canonical validation。

這段敘事核對不是獨立reviewer、live Graph或Presenter UI驗收。肖像另已核實發布者CC0宣告與生成說明並完成作者視覺篩選，逐張來源／原圖及成品hash見`personas\company-24\ASSET-LICENSES.md`與權利manifest；獨立視覺review及live／UI驗收仍分開。
