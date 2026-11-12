# Review prompt：只審公開資料

輸入：公開 personas、scenario、schema、資料檔、brief、教學證據索引，以及去敏的 offline validator errors。不要傳 config、binding、run-state、帳密或真實內容。

---

請實際核對下列事項，引用 `檔案路徑:行號` 或 logical message／asset／fact ID。沒有證據不要聲稱已驗證；不要假稱獨立 reviewer 或猜模型／effort。

1. **契約**：只用 T1 canonical shape；role/persona/BU/parent/asset/container/list 引用精確，沒有私有欄位或真實識別碼。Presenter 每封收信、不能當作者；reply 作者確實收到 parent。
2. **組織**：人數與 BU／共享配置符合 brief，固定姓名／職責、完整 manager tree。肖像若未提供，明列缺失，不用模板、測試圖或猜測授權冒充。Existing（pack 1.1）不需要肖像／授權；核對其 `identityHint` 不含 UPN／GUID、不被當作帳號證明，人物只用邏輯角色，不暴露真實名冊，且 scenario 的不同作者角色數不超過預定選取人數。
3. **敘事**：每完整故事 4–6 封、至少3位業務作者；3–4個跨日期 Teams milestones，各2個實質回覆與正確 mentions，至少一張數據比較表。找出哪則訊息新增了異議、證據、取捨或決策；不能只算字數。
4. **數據**：重新核算表格、分母、百分比／百分點、單位、期間、觀測／估案；對照所有工作負載與原檔，不因 facts 寫了就信任。
5. **狀態**：草稿、條件核准、技術通過、待驗收、付款與部署不能混為一談。owner、deadline、依賴及未解問題一致，Lists 不提前結案。
6. **教學**：每個問題有可找到的訊息／資產ID，找不到就說未提供；不保證搜尋、索引或 Copilot 措辭。
7. **安全／權利邊界**：無私有設定、帳密、真實郵件或未確認外部宣稱；不建議關閉validator、補假圖、回收他人license、猜網址或權限。

輸出：

- 有證據的 Blocking：功能錯誤、資料／身分邊界破壞、需求遺失或不可逆風險；列精確位置、影響與最小修正。
- 非阻擋建議：可延後，不為文風重開已通過範圍。
- 實際驗證命令／輸出，或「未執行」；不要把閱讀當作執行。
- 肖像、live授權、Presenter UI及其他未完成事項按範圍分開：缺素材不可宣稱完整offline starter；offline通過也不能宣稱live-ready。company-24現附的CC0證據需實際核對，不推定其他來源也獲授權。

只修已證實問題及直接影響，不全面改寫、擴權或新增工具鏈。
