# Persona generation prompt（供任何 AI）

只需此 prompt、公開 `schemas\personas.schema.json`、`docs\persona-guidelines.md` 與公開 persona 範例。不要提供任何私有 config、directory roster、UPN、tenant ID、binding、token 或密碼。

---

你要產生可公開分享的原創虛構組織資料，不是 Microsoft 365 真實帳號。

輸入 brief：公司／產業、語言、BU 數量與人數、共享職能、人物來源（`Managed`：使用者核准的 licenseProfile 名稱與肖像；`Existing`：沿用租用戶已有的專用 Demo 帳號）。若沿用 company-24，請保持全部 personaId、alias、姓名與主管關係；課程變動不是改 profile 的理由。

要求：

1. 先列職責與主管樹，確認完整且無循環，人物有自然、可區別的姓名；Presenter 不在集合內。
2. 僅依實際 `personas.schema.json` 輸出 canonical JSON。Managed（1.0）root 是 packId/version/company/businessUnits/people/avatarAssets，不加 UPN、objectId、password 或 status。
3. `companyName` 與 company.name 一致；每人完整職稱、部門、虛構辦公地點、managerRef、avatarAssetId、licenseProfile。
4. 逐人肖像必須來自使用者已核實合法的寫實虛構大頭照及權利證據；**你不能編造圖片、來源、授權、SHA-256 或聲稱看過未提供的檔案**。
5. 缺照片時，把缺失列在獨立rights manifest，說明pack無法完整驗證／初始化，不以真人、插畫、測試圖或猜測hash頂替。company-24現附的24張正式CC0肖像與逐張證據可參考，但不得將其授權擴張到其他來源或改標MIT；不捏造發布者未提供的逐圖prompt／seed。
6. 素材齊備時，由本機可信工具計算真實 hash、驗圖與證據檔；人工逐張覆核。AI 文字回覆不能取代這些步驟。

**Existing 來源（pack 1.1）**：root 是 packId/version:"1.1"/accountSource:"Existing"/company/businessUnits/people，**沒有 avatarAssets、avatarAssetId、licenseProfile、UPN、password、objectId**。每人只需 `personaId`，可選 `profile`（只限 jobTitle／department／companyName／officeLocation，各 1–128 字元；省略代表不修改）與 `managerRef`（同批人物或 null）。人物只描述**邏輯角色與職責**，不得使用真人姓名、真實名冊、UPN 或租用戶資料；只有 Microsoft 365 sample pack 這類公開示意才可把姓名／alias 放進 `identityHint`，且那只是提示，不是帳號證明。實際 UPN 由使用者在本機 `accountMappings` 指定，你不處理也不猜；只有使用者指定的 UPN 不存在時，本機工具才以 `identityHint` 做有界精確查找並請使用者確認，候選名冊不會交給你。

交付：persona JSON、公開職責說明、肖像／證據已具備與缺失的清單（Managed），或所選人物與角色職責清單（Existing）、尚不能完成的原因。不要產生初始化腳本、密碼或租用戶設定。禁止把「JSON 格式通過」說成「服務可用／權利合法」。
