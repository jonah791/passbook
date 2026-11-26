# passbook

本地优先的跨端密码本。库在你自己手里，两台设备连同一个 WiFi 就能同步，没有账号，也没有服务器。

Windows 与 Android 共用一套 KDBX 库格式（Keepass 2 的格式），所以用它记下的东西随时可以拿别的密码管理器打开——不被这个应用锁死。

## 有什么

- **便签式的记法**：打开即列表，点加号就记，改完自动保存。不需要先想清楚「这条该归类到哪个文件夹」。
- **标准 KDBX 库**：AES-256 加密，文件就是普通的 `.kdbx`。拿走文件、换个软件照样能读。
- **局域网直连同步**：两台设备在同一个 WiFi 里，一端显示 6 位配对码，另一端填地址和码即可。同步链路只传**加密后的库文件**，配对码一次性、用过就换。
- **合并而不是覆盖**：不同条目各改各的都保留；同一条两边都改了，取改动更晚的那份，输掉的那版进历史；一边删了、另一边同时改，删除优先（墓碑生效）。新设备第一次同步会整库接管，而本机已有内容时**拒绝**被对端顶掉。
- **自动更新**：从 GitHub Releases 取新版本，校验 SHA256 之后才装。
- **无遥测**：外联只有一个去处——GitHub（查有没有新版、下安装包）。没有统计 SDK、没有崩溃上报、没有账号体系。

## 装

去 [Releases](https://github.com/jonah791/passbook/releases) 下对应端的产物：

| 平台 | 文件 | 怎么用 |
|---|---|---|
| Windows | `passbook-windows-x64.zip` | 解压到任意目录，双击 `passbook.exe`。免安装，删目录即卸载。 |
| Android | `passbook-android.apk` | 直接安装。首次装需要在系统里允许「安装未知应用」。 |

## 自动更新是怎么工作的

1. 启动时静默查一次（12 小时最多一次，失败不打扰），也可以在「关于与更新」里手动查。
2. 有新版本时，列表头会出现一枚「新版 vX.Y.Z」，点进去看发布说明。
3. 点「下载并安装」：下载产物 → **核对 SHA256** → 装上。
4. Windows 上是「退出 → 由脚本等进程结束后覆盖文件 → 自动重开新版本」；Android 上是「下载 APK → 交给系统安装器」。

**安全判据**：发布里没有该产物的 SHA256 摘要，或者摘要对不上，应用就**不装**——宁可让你手动下载，也不让你装上没核对过的程序。这一点对密码本尤其重要：自动更新等于把「装什么」的决定交给了网络。

## 从源码构建

需要 Flutter 3.41+（Dart 3.11+）。

```bash
cd app
flutter pub get
flutter test          # 74 条
flutter analyze       # 应当 0 issue
flutter build windows --release    # 产物在 build/windows/x64/runner/Release/
flutter build apk --release        # 产物在 build/app/outputs/flutter-apk/app-release.apk
```

Android 侧注意两点（都写在 `app/android/app/build.gradle.kts` 的注释里）：`ndkVersion` 必须与 `flutter.ndkVersion` 一致（`path_provider_android` 经由 `package:jni` 硬性要求）；仓库镜像要加在 **settings 级**，加到 project 级会被 Flutter 的 included build 以 `FAIL_ON_PROJECT_REPOS` 拒绝。

## 打一个发布

```powershell
pwsh -File scripts/release.ps1 -Tag v1.0.1
```

脚本会按 `app/pubspec.yaml` 里的版本号构建 Windows 与 Android 产物、生成 `SHA256SUMS.txt`、调 `gh release create` 上传。版本号的**唯一真源**是 `app/pubspec.yaml` 的 `version:`——发布标签与它不一致时脚本会拒绝执行（否则应用查到的「最新版」和实际装的版本会对不上）。

## 已知限制

- **Android 的签名**：仓库里的 release 构建沿用 debug 签名。自动安装新版本要求「新旧 APK 用同一把钥匙签」，所以只有持续用同一条构建链产出的包才能平滑升级；换正式签名需要卸载重装一次（会丢本地库文件，先导出）。要给公开发布配正式签名，见 `app/android/app/build.gradle.kts` 的 `signingConfigs`。
- **局域网同步要求同一网段**：跨网段、跨 NAT 不通——那需要中继服务器，与「没有服务器」的定位冲突。
- **iOS / macOS / Linux 未做**：代码是 Flutter，理论上能扩，但没有验证过就不写在支持列表里。

## 许可

MIT，见 [LICENSE](LICENSE)。
