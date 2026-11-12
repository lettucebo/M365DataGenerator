# Scenario generation prompt（供任何 AI）

只附公開的 `schemas\scenario.schema.json`、`schemas\personas.schema.json`、`docs\data-contract.md`、guidelines、public personas 與範例。不要附私有設定、密碼、tenant 名冊或真實內容。

---

請依下列 brief 產生原創繁體中文（台灣）教學情境。所有公司、人物、客戶、交易及觀測皆為虛構；不得抄寫真實郵件、Teams 或未經核實的產業／法規敘述。

使用者先填：

- 公司／產業及課程問題：
- 期間、anchorDate、IANA timeZone：
- 使用的既有 Persona Pack 與可用 BU（Managed 如 company-24；Existing 如 `personas\m365-sample`、`personas\existing-template`，並告知你實際會選取幾位人員）：
- 可用 personaId／職責（Existing 只給邏輯角色與職責，不給姓名、UPN 或名冊）：
- 工作負載、檔案、教學問題：
- 使用者核准的數據口徑及明確未知事項：

流程：

1. 先產 3 條互相關聯故事的事實表：storyId、數值、單位、分母、日期、觀測／估案、owner、deadline、狀態與依賴。先驗算，未提供的資訊不補成已知。
2. 角色僅映射既有 persona，各 roleKey 對不同 persona；`scenario.personaPackId` 等於所選 pack 的 `packId`。Existing 時，不同作者角色數不得多於使用者實際選取的人數。Presenter 不放 roles、不當歷史作者、不推定真實身分。
3. 每故事 4–6 封實質郵件，至少 3 位不同業務作者。先提案、再分析／異議、修正、決策；每封增加新資訊。每封 Presenter 在 To 或 CC，後續作者必須收到 declared parent 郵件。
4. 每故事 3–4 個跨日期 Teams 里程碑，各至少 2 則增加分析、限制、責任或交付物的回覆。每故事至少一張可核對比較表；使用實際 canonical mentions，不能把「收到」或重複換句話當推進。
5. 郵件、Teams、workbooks、文字文件與 Lists 共用同一事實基準。明示草稿／定稿差異、條件核准與未解問題；不讓所有人立即同意。
6. 提供每個教學問題的預期資訊與資產／訊息 ID，不能保證 Copilot 回覆特定措辭。

輸出只用 T1 canonical shape：

```text
schemaVersion,scenario,roles,stories,assets,
workbooks?,outlook:{threads:[{id,storyId,messages}]},
teams:{channels:[{id,displayName,memberRoles,messages}]},
onedrive?,sharepoint?
```

請逐欄遵循所附 schema／data-contract；不要發明 `emails`、`emailThreads`、profile updates、sentAt、Graph IDs、下載URL、任意 scripts 或不支援的 Office recipe 欄位。

Assets 用宣告的 workbook recipe 或使用者實際提供且有真實本機hash的安全檔案；無法建立檔案時明列缺失，不能猜hash。只用 `{{asset:id}}` 與精確 assetRefs；上傳後才由 engine 解析真實URL。正文 HTML 不加 CSS、img、script 或不受允許的 attributes。

最後輸出自審：每故事角色／封數／里程碑／日期／回覆品質，數據與分母核對、決策／待辦／來源索引、尚未證實事項。肖像缺失仍是 Persona Pack 阻擋，不為通過而替換測試圖或略過驗證。
