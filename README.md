# WindowKeys

[![Build](https://github.com/MyLullaby/WindowKeys/actions/workflows/build.yml/badge.svg)](https://github.com/MyLullaby/WindowKeys/actions/workflows/build.yml)

一个只包含五个窗口动作的原生 macOS 菜单栏工具，编译目标为 Apple Silicon（arm64）。

| 动作 | 全局快捷键 |
|---|---|
| 按自定义宽高比例调整并居中 | Control + Command + C |
| 居中（只写位置，保持当前大小） | Control + Command + ↓ |
| macOS 原生填充 | Control + Command + ↑ |
| macOS 原生左半屏 | Control + Command + ← |
| macOS 原生右半屏 | Control + Command + → |

上、左、右三个方向动作直接触发目标应用的 macOS 原生窗口菜单命令，因此保留系统动画、
平铺边距和台前调度行为。下键只写窗口位置，绝不写窗口大小；C 负责调整大小并居中。
菜单栏中的“自定义窗口动画”控制 C 和下键的动画。
菜单栏中的“开机自动启动”使用 macOS 登录项机制，可随时开启或关闭；如果系统要求批准，
应用会引导到“系统设置 → 通用 → 登录项与扩展”。

## 按应用切换输入法

在菜单栏选择“应用输入法设置…”可以设置一个默认输入法，并为指定应用添加专属输入法。
切换应用时优先使用该应用的专属配置；没有专属配置时自动使用默认输入法。
首次运行会把当时正在使用的输入法保存为默认值，之后可以随时修改。

应用规则按 Bundle ID 匹配，因此移动或更新应用后仍然有效。删除某条专属配置后，
对应应用会重新使用默认输入法。如果配置的输入法已被停用或卸载，WindowKeys 会保持
当前输入法不变，并在设置窗口中将该输入法标记为不可用。
对于中文、日文和韩文输入法，WindowKeys 还会在应用切换后刷新文本输入上下文，避免
菜单栏已经显示目标输入法、但当前应用仍无法使用该输入法的情况。

在菜单栏选择“C 窗口大小…”可以分别拖动宽度和高度滑块。两项均以当前屏幕的
可用区域为基准，可在 30%–100% 之间按 1% 调节，修改后自动保存。
应用使用公开的 macOS Accessibility API，
不会调用 AppleScript，也不会包含 Intel/Rosetta 代码。

## 构建

```sh
./build.sh
```

每次向 GitHub 推送提交以及创建或更新 Pull Request 时，GitHub Actions 都会自动构建并校验
Apple Silicon 版本。可以在仓库的 [Actions](https://github.com/MyLullaby/WindowKeys/actions/workflows/build.yml)
页面打开对应的构建记录，并在页面底部的 **Artifacts** 中下载 `WindowKeys-macos-arm64-<提交哈希>`。
也可以在 Actions 页面通过 **Run workflow** 手动触发构建。构建产物保留 30 天。

首次启动后，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 WindowKeys。
