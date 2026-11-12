# company-24：24位固定人物與CC0寫實虛構肖像

24位人物、24張不同寫實虛構肖像、真實SHA-256及逐張來源／權利證據已提供，可作為**離線可驗證的公開starter**。Persona、rich及minimal的正式validator皆通過；這不代表已獲得租用戶操作授權、服務／Presenter UI或Copilot已就緒。

本包為原創虛構的「晨澄實業集團」，與任何同名公司或人物無關；沒有真實 tenant 名冊、帳號、照片、客戶或交易。Presenter 是使用者原有帳號，不在這 24 人內。

## 固定組織

4 個營收 BU 各 5 人，加上 4 位共享服務人員。`shared` 是共享角色的分類，不是第 5 個營收 BU。角色選取見 `examples\rich-training\scenario.json`；未被課程選取的人物仍保留固定身分。

| personaId | 姓名 | 職稱／職責 | managerRef |
|---|---|---|---|
| mfg-yating | 林雅庭 | 製造總經理；產能與品質放行 | shared-bowen |
| mfg-chenghan | 陳承翰 | 製程品質經理；複測與隔離 | mfg-yating |
| mfg-yijun | 黃怡君 | 生產規劃經理；試點與備援排程 | mfg-yating |
| mfg-junwei | 吳俊緯 | 設備整合工程師；設備參數與驗收 | mfg-yating |
| mfg-xinyi | 周欣怡 | 供應鏈專案專員；追溯與交貨 | mfg-yating |
| it-ziqian | 張子謙 | 資訊總經理；架構與交付範圍 | shared-bowen |
| it-yunru | 許芸茹 | 資料工程師；去重與事件口徑 | it-ziqian |
| it-guanlin | 郭冠霖 | 應用系統架構師；介接與回退 | it-ziqian |
| it-peishan | 羅珮珊 | 服務交付經理；變更與事件管理 | it-ziqian |
| it-zhenyu | 葉振宇 | 測試自動化工程師；驗收證據 | it-ziqian |
| fin-huiling | 劉慧玲 | 金融營運總經理；資金條件核准 | shared-bowen |
| fin-yuchen | 蔡昱辰 | 財務控制經理；驗收與付款閘門 | fin-huiling |
| fin-jingwen | 鄭靜雯 | 風險分析師；假設與例外 | fin-huiling |
| fin-shaoyu | 謝紹宇 | 管理會計分析師；成本與台帳 | fin-huiling |
| fin-yiting | 何宜庭 | 營運稽核專員；核准證據 | fin-huiling |
| tel-guanwei | 楊冠維 | 電信總經理；服務範圍與資源 | shared-bowen |
| tel-siyu | 蘇思妤 | 網路可靠性工程師；探測與切換 | tel-guanwei |
| tel-jiahao | 鄧家豪 | 企業網路方案經理；連線設計 | tel-guanwei |
| tel-yuxuan | 沈宇軒 | 服務營運分析師；觀測與事件關聯 | tel-guanwei |
| tel-wanqing | 江婉晴 | 客戶成功經理；內部需求與交接 | tel-guanwei |
| shared-bowen | 宋博文 | 執行長；集團治理 | null |
| shared-ruoning | 梁若寧 | 專案管理經理；跨 BU 里程碑 | shared-bowen |
| shared-yijie | 方奕傑 | 採購經理；合約與驗收包 | shared-bowen |
| shared-yawen | 唐雅雯 | 資訊安全經理；資料邊界與撤銷演練 | shared-bowen |

`personas.json` 有完整自然姓名、穩定 alias、部門、公司、虛構辦公地點及無循環主管樹；全部 `licenseProfile` 為 `m365-demo`。這是設定名稱，不是 SKU ID，也不保證服務已就緒。

## 肖像與獨立圖片授權

- `avatars\`只含24張正式RGB 512×512 JPEG；沒有真人來源、插畫、測試圖或候選圖混入。
- 唯一來源為發布者David Beniaguev（SelfishGene）的[SFHQ Part2 version 4](https://www.kaggle.com/datasets/selfishgene/synthetic-faces-high-quality-sfhq-part-2)小樣本，透過官方匿名逐檔GET取得，沒有帳號、憑證、完整archive或其他圖源。
- 圖片授權為[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)，依發布者Kaggle Dataset JSON-LD的`CC0: Public Domain`宣告核實，**不是從repo的MIT程式碼授權推定**。保留自願署名，不改標MIT。
- [ASSET-LICENSES.md](ASSET-LICENSES.md)、`portrait-rights-manifest.json`及`rights\<personaId>.txt`逐張記錄官方永久來源端點、原圖／處理後hash、授權、生成provenance與處理方式。舊的缺圖模板與占位值已移除。
- 發布者[生成說明](https://github.com/SelfishGene/SFHQ-dataset)描述Part2以Face Synthetics及Stable Diffusion v1.4肖像靈感，經e4e／StyleGAN2合成、篩選。未提供逐圖prompt／seed或靈感分支，證據不捏造這些資訊。
- 40張小量候選中視覺選出24張不同、成人外觀、寫實且適合中性專業頭像的圖；排除兒童／年齡難判、非人類、幻想、制服、明顯低品質候選。姓名配置只作虛構角色casting，不辨識真人或推論敏感特徵。
- 原圖皆1024正方形，完整縮為512，無裁切、修臉、另生成或保留EXIF；視覺與像素去重不能排除所有真人相似或模型偏差。
- validator仍fail closed：缺圖、hash不符、重複或缺權利文件都會拒絕，沒有成功fallback。

## 離線使用與後續替換規則

從專案根目錄執行，不需要config、帳號或網路：

```powershell
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --personas .\personas\company-24\personas.json
uv run --no-project --python .\.venv\Scripts\python.exe python .\generator\validate_pack.py --pack .\examples\rich-training\scenario.json --personas .\personas\company-24\personas.json
```

預期各為`{"valid": true, "errors": []}`、exit 0。正式素材已在repo，執行時不會下載SFHQ或依賴任何影像服務。

換圖時仍須逐張查權利／生成來源與視覺品質，更新實際檔案hash、canonical rights與manifest；不能以空白模板或程式碼MIT充當圖片授權。初始化或每日RunAll另見[操作指南](..\..\docs\getting-started.md)，必須取得live授權、核對席次／服務並明確確認；離線通過不是live-ready。
