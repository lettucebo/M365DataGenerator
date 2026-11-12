# 用自己的 AI 寫課程資料

本流程不綁 AI 供應商，不新增 API、下載、影像生成或金鑰要求。可以把公開檔案直接貼給選用的 AI；若平台無法讀檔，逐份貼 schema 與公開範例。不要貼私有 `config.json`、binding、run-state、名冊、tenant／object IDs、token、secret、密碼或真實郵件。

## 1. 公開 brief

先寫：產業與虛構公司、課程問題、繁體中文（台灣）、資料期間／時區、可用 BU／既有 persona、工作負載與輸出範圍。例如 rich-training：

> 2026-10-19 至 10/26，製造品質 → 資訊／電信整合 → 金融營運預算，三道閘門。讓學員核對「合格不等於部署」、「收到不等於唯一可用」、「條件核准不等於付款」。只使用 company-24 已有角色，不修改人員 profile；資料與對話全為原創虛構。

使用 Existing 帳號時，brief 改為「只使用所選 pack 的角色」：Microsoft 365 sample pack 用 `personas\m365-sample`（`examples\sample-rich` 保留 rich-training 的故事規模、數據與作者數，只把人物換成 sample 人物），其他專用帳號用 `personas\existing-template` 或自訂 1.1 pack，brief 只描述邏輯角色與職責，**不放真實名冊、UPN 或姓名**。scenario 的 `personaPackId` 必須等於所選 pack 的 `packId`；不同作者角色數不得多於你實際選取的人數（不足時 RunAll 在任何內容寫入前以 `Seed.Binding.Missing` 阻擋，不會用 Presenter 假扮作者）。

## 2. 先事實、再對話

列每個 `storyId` 的 facts：數字、單位、期間、分母、觀測／估案差別、owner、deadline、狀態、依賴及未解問題。先核算，再寫郵件與 Teams，最後寫 workbook／文件／Lists；不能讓各工作負載各編一套答案。

rich 的三個關鍵口徑：

- 112/120 → 118/120 是 +5 個百分點，與試點 40 台不同。
- 各輪 240 筆輸入；最後 237 唯一可用 +3 隔離。200 次探測 190 →198 是 95%→99%，不是 SLA，也不是單一因果證明。
- 新臺幣 480000 擬約定＝336000 證據齊備＋144000 待驗收；600000 上限－480000＝120000 未動支保留。沒有實際付款。

## 3. 寫出不同職責的推進

Golden 品質不是湊字數。每故事 4–6 封郵件、至少 3 位不同業務作者；從提案、分析／異議、修正到決策，Presenter 每封在 To／CC。後續作者必須收到所回覆 parent 的郵件，不能用虛構收件關係湊人數。

每故事 Teams 3–4 個跨日期里程碑主文，各至少 2 則**增加資訊**的回覆；含角色 mention、實際比較表、權衡、後續行動。日期以帶 offset 的時間表示，roots／replies 嚴格遞增；historical author 永遠不是 Presenter。

好回覆：

> 237 才是唯一可用事件，3 筆仍有原鍵且隔離待查；我在 10/27 12:00 前交追蹤。不把隔離刪掉後聲稱 240 全數有效；技術條件通過也不能解除整合驗收。

壞回覆：

> 收到，謝謝，會持續追蹤。

不同立場要有代價：縮小試點降低風險但犧牲排程便利；去重保留證據但不能把隔離當產出；保留預算有彈性但不代表可先動支。不是每個人立刻同意，也不讓所有角色說同樣一段話。

## 4. 只產生 canonical JSON

以 [data-contract.md](data-contract.md) 及 `schemas\*.schema.json` 為準；參考實際 `examples\minimal\scenario.json` 與 rich（Managed），或 `examples\sample-minimal`、`examples\sample-rich`、`examples\existing-minimal`（Existing），使用 `prompts\scenario-generation.md`。

- 不產 YAML、`emails`、`emailThreads`、`senderUpn`、Graph IDs 或 runnable scripts。
- `Presenter` 是執行時的保留 target，不放進 `roles`，不當作者。
- 所有資產先宣告；`{{asset:id}}` 必須在該訊息 `assetRefs`，不能猜 URL。
- workbook 用 typed `rows` 或 `generate` recipe，不能偷加不支援的格式欄位。計算模型用明確 formula column；若像本例是原始觀測台帳，標清觀測值與口徑，別把它包裝成會自動計算的財務模型。
- 更新本機文字／Office 資產時，要同步真實雜湊；絕不猜檔案 hash。不要放外部連結、macro 或未核准的內容。

## 5. 自審、驗證、僅修受影響範圍

以 `prompts\quality-review.md` 核對事實／角色／決策與教學證據索引；執行 [testing.md](testing.md) 的離線命令。根據 `path/code/message/remediation` 修正，不為通過而移除 Presenter、假造素材或關閉驗證。

validator 不會全面證明中文敘事、加總或法律主張正確；人工／AI 必須對照 facts、表格、資產及 Lists。外部案例若無核實完整 URL，就使用明確原創虛構案例，不照抄私有郵件或課程內容。

rich、minimal、sample-rich、sample-minimal、existing-minimal 與正式 company-24／m365-sample／existing-template 目前皆可通過 offline validator；company-24 附24張正式CC0肖像與逐張證據，Existing pack 沒有肖像，無須下載、替換測試圖或修改schema。這只解除原先素材缺口，live執行仍另需授權、確認、服務／Presenter UI與Copilot驗收。
