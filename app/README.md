# MacDefier App（工程）

**Bundle：** `com.macdefier.app`  
**策略：** F′ 抽取 — 主窗自研 SwiftUI；MonitorKit ← Stats readers；CleanupKit ← PureMac（壳）

## 结构

```
app/
  MacDefier/          # SwiftUI 主 App（主应用）
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

- Debug 固定为 `MacDefier-Dev.app` / `com.macdefier.app.dev`；
  `scripts/install-dev-app.sh` 只安装 `/Applications/MacDefier-Dev.app`，
  不覆盖、不终止正式版。
- 未公证试用包只由 `scripts/package-dist.sh` 生成到 `dist/trial/`，文件名
  必须带 `-unsigned`。
- 正式无后缀包只由 `scripts/package-release.sh` 生成到 `dist/release/`；
  Developer ID、公证、staple、NOTICE 和 debug 产物检查全部成功后才输出，
  同版本已存在时拒绝静默覆盖。

正式签名打包需自行设置 `SIGN_ID`、`TEAM_ID` 和 `NOTARY_PROFILE`；参见 `scripts/package-release.sh`。
