# MacDefier

MacDefier 是一个用 SwiftUI 构建的开源 macOS 工具，用于诊断卡顿、查找垃圾、管理软件和 AI 工具，并查看系统资源。AI 顾问可选，清理和卸载不依赖 AI。

An open-source macOS utility for system diagnostics, cleanup, app and AI-tool management, and resource monitoring. Built with SwiftUI. AI assistance is optional.

**[下载安装包 · Download DMG](https://github.com/KunZhang1997/MacDefier/releases/download/v0.14/MacDefier-0.14.dmg)** · [从源码构建](#从源码构建)

## 功能

- **诊断**：查看系统负载与资源占用，提供问题线索。
- **清理**：扫描缓存、日志和其他可清理项目，先预览再确认，通常移入废纸篓。
- **软件管理**：查看应用、关联数据和 CLI 工具，预览卸载范围。
- **AI 工具管理**：查看本地 AI 工具、缓存和模型，按资源状态提供处理入口。
- **监控**：查看 CPU、内存、磁盘、网络、GPU 和传感器数据；可用信息因硬件及权限而异。
- **可选 AI 顾问**：连接自行配置的云端 API 或本地模型。
- **中英文界面**，支持自定义窗口宠物包。

项目持续开发中，支持直接下载安装包，也支持从源码构建。

## 安装包安装

**[下载 MacDefier 0.14 安装包（DMG）](https://github.com/KunZhang1997/MacDefier/releases/download/v0.14/MacDefier-0.14.dmg)** · [版本说明与校验文件](https://github.com/KunZhang1997/MacDefier/releases/latest)

需要 **macOS 14.0 或更新版本**，支持 **Apple Silicon 和 Intel Mac**。安装包已使用 Developer ID 签名并通过 Apple 公证，无需安装 Xcode 或其他开发工具。

1. 下载并打开 `MacDefier-0.14.dmg`。
2. 将 `MacDefier.app` 拖入 `Applications`（应用程序）。
3. 从「应用程序」打开 MacDefier，按需要授予相应权限。

清理部分受保护目录时，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中允许 MacDefier。AI 顾问为可选功能，可在设置中配置。

**English:** [Download the DMG](https://github.com/KunZhang1997/MacDefier/releases/download/v0.14/MacDefier-0.14.dmg), open it, drag `MacDefier.app` into `Applications`, and launch it from there. Requires macOS 14.0 or later; supports Apple Silicon and Intel. Developer ID signed and Apple notarized. No developer tools required.

## 从源码构建

需要 macOS 14.0 或更新版本、Xcode（本次验证使用 Xcode 27.1），以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
git clone https://github.com/KunZhang1997/MacDefier.git
cd MacDefier/app
./rebuild_and_launch.sh
```

脚本生成 Xcode 工程、构建 Release，并更新 `/Applications/MacDefier.app`。日常运行使用生产 Bundle ID `com.macdefier.app`，保留现有设置和 Keychain 命名空间。Debug 用于临时编译、调试；兼容入口 `install-dev-app.sh` 已转向同一个 Release 安装流程。

本地源码构建默认使用 ad-hoc 签名；正式分发通过 `app/scripts/package-release.sh`，由调用者提供 `SIGN_ID`、`TEAM_ID` 及公证配置。仓库只包含更新验签公钥。

源码可能先于安装包更新；安装包版本与说明以对应 GitHub Release 为准。

## 检查

在仓库根目录执行现有测试和 Debug / Release 构建：

```bash
bash app/scripts/ci.sh
```

测试和构建使用隔离缓存目录。完整脚本会运行 CleanupKit、PetArchiveKit、MonitorKit 单元测试，AI 端点及传输检查、诊断与磁盘布局检查，再构建 Debug 和 Release。

卸载助手、更新器和构建生命周期还提供独立检查入口：`app/UninstallHelperKit` 的 `swift test`、`app/scripts/test-update-feed.sh`、`test-app-update-state.sh`、`test-app-update-controller.sh` 和 `bash app/rebuild_and_launch.sh --self-test`。

## 数据与权限

扫描和清理在本机执行。配置云端 AI 后，相关请求内容会发送给你选择的服务；局域网模型请求会发送至配置的设备。监控页的公网 IP 查询会连接第三方服务，可在设置中关闭。API Key 存储于 macOS Keychain。

部分目录需要 macOS 的相应访问权限。执行清理或卸载前应检查预览；默认移入废纸篓并不适用于所有操作，详情以确认页为准。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `app/MacDefier/` | SwiftUI 应用、诊断、AI 和界面资源 |
| `app/CleanupKit/` | 扫描、清理、卸载及保护规则 |
| `app/MonitorKit/` | 系统资源采样 |
| `app/PetArchiveKit/` | 宠物包导入与校验 |
| `app/UninstallHelperKit/` | 卸载助手协议、权限边界、客户端与测试 |
| `app/UninstallHelper/` | 按需授权的卸载助手入口 |
| `app/Vendor/ZIPFoundation/` | 固定版本的 ZIPFoundation 依赖 |
| `app/scripts/` | 测试、构建与打包脚本 |

## 许可证与致谢

MacDefier 源码使用 [MIT License](LICENSE)。允许使用、修改、分发及商业使用，分发时须保留许可证及版权声明。

第三方组件保留各自许可证和署名，详见 [app/NOTICE](app/NOTICE)：[Stats](https://github.com/exelban/stats)、[PureMac](https://github.com/momenbasel/PureMac)、[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)、[Sparkle](https://github.com/sparkle-project/Sparkle) 使用 MIT；示例宠物素材 [The Robot - Free Sprite](https://opengameart.org/content/the-robot-free-sprite) 使用 CC0。

欢迎通过 [Issues](https://github.com/KunZhang1997/MacDefier/issues) 报告问题，或提交 Pull Request。报告问题时请删除日志中的 API Key 和个人路径等私密信息。
