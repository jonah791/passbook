# passbook — 跨平台密码本

## 目标

一个**本地优先、零外联**的跨平台密码管理器。Windows 与 Android 优先，数据用标准 KDBX 4 文件。
交互按**便签应用**的心智做：打开即列表、点加号就能记、输入即存，不需要学。

## 出处

主人 2026-11-26 11:05 原话：「要不然我们自建一个跨平台密码本」。
11:25 追加定调：「降低使用复杂度，对标主流便签应用」。
背景：审计 keestone（外联少但依赖第三方库、功能单薄）与 Monica 三仓（设计强但重、GPL、默认向 Google 发域名清单）之后的自主选择。

## 边界（第一版）

**做**
- 新建 / 打开 / 保存 KDBX 4 文件（主密码，后续加密钥文件）
- 条目列表 + 全屏编辑（标题 / 正文 / 用户名 / 密码 / 网址）
- 搜索、复制（剪贴板 30 秒后自动清空）
- 自动保存（输入即存）、自动锁定（5 分钟无操作）、密码生成器
- **局域网同步**：两台设备连同一个 WiFi，一端开端点、一端去连，按条目 UUID 双向合并
- 标准 KDBX：KeePassXC / 手机端 KeePass 能直接打开，数据不锁定

**不做**
- 云同步（用你自己的网盘放文件即可）；局域网同步是点对点直连，不经过任何中转
- 自动后台同步（第一版手动触发：页面一关端点就关）
- 浏览器自动填充扩展
- 生物识别（后续）
- 任何网络请求：不检查更新、不取网站图标、无遥测

## 技术选型（含理由）

| 选择 | 理由 |
|---|---|
| Flutter + Dart | 一套代码覆盖 Windows / Linux / macOS / Android / iOS；本机 Flutter 3.41.9 / Dart 3.11.5 |
| `kpasslib`（MIT） | 纯 Dart 的 KDBX 3/4 读写，Argon2id + AES-KDF，无原生依赖 |
| 标准 KDBX 4 | 数据可迁移是硬要求；不用自有格式，避免 Monica 那种「只有它的客户端能读」 |

## 视觉定调（纸与墨）

一个日用密码本不该长得像仪表盘——它该像**一页安静的纸**。
暖白纸底 / 墨色字 / 一根发丝线 / 唯一强调色是印章赤陶（只出现在品牌字、光标、焦点线、危险动作）。
层级全靠字号 / 字重 / 字距 / 留白建立；不加阴影、卡片、渐变、无意义的眉标。

**「高级」不是形容词，是一份可复核的破绽清单**（命中任何一条即返工）：
标题只把其中一个词换色 · 标签全大写 · 内容上方挂无意义的小标签 · 用
01/02/03 编号讲非序列内容 · 每段 fade-and-slide-up 或每张卡都悬停过渡 ·
大数字 + 小标签 + 渐变点缀的默认首屏。

复核方式：`app/test/visual_snapshot.dart` 零窗口渲染四屏（解锁 / 列表 / 编辑 /
深色）到 `app/test/goldens/`，看图判断，不看代码猜。

## 判据（可证伪）

**数据与安全**
1. 新建一个库 → 保存 → 用 KeePassXC 能打开，条目与密码一致（`app/test/kdbx_roundtrip_test.dart`）
2. 全程抓包：除用户主动打开的网址外无任何出网连接
3. 冷启动 → 解锁 → 复制密码，剪贴板 30 秒后自动清空
4. 解锁后 5 分钟无任何键鼠动作 → 锁回解锁页；锁定前正在编辑的内容必须已落盘
   （`app/test/idle_guard_test.dart` + `app/test/vault_flush_test.dart`，后者含负样本：
   没 flush 就 close 必须真的丢，否则那条 flush 就是装饰）
5. 生成的密码四类字符各至少一个、不含 0 O 1 l I（`app/test/password_gen_test.dart`）
6. Windows 与 Android 两个平台都能完成上述各条
   - **Windows 端**：已实测（`passbook.exe --selftest` + 常规测试）
   - **Android 端**（2026-11-26 实测，Android 14 / API 34 x86_64 模拟器）：
     `flutter build apk --debug` **退出码 0**，产物 `build/app/outputs/flutter-apk/app-debug.apk`（177 MB）；
     装上去能建库（提示「库已建在 /data/user/0/com.passbook.passbook/app_flutter/passbook.kdbx」）、
     关掉重开**直接问主密码而不是重建**、记条目、开同步页（读得到本机 IPv4 与端口）
   - 判据不是「日志里没报错」，是**退出码 + 产物存在 + 真跑一遍**：`| tail` 会把退出码换成 tail 的 0

**同步（局域网）**
7. 两端各改不同条目 → 同步后两端条目**完全一致**，谁的新东西都不丢
   （`app/test/sync_merge_test.dart`）
8. 一端删除 → 另一端同步后那条**不许复活**。这条靠墓碑（`deletedObjects`）：
   删除必须走 `db.move(item: entry)`（target 为 null 时才写墓碑），
   不能用 `db.remove()`（它会挪进回收站，条目仍在库里，合并后照旧看得见）
9. 同一端重复同步幂等：合同一份两次，条目数不变（不长出副本）
10. 配对码一次性：用过即换；错码必须被拒（`app/test/sync_lan_test.dart`）
11. **线上只走 KDBX 密文**：传输层不需要也不应该再见明文
12. 冲突的准确语义（都进了测试，别读成更强的承诺）：
   - 不同条目各改各的 ⇒ 都保留
   - 同一条两边都改 ⇒ **整体择一**（按修改时间，晚的赢；输的那版进历史可翻回），
     不是逐字段合并
   - 删除 vs 并发编辑 ⇒ **墓碑优先**，对端改了也不复活
13. 新设备第一次同步：本机是空库 ⇒ **整库接管**对端（根分组 UUID 不同也能接）；
   本机已有内容 ⇒ **拒绝覆盖并说明**——两条都在 `sync_merge_test.dart` 里

**跨端实测（2026-11-26，Windows ↔ Android 14 模拟器，同一局域网 192.168.50.0/24）**
- 安卓建空库 → 在同步页填 Windows 端 `192.168.50.204:8124` + 配对码 → **整库接管**，
  安卓列表 1 条「来自Windows端」；Windows 侧日志 `MERGED added=0 removed=0 after=1`
- 两端各自再加一条（安卓 `AndroidAdded`，Windows `Windows端新增`）→ 安卓再连（`:8125`）→
  **两端各 3 条，谁都没丢**；Windows 侧 `MERGED added=1 removed=0 after=3` 且打出了 `ENTRY AndroidAdded`
- 反向（Windows 主动拉安卓，经 adb 端口转发 46587）：`PULLED added=0 removed=0 after=3`，
  安卓页面显示「对端：两边已经一致（3 条）」，配对码已换成新的（一次性生效）
- 工具：`app/tool/lan_peer.dart`（无界面的命令行对端，跑同一份 `sync_lan.dart`）、
  `app/lib/lan_probe_main.dart`（装机探针，`--target` 打专用 APK）

**体验**
- 首次使用只设一个主密码，不让人选文件。库**优先放文档目录**；文档目录写不进去时
  自动退到用户数据目录（`%APPDATA%\com.passbook\passbook`），并把实际路径告诉用户。
  判据：这台机器开着 Windows「受控文件夹访问」，文档目录读得到、写不进，报错还是
  误导性的「找不到文件」⇒ **只查「目录存在」会误判成可用，必须实测写一次**
  （`app/test/vault_path_test.dart` + `passbook.exe --selftest` 真机复验）
- 输入即保存（800ms 防抖）；返回列表 / 窗口失焦 / 自动锁定都会先落盘，不丢字
- 解锁后光标已在搜索框；Ctrl+F 搜索 / Ctrl+N 新建 / Ctrl+L 锁定 / Esc 返回
- 每个版本必须过：`flutter analyze` 0 issues · `flutter test` 全绿 · `flutter build windows`

## 待主人定夺

- **全局热键 Ctrl+Alt+P 唤起**：要它就得后台托盘常驻（关窗不退、多一个常驻进程）。
  这是形态变化，不是复杂度降低，所以这一版没做。要做我加。

## 平台顺序

Windows（已跑通）→ **Android（2026-11-26 跑通：APK 构建 + 装机运行 + 与 Windows 双向同步）**
→ Linux / macOS（架构上留好，不急）

## 构建 Android 的四个坑（2026-11-26 实录，照着踩会省几小时）

1. **Gradle 下载被限速**：这台机器直连国际 Maven 时单个 jar 只有 ~6 KB/s（同一 URL 用 curl 是 3 MB/s）。
   给 Gradle 的 JVM 配本机代理即可（`%USERPROFILE%\.gradle\gradle.properties`）：
   `systemProp.https.proxyHost=127.0.0.1` / `systemProp.https.proxyPort=<本机代理端口>`
2. **镜像别塞进 project 级仓库**：Flutter 的 included build（`packages/flutter_tools/gradle`）
   声明了 `FAIL_ON_PROJECT_REPOS`，往 project 级加仓库会让它直接报
   「Build was configured to prefer settings repositories…」。镜像要写进
   `android/settings.gradle.kts` 的 `pluginManagement.repositories` 与工程 `allprojects`（本仓已写）。
3. **`ndkVersion = flutter.ndkVersion` 不能删**：`path_provider_android` 现在依赖 `package:jni`，
   它硬性要求 NDK 28.2.13676358；删掉会报「plugin(s) depend on a different Android NDK version」。
4. **pub 缓存的目录要可写**：`jni` 会用自己的 CMake 在 pub 缓存里建 `.cxx` 构建目录。
   缓存默认在 `%LOCALAPPDATA%\Pub\Cache`，写不进去就报一堆
   「CMake Error: Cannot open file for write … .cxx/…/CMakeCache.txt」——
   把 `PUB_CACHE` 指到一个可写目录再 `flutter pub get` 即可。
   （同理：`app/build` 若整个被挪走/换成只读，CMake 那一步也会这样报。）

## 目录

- `app/` — Flutter 应用（`lib/core/` 逻辑、`lib/pages/` 界面、`test/` 判据）
  - `app/tool/lan_peer.dart` — 命令行对端（无界面跑同一份同步协议，跨进程/跨设备联调用）
  - `app/lib/lan_probe_main.dart` — 装机探针（`flutter build apk --target=…`，把结果打进 logcat）
- `docs/` — 设计决定与判据
