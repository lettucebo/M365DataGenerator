# 固定人物與肖像 guideline

## 先定組織，不每堂課重造帳號

先閱讀 `config.json.example` 理解 public／private 邊界，再只把公開 schema、此 guideline、課程 brief、公開 persona pack 交給自己選擇的 AI。沒有指定供應商、帳號、API key 或服務；不需要將私有設定交給 AI。

建議使用固定公司與固定 `personaId`。課程只挑既有角色，不能為了故事改姓名、部門或主管；需要新公司或調整 profile 時，先獨立審核 Persona Pack，再走 `InitializePersonas` 的完整 diff 與確認。Scenario 沒有 profile 寫入能力。

`company-24`已提供完整24人資料與24張不同CC0寫實虛構肖像，可作為離線starter；來源、處理及逐張證據見`personas\company-24\ASSET-LICENSES.md`。使用者也可自行提供合法pack，24人不是通用限制。離線通過不授權任何live操作。

## 先選人物來源

兩種來源皆透過同一 App-only connector。初始化仍需本人預覽與確認；App 不是登入操作員。
Presenter 與舊設定明示的 adminOperatorUpn 都排除，Application 權限不會讓 RunAll 取得人員寫入能力。

| 來源 | 何時選 | pack | 工具會做什麼 |
|---|---|---|---|
| `Managed` | 租用戶沒有可用 Demo 人員 | 1.0（如 `company-24`，需肖像與授權設定） | 建立／修正受管人員、主管、照片與明選授權 |
| `Existing` | 租用戶已有專用 Demo 帳號，或有 Microsoft 365 sample pack | 1.1（`personas\m365-sample`、`personas\existing-template` 或自訂） | 只檢查你在本機 `accountMappings` 逐一指定的帳號，並調整四個文字欄位與 manager；不改姓名、UPN、照片、密碼、使用地區、授權、角色 |

Existing 的人數 N 是你這次選的帳號數（可少於 pack 人數，不要求 24 人），整批檢查、確認、讀回都針對這 N 人。`personas\m365-sample` 的姓名／alias 只是 `identityHint`，**不是帳號 provenance**，工具不會單憑姓名認領帳號：你指定的 UPN 存在就沿用，只有它不存在時才以提示做有界精確查找並提議，仍由你確認；沒有 sample pack 的租用戶用 `existing-template` 的邏輯角色，或自訂 1.1 pack。下方「肖像人工 gate」只適用 Managed。

## 可交給 AI 的 persona brief

```text
公司：原創虛構，繁體中文（台灣）；不影射真實客戶或組織。
組織：製造／資訊／金融營運／電信各5人，共享服務4人。
穩定性：personaId、alias與姓名跨課程保持；Presenter不在集合內。
職責：每個BU有主管、交付、分析與執行職能，避免24人都叫專案經理。
主管：一個明確根節點；BU主管及共享主管向其報告，其他人指向對應主管。
授權設定名稱：m365-demo；不猜SKU、租用戶可用席次或服務就緒。
肖像：由有權提供素材的人員另外供應、逐張查證。沒有素材時明列missing並停止釋出；
      不要求AI假造授權、SHA-256、來源、照片或證據。
輸出：僅符合schemas\personas.schema.json的JSON；權利蒐證狀態放獨立manifest。
```

資料形狀見 [data-contract.md](data-contract.md)，提示可用 `prompts\persona-generation.md`。姓名要自然、區別清楚，不用 `Demo User 01`、`Manufacturing A` 當顯示姓名；相同常見姓氏可以，personaId／alias 仍須唯一。

## 可交給 AI 的 Existing persona brief

```text
公司：原創虛構，繁體中文（台灣）；不影射真實客戶或組織。
人物：只描述邏輯角色與職責（例如「營運主管」「資料分析」「專案協調」）；
      不提供真實名冊、UPN、objectId、租用戶資料或真人姓名。
profile：每人至多 jobTitle／department／companyName／officeLocation，每項 1–128 字元；省略代表不修改。
主管：managerRef 只指向同批人物，一個明確根節點；不要求移除既有主管。
輸出：僅符合 schemas\personas.schema.json 1.1 的 JSON（沒有肖像、授權或帳號欄位）。
```

Existing 的 UPN 只由本機私有 config 的 `accountMappings` 提供（不存在時由工具在本機解析並於確認後存回），不交給 AI，也不寫進 public pack。

## 肖像人工 gate

正式每人一張不同寫實虛構專業大頭照 JPEG；不用真人、插畫、純色測試圖、同一人裁切／換 metadata 或抓取未明確授權的網站。沒有已核實來源時，正確選擇是缺失，而不是網站看似免費便猜測可散布。

逐張保留：

1. 檔案 SHA-256、來源完整 URL、取得日期、原創者／提供者。
2. 生成來源與虛構人物證據，不把第三方轉貼或「AI」標籤當完整 provenance。
3. 明確可公開散布及所需使用方式的授權／條款原文、版本、URL與署名要求；有疑義交有資格人員判定。
4. 非空 UTF-8 本機證據文件；模板、占位字或程式碼 MIT 不能替圖片授權。
5. 人工確認專業構圖、自然寫實、無明顯瑕疵、24 張不同面孔，並記錄 reviewer／日期。

機器 validator 只驗檔案、雜湊、參照、部分重複與證據檔存在，不審判法律權利，也不做人臉辨識。即使拿虛假聲明讓 JSON 通過，也不算符合此 guideline。

本包實際來源是發布者SFHQ Part2 v4的官方小樣本，發布者Kaggle Dataset JSON-LD明列CC0；repo的MIT只用於code。生成說明是資料集層級e4e／StyleGAN2流程，Part2含Face Synthetics與Stable Diffusion v1.4靈感；不捏造逐圖prompt／seed或敏感人物特徵。檔案hash與視覺審閱不保證完全無真人相似或模型偏差。

## 正反例

- 好：林雅庭（製造總經理）決定放行，陳承翰（品質）提出分母／隔離異議；固定 `managerRef` 與職責可解釋。
- 壞：每課將同一帳號重新命名不同主管，或用 Teams 顯示文字偽裝作者。
- 好：未知來源在獨立 manifest 標 `missing`，照片缺檔使 full pack 被拒絕。
- 壞：用測試 JPEG、網路真人或 `license:"MIT"` 填空就宣稱合法。
- 好：`licenseProfile:"m365-demo"` 對應使用者私下選的實際 SKU 集合。
- 壞：以「tenant 有 25 人」推定還有 24 個可新增席次，或回收他人 license。
- 好：Existing 在本機 `accountMappings` 明確寫 `personaId → 你選定的 UPN`，先看完整 `原指定 → 實際帳號` 與 Before → After 再確認。
- 壞：因為顯示名稱或 alias 相似就直接認領 tenant 內的帳號（沒有唯一精確匹配、沒有你的確認），或把 Presenter／登入操作員當作 Demo 人員。
