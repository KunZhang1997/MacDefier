# MacDefier App（工程说明）

**Bundle ID：** `com.macdefier.app`（禁止 `eu.exelban.*`）  
**唯一应用路径：** `/Applications/MacDefier.app`（全链路单一构建，不并存 Dev/Trial/备份 `.app`）  
**开源许可：** MIT（第三方开源署名见 `app/NOTICE`：Stats、PureMac、ZIPFoundation、Sparkle）  
**现行直装基线：** `v0.21`（Developer ID 签名 + Apple 公证 DMG + Sparkle 2.9.4 官网签名更新源）

---

## 工程结构

```text
app/
  MacDefier/            # SwiftUI 主应用（横向七入口工作台 + 悬浮窗宠 Mr. Defier + 菜单栏双列面板）
  MacDefierTests/       # 主工程正规单元测试（XCTest：AI 策略/传输/档案隔离、更新状态机、诊断等）
  CleanupKit/           # 清理、软件盘点、CLI 多前缀治理、AI 工具数据与磁盘空间树图（Swift Package）
  MonitorKit/           # 本机硬件与进程采样、磁盘 I/O、SMC 只读温转与卡顿事件回看（Swift Package）
  PetArchiveKit/        # 窗宠压缩包安全校验与解包（Swift Package）
  UninstallHelperKit/   # 受限管理员卸载助手 Core / IPC / Client（Swift Package）
  UninstallHelper/      # 内嵌 SMAppService LaunchDaemon 可执行目标
  Config/               # 构建与签名配置
  Vendor/               # 第三方源码依赖（ZIPFoundation）
  scripts/              # 单一构建生命周期、打包公证、Sparkle 清单与助手门禁脚本
  project.yml           # XcodeGen 工程真源
  NOTICE                # 第三方开源许可证声明
```

## 工作台信息架构

- **主窗口顶栏横向七入口**（快捷键 `⌘1`–`⌘7`）：
  `诊断` ｜ `清理` ｜ `AI 工具` ｜ `磁盘文件` ｜ `软件` ｜ `监控` ｜ `设置`
- **悬浮参谋 `Mr. Defier`**：主窗内自由拖动窗宠（仅避让顶栏），点击展开对话气泡；关闭 AI 时全部扫描、清理、卸载与监控功能独立可用。
- **菜单栏常驻面板**：原生双列实时状态浮层（CPU 分核、GPU/内存/网络曲线、系统盘空间、电池、Apple Silicon 只读温度与风扇 RPM、Top 5 进程及快捷入口）。
- **明确不做进产品壳**：直接改 `vendor/stats` 品牌发版、`eu.exelban.*` 偏好域、远程多机监控、主动风扇调速控制、假内存加速、恐吓式杀毒或文件粉碎。

---

## 生成、构建与单一应用安装规则

本仓遵循**本机唯一应用构建规则**（`scripts/single_app_build.py`）：

1. 同一平台只维护唯一可运行路径 `/Applications/MacDefier.app`（使用生产 Bundle ID `com.macdefier.app` 与 Release 配置原位事务替换），**不再并行安装旧 `MacDefier-Dev.app` / `com.macdefier.app.dev`**。
2. `rebuild_and_launch.sh`、`scripts/install-app.sh`（及兼容转发入口 `scripts/install-dev-app.sh`）、`scripts/package-dist.sh`、`scripts/package-release.sh` 与 `scripts/ci.sh` 共用产品互斥锁；任务退出时自动注销 Launch Services 临时注册并清理构建/解包临时 `.app`，保留个人设置、AI 凭据、模型与应用支持数据。
3. 安装前先验签并请求旧实例正常退出，替换或拉起失败时自动回退；Debug 配置仅用于本地临时编译与单测，不落盘并行安装。

### 常用命令

```bash
cd app

# 1. 重新生成 Xcode 工程并执行临时无签名编译检查
xcodegen generate
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 2. 原位重建并启动唯一 /Applications/MacDefier.app（Release）
bash rebuild_and_launch.sh

# 3. 单一应用构建生命周期自检
bash rebuild_and_launch.sh --self-test
```

### 单元测试与全量 CI

```bash
cd app

# 四个独立 Swift Package 单元测试
swift test --package-path CleanupKit --jobs 2
swift test --package-path MonitorKit --jobs 2
swift test --package-path PetArchiveKit --jobs 2
swift test --package-path UninstallHelperKit --jobs 2

# 主工程单元测试（MacDefierTests）
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
  -destination 'platform=macOS' test \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 发布前全量门禁（生成工程 + 包单测 + 主工程测试 + Debug/Release 双构建）
bash scripts/ci.sh
```

### 分发打包边界

- **未公证试用包**：仅由 `scripts/package-dist.sh` 输出至 `dist/trial/`，文件名强制带 `-unsigned` 后缀。
- **正式公证发布包**：仅由 `scripts/package-release.sh VERSION` 输出至 `dist/release/`（如 `v0.19`）；须通过双架构（`arm64` + `x86_64`）构建、Developer ID 签名、Apple 公证、staple、`NOTICE` 检查、无 debug/preview dylib 检查及 `UninstallHelper` 校验后才落盘，同版本已存在时拒绝静默覆盖。

---

## 顶栏标签旁一键更新（Sparkle 2.9.4 · 官网唯一主源）

- **按需显示（七页共用标签栏右侧）**：七个一级页面共用顶部胶囊标签栏右侧紧邻的 `34×34 pt` 圆形下载按钮；仅在主窗启动或 App 回到前台触发 `checkForUpdateInformation` 静默读取官网签名元数据且确认有可安装新版时才创建按钮（无后台定时轮询；成功最短间隔 15 分钟，失败最短间隔 1 分钟）。最新版、查询中、离线或失败态完全隐藏入口，不显示「已是最新版」。
- **原位下载与互斥安装**：仅在用户点击圆形下载按钮后才开始下载，原位展示圆环下载进度并支持取消；准备安装时先获取 `ResourceMutationCoordinator` 互斥锁，等待当前正在执行的清理或卸载完成后再自动替换并重启，不强杀进行中的文件操作。
- **官网唯一主源与签名发布规范**：
  - 官网介绍页（应用内唯一外链入口）：`https://kun97.tech/macdefier/`（设置页「关于 → 官方网站」、菜单栏「帮助 → 官方网站」及 `⌘K` 命令面板均直跳该页面，应用内不展示 GitHub 链接）。
  - 固定更新源：`https://kun97.tech/macdefier/releases/appcast.xml`（无论用户最初从官网还是 GitHub Releases 下载安装包，客户端均统一以官网 `kun97.tech` 为唯一更新源，并在运行时拒绝非 `https://kun97.tech/macdefier/releases/` 的安装包地址）。
  - EdDSA 私钥仅存于发布机登录钥匙串账户 `com.macdefier.app.sparkle`（严禁入库或随包分发），仓库仅保留公钥。
  - 每次发版必须递增包内真实版本号并保持 `com.macdefier.app` 与同一 Developer ID 签名身份；运行 `scripts/package-release.sh VERSION` 后，将原始 `MacDefier-VERSION.dmg` 与签名生成的 `appcast.xml` 一并发布至官网 `https://kun97.tech/macdefier/releases/`（GitHub Releases 仅作额外分发镜像，不再承载 `appcast.xml`），上传后严禁二次改动文件。
  - 只读检查本机更新签名配置：`scripts/generate-update-feed.sh --check-signing`。

---

## 卸载权限边界与受限 `UninstallHelper`

### 卸载安全原则

- **普通用户优先**：卸载前先校验目标真实身份；仅当选中的 `/Applications/<name>.app` 一层主程序（含合规 `Wrapper/<name>.app` iOS 包装应用）在原子移动进废纸篓时因 `EACCES`/`EPERM` 失败，才进入受限管理员卸载助手。
- **禁止提权脚本与连带误删**：绝不执行 root shell、不改目标权限、不永久删除；`npm` / `Homebrew` / `uv` 等 CLI 工具始终以当前普通用户运行原包管理器命令，不提权执行第三方包脚本。
- **强先后依赖**：主程序未确认移走前严禁清理关联数据；扩展容器（`Contents/PlugIns/*.appex`）须通过 Apple 信任链与同 Team 签名归属核验且无其他存活所有者后才允许勾选。

### 受限 LaunchDaemon 实现与门禁

- **分层与双向验签**：`UninstallHelperKit` 分离 `Core`、`IPC`、`Client`；内嵌 `SMAppService` LaunchDaemon 与主应用执行同 Team 与精确签名标识双向校验。首次使用须在设置页或提示中显式启用（必要时经「系统设置 → 通用 → 登录项与扩展」批准）；Helper 空闲后自动退出，且应用原位重装或更新（`SHA256 + dev/ino` 指纹变化或 XPC `4102` 失配）时自动执行 `unregister` + 退避 `register` 回收旧守护进程并重绑新二进制。
- **v2 跨进程凭据核验**：使用私有授权规则 `com.macdefier.app.uninstall.trash.v2`（委托系统 `authenticate-admin-nonshared`，admin、30 秒有效期、非共享）；客户端前台实际获取授权后交由禁止 UI 的 helper 核验，连接断开即失效。
- **同卷私有暂存与恢复日志**：RPC 不接受调用方传入的 UID、home、废纸篓路径或任意命令；App 跨授权等待保持原对象文件描述符，helper 先写入恢复 journal，将目标原子移入同卷 root 私有 staging 目录复核身份后，再提交至调用用户的废纸篓（冲突或异常时保留现场并阻断后续关联清理）。
- **发布校验门禁**：正式发布包必须通过逐架构结构与签名门禁校验：
  ```bash
  scripts/validate-uninstall-helper.sh /Applications/MacDefier.app
  ```
  （`--structure-only` 仅限本地未签名编译自检，不可替代发布门禁。）
