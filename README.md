# 米读 MiDu

> Legado 书源原生支持 · 跨源聚合搜索 · 阅读换源 · 玻璃态 UI 的开源电子书阅读器

米读是一款基于 Flutter 的电子书阅读器，专注于完美兼容 Legado（阅读）书源格式，提供跨源聚合搜索、阅读时一键换源、书源健康检查等增强能力，界面采用紫色玻璃态设计，主要面向 iPhone 适配。

## 特性

- **Legado 书源原生支持**：基于 [fjs](https://pub.dev/packages/fjs)（Rust + QuickJS）执行书源中的 JavaScript 规则，注入 `document`、`$`、`java.crypto` 等 polyfill，完美兼容 `完美书源.json` 等 Legado 书源集合。
- **跨源聚合搜索**：所有书源并发搜索，结果按相关性三级排序去重合并——书名+作者完全一致优先，其次是书名一致作者不一致，最后按模糊匹配程度排序，而非按书源拼接。
- **阅读手动换源**：阅读时点击换源面板可展示该书的其他可用书源，基于章节标题相似度 + 序号比例双对齐算法切换并跳转到对应章节。
- **书源健康检查**：手动触发探测搜索→详情→目录→正文链路，失效源弹窗可选择暂时屏蔽 7 天，屏蔽期间自动从运行时过滤。
- **玻璃态 UI**：紫色品牌色（#6C4CF6）+ 毛玻璃模糊 + 动态渐变 + 微动效，iOS 风格连续圆角与水平推入路由。
- **多平台书架**：本地导入（EPUB/TXT/PDF/Kindle）与在线书源统一管理。

## 安装

米读不上架 App Store，仅支持巨魔（TrollStore）和自签安装。请从 [Releases](../../releases) 下载 `.ipa` 文件：

- **TrollStore**：将 IPA 拖入 TrollStore 安装，无需签名，永久有效。
- **自签**：使用 AltStore / Sideloadly / 巨魔等工具用个人 Apple ID 签名安装（7 天有效期）。

## 构建

```bash
# 安装依赖
flutter pub get

# 运行分析
flutter analyze

# 构建未签名 IPA（供 TrollStore / 自签）
flutter build ipa --release --no-codesign
```

## 技术栈

- **Flutter** 3.47+ · Material 3 · iOS 优先
- **fjs** 3.3.0 · Rust + QuickJS JavaScript 运行时（书源 JS 规则执行）
- **Dio** 5.7 · 网络传输
- **sqflite_common_ffi** · 本地数据库
- **shared_preferences** · 书源注册与健康屏蔽存储

## 书源

米读不内置任何书源。导入你自己的 Legado 书源集合（如 `完美书源.json`），通过应用内「书源管理」页面导入即可。

## 协议

MIT License
