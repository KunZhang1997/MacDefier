# MacDefier App（工程）

**Bundle：** `com.macdefier.app`  
**策略：** F′ 抽取 — 主窗自研 SwiftUI；MonitorKit ← Stats readers；CleanupKit ← PureMac（壳）

## 结构

```
app/
  MacDefier/          # SwiftUI 主 App（侧栏 IA 对齐线框）
  MonitorKit/         # 采样库（CPU/RAM/Disk/Net/GPU 列表…）
  CleanupKit/         # 清理壳（B2 抽 PureMac）
  project.yml         # xcodegen
  NOTICE              # MIT 署名 Stats / PureMac
  MacDefier.xcodeproj # xcodegen 生成
```

## 生成 / 编译

```bash
cd "…/MacDefier/app"
xcodegen generate
xcodebuild -scheme MacDefier -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
open MacDefier.xcodeproj
```

## 页面（跟新前端，不跟 Stats 设置窗）

侧栏：诊断 / 清理 / 软件 / AI / 监控 / 设置  
监控横排：Dashboard | CPU | GPU | RAM | Disk | Sensors | Network

## 不做进产品壳

- 在 `vendor/stats` 改品牌发版  
- Bundle `eu.exelban.*`  
- 菜单栏 Stats 整壳 / Remote / 风扇控制  

## 构建身份与分发真源

- 日常源码构建使用 `./rebuild_and_launch.sh`，构建 Release 并原位更新唯一安装 `/Applications/MacDefier.app`，Bundle ID 为 `com.macdefier.app`。
- Debug 仅作临时编译、调试，不并列安装 Dev 版本；`scripts/install-dev-app.sh` 为兼容入口，现转向同一个 Release 安装流程。
- `scripts/single_app_build.py` 为构建、打包、安装和临时应用清理提供公共生命周期；自检用 `./rebuild_and_launch.sh --self-test`。
- 未公证试用包只由 `scripts/package-dist.sh` 生成到 `dist/trial/`，文件名
  必须带 `-unsigned`。
- 正式无后缀包只由 `scripts/package-release.sh` 生成到 `dist/release/`；
  Developer ID、公证、staple、NOTICE 和 debug 产物检查全部成功后才输出，
  同版本已存在时拒绝静默覆盖。

## 顶栏一键更新

所有页面共用一个按需出现的右上角下载图标。启动主窗或 App 重新回到前台时静默读取更新清单；确认有可安装的新版才显示图标。最新版、尚未确认、静默检测中、检测失败及无可用更新均隐藏整块入口，不显示「已是最新版」。点击后在原位显示下载进度，完成后安装并重启；没有检查更新弹窗或浏览器跳转。正在清理、移到废纸篓或卸载时，安装会等待当前操作完成。连接、下载和等待阶段可取消，安装阶段不强制终止。Debug 不检测或显示正式版更新入口，不覆盖不同 Bundle ID 的正式版。

更新由 Sparkle 2.9.4 验证签名。更新源固定为：
`https://github.com/KunZhang1997/MacDefier/releases/latest/download/appcast.xml`。
仅由启动与前台激活触发元数据检测，不进行后台定时轮询；成功后至少间隔 15 分钟，失败后至少间隔 1 分钟才允许下次激活重试。检测使用 Sparkle 的 `checkForUpdateInformation`，本身不下载、安装、显示窗口或发送系统信息。实际下载仍须点击图标。

发布要求：

1. 首次需要发布并安装一个包含更新器的新正式版；此前的安装包无法凭空获得此入口。
2. 每次递增包内实际版本，继续使用 `com.macdefier.app` 和同一签名身份；不能只改安装包文件名或 GitHub 标签。2026-10-23 只读核对的 GitHub `0.15` 安装包内仍是 `0.14`，不能拿它作为新版本更新包。
3. 运行 `scripts/package-release.sh VERSION`，将输出的原始 `MacDefier-VERSION.dmg` 与 `appcast.xml` 一起上传到同一个 GitHub 正式 Release，并让它成为 latest；不可上传后再修改签名清单或安装包。默认标签为 `vVERSION`，若标签不带 v，打包时设置 `MACDEFIER_RELEASE_TAG=VERSION`。

EdDSA 私钥留在登录钥匙串账户 `com.macdefier.app.sparkle`，仓库只有公钥。打包脚本会在构建前核对公钥，在签名、公证、staple 后对最终安装包生成更新清单并验签；不自动发布。新构建环境先解析项目依赖，或用 `MACDEFIER_SPARKLE_TOOLS_DIR` 指向固定版本 Sparkle 的 bin 目录。私钥迁移应走钥匙串的受控备份，不能提交到源码或 Release。

可独立验证：

```bash
bash scripts/test-app-update-state.sh
bash scripts/test-app-update-controller.sh
bash scripts/test-update-feed.sh
scripts/generate-update-feed.sh --check-signing
```

前三项使用隔离样本或注入回调；不代表线上下载、安装和重启已验收。最后一项只读核对本机签名账户。

## 卸载权限与失败结果

- 普通移动先核对选中对象身份；仅主程序位于 `/Applications` 一层、且原子移动本身因 EACCES/EPERM 失败时，进入新的受限卸载助手。读取或废纸篓访问错误不会自动当成管理员权限问题。完全磁盘访问不会授予文件拥有者或管理员权限。
- 只处理用户确认的目标，不执行提权 shell、不更改目标权限、不永久删除。npm/Homebrew/uv 仍通过原包管理器以当前用户运行，失败时显示安装权限、依赖或命令错误，不将包管理器脚本提权。
- 主程序未确认移走时保留关联数据；取消、恢复冲突、提交后位置不明或回执中断均停止后续项，不自动重试。原路径重新出现应用时，不继续清关联数据。
- 已知锁定、只读卷、跨卷、安全边界或身份变化不通过管理员授权绕过。符号链接仅走原有普通用户边界，不交给 Finder 提权跟随。
- 2026-10-23 空样本实测否决了 Finder Apple Events 自动授权方案：发送原生 file-reference URL，等待管理员确认时将原对象改名并在原路径放置另一空对象；确认后原对象仍在，替换对象消失，Finder 却回报成功。事后身份验证能发现异常，不能撤销错误处理，因此已移除该桥接及自动化 entitlement。此原型未安装或外发。

定向回归（以下测试使用隔离样本或注入回调，不调用真实卸载）：

```bash
swift test --package-path CleanupKit --jobs 2 --filter 'UninstallBoundaryErrorTests|UninstallSystemTrashTests|UninstallCommandFailureTests|CliUninstallAuthorizationFlowTests|UninstallBoundaryTests|CliManualEntryTests'
```

### 受限助手实现（2026-10-23，实机启用待验收）

- `UninstallHelperKit` 分离 Core、IPC、Client。SMAppService daemon 位于应用包内；Release/Dev 使用不同 Mach 服务和授权 right，同 Team 且精确签名标识双向校验。先完成不带敏感数据的握手，再发送短期授权凭证；连接中断即永久失效，不自动重连重发。
- 第一次使用需明确启用助手，并可能在系统设置批准后台项目。之后由 macOS 请求管理员授权，系统可能复用授权，不承诺每次弹密码。设置页可查看、启用或停用。未签名/ad-hoc 构建拒绝启用。
- RPC 不接受 UID、home、目标废纸篓或任意命令。调用用户来自 XPC，home 来自系统账户数据库；只处理其确认过的 `/Applications/<name>.app`，拒绝系统应用、MacDefier、符号链接、嵌套路径和 CLI。
- App 保留原对象 FD 跨越授权等待；helper 将项目原子移入同卷、root 私有且拒绝额外 allow ACL 的 staging，核对实际对象后才提交调用用户的废纸篓。身份不匹配时禁止提交；还原使用不覆盖的 rename，冲突时保留对象和恢复位置。不能保证错误对象从未被短暂暂存，也不能保证冲突时自动恢复。
- 第一次移动前写入并同步恢复 journal；记录 request UUID、原对象/父目录/废纸篓身份。已有 UUID 不重放。最终提交后再次核对目录绑定、目标对象与源路径；位置或持久化无法确认时返回 `committedUnknown`，不盲目回滚已提交对象、不报正常成功、不继续清关联数据。
- journal/staging 只在真实服务运行时创建于 `/Library/Application Support/<service>/staging/`。本轮未注册服务、未写系统授权数据库、未移动真实应用。发生 retainedStaging 时需依据界面路径进行管理员恢复；目前没有自动恢复 RPC。直接 POSIX 移入废纸篓不承诺 Finder 的“放回原处”元数据。
- 正式包必须执行 `scripts/validate-uninstall-helper.sh APP_PATH`，逐架构校验 plist 映射、helper/main 架构、签名、Team、runtime 和危险 entitlement。`--structure-only` 只适用于未签名构建，不算发布门禁。尚未完成公证、安装及系统授权正向验收；更新已注册助手时需先停用再重新启用，实际升级流程仍待验证。

验证：Core 18 项、IPC 9 项、原卸载链路 72 项、错误提示解析 36 项通过；测试全部使用隔离样本。Core 包含授权等待替换、最终 Trash 改名窗口、还原冲突、FIFO、ACL 和中断记录。运行核心测试：

```bash
swift test --package-path UninstallHelperKit --jobs 2
```

界面采用 standard 原生风格；新增助手设置静态审查无告警，旧卸载窗口没有 high 告警但仍有 28 项字体/固定尺寸等 medium 提示。本轮只加授权状态、错误文案和工作中禁止关闭，未重构旧布局。原生键盘/VoiceOver、缩放、明暗/高对比以及真实系统授权交互未验收；没有自定义动画，未采集 Instruments。暂评 74/100（平台12、布局11、语义13、交互13、动效12、无障碍5、实现8），不表示通过发布验收。
