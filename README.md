# 摄影风格 3（PhotoStyles3）

给老机型拍的照片加上 iPhone 18 Pro 的新影像风格：**摄影风格 3（Photographic Styles 3）**。

流程：从相册选一张照片 → 选择风格 3 的新元素 → 保存到相册。

风格 3 相比前代的新增项（据公开报道整理）：
- **质感 Texture**：标准 / 柔肤（Soft Skin）/ 光晕（Glow）/ 胶片（Film），带强度
- **颗粒 Grain**：胶片颗粒开关（原机上没有强度滑杆）
- 叠加在原有的色调（Tone）/ 色彩（Color）调色板之上

本 App 用 Core Image 在后期模拟这套效果。需要说明：原机的风格是在拍摄管线中结合场景语义实时计算的，后期模拟效果接近，但不完全相同。

## 构建

GitHub Actions 使用 Xcode 27.2 / iOS 27.2 SDK（`xcode-27` runner）构建未签名 IPA，最低系统 iOS 17.0。

## 安装

用 AltStore / SideStore 安装 `PhotoStyles3.ipa`（会用你的 Apple ID 重新签名）。
