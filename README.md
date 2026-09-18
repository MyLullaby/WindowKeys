# WindowKeys

[![Build](https://github.com/MyLullaby/WindowKeys/actions/workflows/build.yml/badge.svg)](https://github.com/MyLullaby/WindowKeys/actions/workflows/build.yml)

一个只包含五个窗口动作的原生 macOS 菜单栏工具，编译目标为 Apple Silicon（arm64）。

| 动作 | 全局快捷键 |
|---|---|
| 按自定义宽高比例调整并居中 | Control + Command + C |
| macOS 原生居中 | Control + Command + ↓ |
| macOS 原生填充 | Control + Command + ↑ |
| macOS 原生左半屏 | Control + Command + ← |
| macOS 原生右半屏 | Control + Command + → |

四个方向键只触发目标应用的 macOS 原生窗口菜单命令，动画、最终位置和尺寸、平铺边距、
台前调度行为全部由系统处理。不会主动展开应用菜单，也不会追加自定义尺寸补正。
这些原生命令需要 macOS 15 或更新系统且目标应用提供对应菜单；找不到、禁用或调用失败时
会发出提示音并记录日志，不再用自定义窗口调整兜底。系统接受命令后是否生效由系统处理。

只有 C 的“调整大小并居中”使用自定义实现：通过 AppKit `NSAnimation` 执行约 0.3 秒的
缓出动画，同时变化位置和大小。识别固定宽高和固定比例；窗口受最小尺寸限制时，动画中
保持原定移动轨迹，不逐帧重新居中。结束后按实际尺寸做一次位置校准，不再每隔 120 毫秒
重复修改大小，避免出现“动画结束后又分几段调整”。新动作或焦点变化会取消旧动画。
菜单栏中的“调整大小并居中动画”只控制 C；
关闭该选项或系统开启“减少动态效果”时，C 直接调整，原生命令仍遵循系统自己的动画设置。
实现参考了 [Loop 的窗口动画与尺寸限制处理](https://github.com/MrKai77/Loop/blob/df26d565e07c82e156b8f1c361bdcf428f32e3a4/Loop/Window%20Management/Window%20Manipulation/WindowTransformAnimation.swift)，
未引入其依赖。与 Loop 一样，目标应用开启增强辅助功能模式（`AXEnhancedUserInterface`）时
走无动画兼容路径：同步调整期间临时关闭该属性，结束时恢复并检查；直接调整最多连续尝试
两次，不做延时重试。该属性恢复失败会记录日志。
菜单栏中的“开机自动启动”使用 macOS 登录项机制，可随时开启或关闭；如果系统要求批准，
应用会引导到“系统设置 → 通用 → 登录项与扩展”。

## 按应用切换输入法

在菜单栏选择“应用输入法设置…”可以设置一个默认输入法，并为指定应用添加专属输入法。
切换应用时优先使用该应用的专属配置；没有专属配置时自动使用默认输入法。
首次运行会把当时正在使用的输入法保存为默认值，之后可以随时修改。

应用规则按 Bundle ID 匹配，因此移动或更新应用后仍然有效。删除某条专属配置后，
对应应用会重新使用默认输入法。如果配置的输入法已被停用或卸载，WindowKeys 会保持
当前输入法不变，并在设置窗口中将该输入法标记为不可用。
WindowKeys 只在当前输入法与目标配置不一致时模拟一次系统“选择上一个输入法”快捷键
（默认是 Control-Space），由 macOS 完成切换。请确保该快捷键已在系统键盘设置中启用；
此方式适合在 ABC 和一个非拉丁输入法之间切换。

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

## 窗口回归验证

打开待测窗口后运行（执行环境需要辅助功能权限）：

```sh
zsh Tests/run-window-commands.sh com.tencent.WeWorkMac '文档窗口标题'
```

只检查原生命令映射和几何计算、不操作窗口时，可运行：

```sh
zsh Tests/run-window-commands.sh --geometry-only
```

脚本调用当前源码的窗口控制器，检查原生命令映射、最小尺寸下的移动轨迹、固定宽高和
固定比例、自定义动画及结束后的稳定性、
最大化、退出平铺后的缩放、单次居中和动画中断。原生命令测试需要应用支持相应菜单。
系统原生平铺的边距可配置，用例会读取当前设置，而非要求固定 8 像素。
结束后恢复原窗口尺寸和位置。测试期间请勿切换窗口；前台变化会中止后续命令。
