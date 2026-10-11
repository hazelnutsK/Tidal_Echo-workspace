# Tidal Echo for iOS

这是 Tidal Echo 的第一版 SwiftUI 原生客户端。它复用现有 FastAPI relay，不修改 PWA、数据库或 AI 侧进程。

## 当前功能

- HTTPS relay + Bearer 密钥登录
- 密钥保存在 iOS Keychain
- 拉取并显示聊天记录
- SSE 实时消息、输入状态、流式回复预览
- 发送文字与图片
- ReplayKit 单帧屏幕共享（一次性本机票据，不依赖 App Group）
- 多图消息以可拖拽、快甩翻页的三层照片堆展示
- 内置颜文字抽屉，支持分类浏览、自定义添加与删除
- Thinking / Action 折叠卡片
- 雾绣、纸白、夜港三套原生主题
- GitHub Actions 编译模拟器版本和未签名 IPA

暂未包含原生推送、Moments 和日历。

## 服务地址

登录页填写 relay 根地址，例如：

```text
https://example.com/relay
```

如果只填写 `https://example.com`，客户端会自动补上 `/relay`。第一版只接受 HTTPS。

## 在 GitHub Actions 构建

仓库中的 `.github/workflows/ios-build.yml` 会：

1. 在 macOS runner 安装 XcodeGen。
2. 从 `ios/Assets/AppIconSource.png` 生成完整 iOS AppIcon。
3. 根据 `project.yml` 生成 Xcode 项目。
4. 编译 iOS Simulator 版本，尽早发现 SwiftUI 编译错误。
5. 编译未签名的真机 `.app`。
6. 打包成 `TidalEcho-unsigned.ipa` 并上传为 workflow artifact。

把代码推送到 GitHub 后，也可以从 Actions 页面手动运行 **iOS Build**。

## 使用 AltStore 安装

1. 下载 Actions 产物 `TidalEcho-unsigned-ipa`。
2. 解压得到 `TidalEcho-unsigned.ipa`。
3. 在 iPhone 的 AltStore 中选择 **My Apps → +**，选择 IPA。
4. 使用免费 Apple ID 时，在 7 天到期前让 AltStore 连接 Windows 上的 AltServer 刷新。

首次使用 iOS 16 或更高版本的侧载 App，需要在系统设置中开启开发者模式。

## 在 Mac 上打开（可选）

```bash
brew install xcodegen
cd ios
bash scripts/prepare-assets.sh
xcodegen generate
open TidalEcho.xcodeproj
```

项目文件由 XcodeGen 生成，不提交到 Git。

## ReplayKit 屏幕共享

设置页的“屏幕共享”会先向 relay 申请一张 3 分钟、只可用一次的临时票据，
同时在 `127.0.0.1:49271` 短暂开启仅限本机的一次性交接通道。点系统广播按钮并
选择 Tidal Echo 后，Upload Extension 会取走票据，主 App 随即关闭监听。它不需要
App Group、配置页或粘贴操作；扩展不会读取主 App 的 Keychain，也不会把长期
`RELAY_SECRET` 打进 IPA。

共享开始后会留 3 秒给你切到目标页面，只上传一张最长边 720 px 的 JPEG，
成功后立即结束广播。系统的红色录制标记和手动停止入口始终保留。

票据里带有每次新生成的随机探针。扩展上传截图时会把探针一同交回 relay；完全
一致后，设置页才显示绿色“验证通过”。因此仅仅开启本机监听不算通过，必须完成
一次共享看到绿色结果。

这个功能会让 IPA 内包含主 App 和 Upload Extension 两个 bundle。
免费 Personal Team / AltStore 签名时会占用 2 个 App ID，并跟主 App 一样需要
按免费签名的有效期刷新。这个流程不申请 App Groups capability；完成一次共享后
显示绿色，表示主 App、Upload Extension、本机交接和 relay 全链路都已实测可用。
