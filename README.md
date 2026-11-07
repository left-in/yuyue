# 语阅 Yuyue

读书、听书的 App，支持 iPhone、iPad、Mac 和 Android。没有服务器，书和笔记都留在你自己的设备上。

## 安装

从 [Releases](https://github.com/left-in/yuyue/releases) 下载。语阅不上架应用商店，也没有 Apple 开发者签名，所以安装时多几步。

**Mac（Apple 芯片，macOS 15 及以上）**

1. 打开 `.dmg`，把语阅拖进“应用程序”。
2. 第一次打开会被系统拦下，去“系统设置 → 隐私与安全性”，点“仍要打开”。

Key 和密码存在 App 沙盒文件夹里的一个明文文件中，只有你的用户账号能读，不同步。

**Android（8.0 及以上）**

下载 `.apk`，允许浏览器或文件管理器安装未知来源的应用，然后安装。

**iPhone、iPad（iOS 18 及以上，进阶用户）**

用 [Impactor](https://github.com/claration/Impactor) 和你自己的 Apple ID 给 `.ipa` 签名并安装，或者用 Xcode 从源代码编译。

- 免费 Apple ID 签的 App 7 天后过期，要重新签名。
- 手机要打开开发者模式，还需要一台电脑。
- Impactor 是第三方工具，要输入你的 Apple ID，建议用小号。这种安装方式苹果随时可能改变，语阅不保证一直可用。

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

打包三端的发布文件到 `dist/`：`scripts/package-release.sh`，也可以只打一部分，比如 `scripts/package-release.sh mac android`。Android 正式版的签名配置放在 `android/keystore.properties`（不进仓库）。

## 许可

语阅以 [GPL-3.0](LICENSE) 发布，第三方组件和模型的许可见 [NOTICE](NOTICE)。
