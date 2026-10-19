# 语阅 Yuyue

读书、听书、看漫画的 App。没有服务器，免费。

- 要做什么：[FEATURES.md](FEATURES.md)
- 怎么做：[TECH.md](TECH.md)
- 设计：`design-language-v0.21-confirmed.html`、`prototype-v0.28.html`

## 目录

```
core/       Rust 核心：导入和整理书、断句、进度、同步日志。iPhone、Mac、Android 共用
reader/     书页（TypeScript），在系统的网页控件里排字、高亮
design/     设计参数（颜色、字体……）和生成脚本，一份参数生成三个平台的代码
apple/      iPhone、iPad、Mac（SwiftUI）
android/    Android（Kotlin + Compose）
fixtures/   测试用的书
scripts/    开发用的小脚本
docs/dev/   给开发看的约定（英文），比如书页和原生之间怎么通信
```

## 现在做到哪

第一步"打地基"（TECH.md 第十四节）。

## 开发环境

- Rust：`~/.cargo/bin`（用 rustup 装的，没改 shell 配置，用前先 `. ~/.cargo/env`）
- Node 24、pnpm
- Xcode 27、XcodeGen
- 暂时没有：iOS 模拟器、Android SDK（磁盘空间不够，先在 Mac 上验证）
