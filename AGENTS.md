# 公開教材與 AI 協作規則

- 除程式碼／識別碼外使用繁體中文（台灣）。故事必須原創虛構，不複製私有郵件、Teams、名冊或課程內容。
- 權威介面是 `schemas\*.schema.json` 與 `generator\validate_pack.py`；不為方便新增另一套 emails／YAML／Graph ID 格式。詳見 `docs\data-contract.md`。
- 公開 persona 只定義邏輯身分；Scenario 只引用固定人物，不改 profile。Presenter 是既有私有帳號，不在 personas／roles 內，也不作歷史作者。
- 人員來源有兩種，由私有 config **明確選擇**，不自動掃描租用戶替你決定：`Managed`（config／personas 1.0，建立受管人員）與 `Existing`（1.1，採用使用者明確 `accountMappings` 指定的既有 Demo 帳號）。兩者共用同一組 Mode，Existing 沒有新增模式或框架。
- 不讀取或傳給 AI：私有 config、binding、run-state、tenant roster、token、secret、密碼或真實內容。public prompt 不需要任何 API key 或指定 AI 平台。
- **company-24已附24張不同CC0寫實虛構肖像與逐張來源／權利證據，可作offline starter，不是live-ready。** 核對`personas\company-24\ASSET-LICENSES.md`、權利manifest及真實hash；圖片CC0與程式碼MIT分開，不以真人、插畫、測試圖或假證據補位。`personas\m365-sample`（16 個公開示意姓名）與`personas\existing-template`（三個邏輯角色）是 Existing 的起點，沒有肖像／授權；sample 姓名只是提示，不是帳號 provenance，也不是 Microsoft 官方 profile；它們只在你指定的 UPN 不存在時用於有界精確查找（見下方 Existing 規則）。人數 N 是使用者本次選取的帳號數，不寫死為 3、16 或 24。
- 不修改 validator／schema 來略過缺肖像。隔離離線測試可以使用清楚標示的測試作品，但只能在使用者明確允許的測試副本；不得混進發布的 personas／examples。
- 完整故事須有多角色實質往返、跨日里程碑、表格、取捨、決策、owner／deadline與證據索引；`docs\scenario-guidelines.md`、`prompts\quality-review.md` 為內容品質基準。
- 真實檔案hash由工具計算，不猜；source／license需實際證據與人工覆核，不從程式碼MIT推定圖片權利。
- 初始化與每日RunAll分開：Managed 初始化改人員／manager／photo／license；Existing 只調整四個文字欄位（jobTitle／department／companyName／officeLocation）與 manager，不碰姓名、UPN、照片、密碼、使用地區、授權或角色。RunAll 只建立課程內容。兩者都需明確確認，NonInteractive不是同意，offline通過不是live授權。
- 所有連線模式皆使用同一 App 的 client credentials；secret 僅來自 process 環境變數，不使用 Graph SDK／device login fallback。Application grants 不擴大 Mode／one-shot capability。Presenter 與舊 adminOperatorUpn 只作保護帳號，不冒稱登入操作員。
- Existing 必須整批 N 人先全部唯讀檢查通過才進入提醒／確認，再逐人寫入並整批讀回；任何一人 Block、Unknown 或未完成都不標成功、不重試、不回滾。確認必須由使用者本人輸入（含 `DemoAccountAcknowledged`），AI 與程式碼不得代填；`DemoAccountAcknowledged` 表示使用者已核對並同意此 fingerprint 列出的實際帳號作 Demo profile 更新，工具不檢查也不修改目標帳號的目錄角色；驗證的是 App 的必要 Application roles，不是個人管理角色。實際 UPN／Before→After 只在本機顯示，不傳給 AI。
- 不自動購買／回收license、不把tenant人數當可用席次、不採用同名既有資源、不重送Unknown、不刪除／rollback作補救。Existing 不單憑姓名／alias 認領帳號：你指定的精確 UPN 存在就沿用；只有它不存在（404）且尚未綁定時，才用 public `identityHint` 做有界、GET-only 的精確查找。唯一完整精確匹配只是列入整批預覽的提議；多筆／相似／找不到由使用者在本機**一次**明確選擇（找不到同一人時可選替代者，標 `UserSelectedReplacement`，替代者保留自己的姓名與照片）。選人不是寫入同意，候選名冊不傳給 AI；403／逾時不是「不存在」；已完成 binding 的帳號不再依名稱重配；通過檢查的帳號仍不當成工具建立的 Provisioned。
- live結果必須read-back；SharePoint Graph結構證據不是Presenter effective ACL或UI proof。完成後從實際結果提供site／List直接連結，不猜URL。
- 依 `docs\testing.md` 分開報告offline、未授權live、Presenter UI與Copilot readiness。沒有執行的驗證明列未執行；有缺口即保留blocked，不誤報完整完成。
