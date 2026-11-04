> **状态**：现行　**主题**：DSHTouchBar　**更新**：2026-11-04

# DSHTouchBar

在 MacBook Pro 的 **Touch Bar** 上实时显示 [DeepSeek Harness](https://github.com/) 里正在工作的 Bot，
点击头像即可切换到对应 Bot 的会话。空闲时显示 Q 版鲸鱼娘。

> 利用 macOS 私有 API（`DFRFoundation` / `NSTouchBarItem.addSystemTrayItem`）在 Control Strip 常驻显示，
> **不独占系统 Touch Bar**、不抢系统控件。

## 功能

- **常态**（Control Strip）：全部空闲显示鲸鱼娘；有 Bot 工作时显示**最活跃的一个**（带头像动画）
- **点开**：展开整条 Touch Bar，显示**全部 Bot**（最多横向滚动），活跃的自动置顶并带动画
- **矢量表情动画**：每个头像实时自绘，连续眨眼 + 注视微动；工作=普通眼，空闲=笑眼 ^_^
- **交互**：点头像切会话（缩放反馈）、长按看名字、滑动浏览、✕ 收起
- **生命周期**：只在 DSH 开启时显示（插件管理），App 挂了自动重拉，无 Touch Bar 硬件自动退出
- **性能**：活跃 30fps / 空闲 10fps 分级重绘，CPU 约 1-2%

## 截图

> (欢迎 PR 补充截图)

## 架构

```
┌─────────────────┐   spawn/watch    ┌──────────────────┐
│  DSH 插件(host) │ ───────────────► │ 原生 App (Swift) │
│  ds-touchbar    │                  │  DSHTouchBar.app │
│                 │   poll click     │                  │
│  插件(client)   │ ◄─────────────── │  读数据/画 Touch │
│  openSession ◄──┼── ~/.dsh/touchbar-click.json ◄──────┤  Bar/捕获点击
└─────────────────┘                  └──────────────────┘
                                  数据脚本: dsh-active-bots-json.sh
                                  读 ~/.dsh/bot/inflight.json + state.json
```

- **原生 App**（Swift，arm64）：读数据脚本，用私有 API 画 Control Strip item；点头像写 click 文件
- **DSH 插件**（Cordis 插件）：
  - host 端：拉起/看护 App，注册 `GET /api/ds-touchbar/poll`
  - client 端：轮询 click 文件 → `ctx.uiWorkspace.openSession(id)` 切会话
- **数据脚本**：读 DSH 的 `inflight.json`（活动 Bot）+ `state.json`（Bot 元数据），输出 JSON。头像的 shape/color 按 DSH 前端算法（bot.id + FNV-1a）派生，与界面一致

## 安装

要求：macOS（带 Touch Bar 的 MacBook Pro）、Xcode 命令行工具、Node.js（DSH 自带环境亦可）。

```bash
git clone <this-repo>
cd dsh-touchbar
./install.sh          # 构建 App + 安装插件 + 注册到 DSH profile
# 重启 DSH 生效
```

手动安装：见 `install.sh` 内各步骤（数据脚本 → `~/bin`、App → `~/.dsh/ds-touchbar/`、插件 → `~/.dsh/local-plugins/ds-touchbar/`）。

## 构建

```bash
./build.sh            # swiftc 编译 + ad-hoc 签名 → DSHTouchBar.app
pkill -x DSHTouchBar  # 插件 5 秒内自动重拉
```

## 目录结构

```
├── Sources/                 原生 App 源码
│   ├── main.swift           主逻辑(配置/API/图像/数据/交互/渲染/控制器/入口)
│   ├── BotAvatarView.swift  矢量自绘头像(眨眼/注视/笑眼/节流)
│   ├── Characters.swift     ds-bot 20 个角色 SVG path
│   ├── Eyes.swift           角色眼睛数据
│   ├── WhaleGirl.swift      空闲态鲸鱼娘头像(base64)
│   └── TouchBarPrivateApi.h DFRFoundation 私有 API 声明
├── Resources/               提取的中间数据
├── plugin/                  DSH 插件(host + client)
├── scripts/                 数据脚本
├── build.sh / install.sh
└── README.md / LICENSE
```

## 配置

`~/.dsh/touchbar-config.json`（可选，存在即生效，无需重编译）：

```json
{
  "refreshInterval": 2.0,
  "layoutYOffset": -1
}
```

## 致谢 / Attribution

- **鲸鱼娘形象**：`Sources/WhaleGirl.swift` 中的 Q 版鲸鱼娘来自
  [deepseek-whale-girl-gallery](https://github.com/Iphsiibl/deepseek-whale-girl-gallery)，
  以 **CC BY-NC-SA 4.0** 授权（署名-非商业性使用-相同方式共享）。
  原始角色：上善无形「溟月」→ ZipZipPipe「女仆装鲸鱼娘」。
- **角色矢量图形 / 头像派生算法**：参考 [DS-Bot](https://github.com/Fei2411/DS-Bot)（Apache-2.0）。
- **Touch Bar 私有 API 用法**：参考 [MTMR](https://github.com/Toxblh/MTMR)（MIT）。

## License

代码以 **MIT** 许可（见 `LICENSE`）。
鲸鱼娘图片资源除外：以 **CC BY-NC-SA 4.0** 授权，**禁止商业用途**，须署名、衍生同协议共享。
如需商用，请移除 `Sources/WhaleGirl.swift` 的图片或替换为自有素材。

## 已知限制

- 依赖 macOS 私有 API，系统大版本升级后可能需适配。
- 「活跃置顶」依赖 DSH 的 inflight 实时数据，点开瞬间若为空会短暂全 idle（1.5s 内自动纠正）。
- 仅在有 Touch Bar 的机型生效。
