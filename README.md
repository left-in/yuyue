# 语阅 Yuyue

读书、听书的 App，支持 iPhone、iPad、Mac 和 Android。没有服务器，书和笔记都留在你自己的设备上。

## 目录

```
core/       Rust 核心：导入和整理书、断句、进度、同步。各平台共用
reader/     书页（TypeScript），在系统的网页控件里排字、高亮
design/     设计参数（颜色、字体……）和生成脚本，一份参数生成各平台的代码
apple/      iPhone、iPad、Mac（SwiftUI）
android/    Android（Kotlin + Compose）
shared/     各平台共用的资源
fixtures/   测试用的数据
scripts/    开发用的小脚本
docs/dev/   给开发看的约定，比如书页和原生之间怎么通信
web/        官网
```

## 构建

需要 Rust、Node、pnpm；Apple 端另需 Xcode 和 XcodeGen，Android 端另需 Android SDK 和 NDK（用 `ANDROID_HOME` 指定）。

```sh
# 书页
cd reader && pnpm install && pnpm build

# Apple
apple/build-core.sh
cd apple && xcodegen

# Android
android/build-core.sh
cd android && ./gradlew assembleDebug
```

测试：`cargo test`（在 `core/` 下）、`pnpm test`（在 `reader/` 下）。

## 许可

语阅以 [GPL-3.0](LICENSE) 发布，第三方组件和模型的许可见 [NOTICE](NOTICE)。
