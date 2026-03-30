# WinTop 📌

[English](./README.md) | 中文文档


一个轻量级 macOS 工具，让任意窗口始终保持视觉置顶——且不会抢占焦点。

## 工作原理

WinTop 使用 **ScreenCaptureKit** 为目标窗口创建一个浮动镜像。镜像面板以 floating 层级悬浮在所有窗口之上，而真实窗口仍保持在原本的 z 轴位置。原窗口完整保留焦点、键盘输入和交互能力——WinTop 的覆盖层会将所有鼠标事件透传给真实窗口。

```
┌─────────────────────────────────┐
│  WinTop 镜像面板 (.floating)     │  ← 始终可见，置于顶层
│  [SCStream 实时渲染]             │  ← ignoresMouseEvents = true
└─────────────────────────────────┘
         ↕ 透传所有鼠标/键盘事件
┌─────────────────────────────────┐
│  真实窗口（正常 z 轴顺序）        │  ← 仍可完整交互
└─────────────────────────────────┘
```

## 功能

- **⌥ + P** — 置顶当前最前台窗口
- **⌥ + U** — 取消最近置顶的窗口
- 支持同时 **置顶多个窗口**
- 镜像随窗口移动和调整大小自动跟随
- 不抢焦点——打字绝不被打断
- 菜单栏图标，支持退出

## 系统要求

| 项目 | 要求 |
|---|---|
| macOS | **macOS 14 Sonoma 及以上**（ScreenCaptureKit 的 `SCContentFilter(desktopIndependentWindow:)` 最低需要 macOS 14） |
| 处理器架构 | Apple Silicon 和 Intel 均支持 |
| 系统权限 | **辅助功能（Accessibility）** + **屏幕录制（Screen Recording）**，两者均需授权 |
| Swift | Swift 5.9+（Xcode 15+）或命令行工具 |

> 已在 macOS 15 Sequoia 和 macOS 26 Tahoe 上测试。

## 安装

### 从源码构建（推荐）

```bash
git clone https://github.com/YOUR_USERNAME/WinTop.git
cd WinTop
chmod +x build.sh
./build.sh
```

`build.sh` 会编译 Swift 源码、以 ad-hoc 签名对 app 签名并启动 WinTop。启动后菜单栏会出现 📌 图标。

首次启动时，macOS 会请求：
1. **辅助功能权限** — 用于识别当前最前台窗口
2. **屏幕录制权限** — ScreenCaptureKit 捕获窗口内容所需

请在 **系统设置 → 隐私与安全性** 中分别授权。

> **注意：** 修改源码后重新运行 `./build.sh` 即可。脚本仅在 `wintop.swift` 比二进制文件新时才重新编译，并会重新签名以避免重复授权弹窗。

## 使用方法

1. 启动 `WinTop.app`（或运行 `./build.sh`）
2. 点击你想置顶的窗口，使其成为前台窗口
3. 按 **⌥ + P**（Option + P）— 浮动镜像出现
4. 切换到其他应用——镜像始终保持可见在最前方
5. 按 **⌥ + U**（Option + U）取消置顶（多个置顶窗口时依次取消）

## 已知限制

| 限制 | 原因 |
|---|---|
| 拖动时约 1 帧重影 | 镜像通过 SCStream 捕获管道渲染，非直接合成；属于方案固有延迟 |
| 需要屏幕录制权限 | macOS 14+ 上 ScreenCaptureKit 的 TCC 要求 |
| 镜像为只读 | 浮动窗口是实时视觉副本，非真正的窗口代理 |
| 无最小化/最大化控件 | 设计如此——镜像是无边框覆盖层 |

## 架构说明

```
wintop.swift
├── CaptureManager      — SCStream 配置、帧传递、动态分辨率更新
├── MirrorPanel         — NSPanel 覆盖层、AXObserver 位置同步、图层结构
├── WinTopManager       — 管理活跃镜像数组，处理 pin/unpin 逻辑
└── AppDelegate         — 菜单栏、Carbon 快捷键注册、TCC 权限请求
```

**关键设计决策：**
- `SCContentFilter(desktopIndependentWindow:)` — 只捕获单个窗口，不捕获整个屏幕
- `AVSampleBufferDisplayLayer` + 静态兜底 `CALayer` — 防止合成时黑色闪烁
- `AXObserver`（`kAXWindowMovedNotification` / `kAXWindowResizedNotification`）— 事件驱动的位置同步，窗口静止时零轮询开销
- `panel.ignoresMouseEvents = true` — 所有输入透传给真实窗口
- `panel.level = .floating` + `.nonactivatingPanel` — 保持在普通窗口上方，不参与焦点管理

## 参考项目

- [Topit](https://github.com/lihaoyun6/Topit) — ScreenCaptureKit 镜像方案
- [AlwaysOnTop](https://github.com/AirBalloonDev/AlwaysOnTop) — 快捷键与窗口管理模式

## 开源协议

MIT
