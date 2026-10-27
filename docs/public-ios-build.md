# 直接在开发仓库编译 iOS

2026-10-15，小雪明确同意将 hazelnutsK/Tidal_Echo-workspace 改为公开。
现在日常开发、源码提交和 iOS 编译都用这一个仓库，不需要再导出到另一个仓库。

## 日常流程

1. 改代码后跑相关检查，提交并推送任务分支。
2. 小雪要求打包时，核对该分支的源码和最近成功构建的提交。
3. 在当前仓库手动运行 iOS Build，选择这条任务分支。
4. 检查构建结果，在运行页面的 Artifacts 下载 TidalEcho-unsigned-ipa。

说“先别编译”时仍推送源码，但不触发构建。
工作流只有 workflow_dispatch；推送源码和本次更改仓库可见性不会自动打包。
真实密钥、聊天数据、记忆正文、实际人设和附件仍不入 Git。

## 在网页上编译

打开 https://github.com/hazelnutsK/Tidal_Echo-workspace/actions/workflows/ios-build.yml
点击 Run workflow，选需要打包的分支，然后再次点击 Run workflow。
想只做原生界面验收时可勾选 native_review_only；要 IPA 时保持默认 false。

## 使用 GitHub CLI

    gh workflow run ios-build.yml -R hazelnutsK/Tidal_Echo-workspace --ref cc/your-task

手动编译需要有 Actions 写入权限的 GitHub 账号。
VPS 的现有 deploy key 继续负责源码拉取/推送；它不是 Actions 调度凭据。
可以让 VPS CC 完成源码修改和推送，再让小克送编译，或自己在网页上点运行。

## 旧导出流程

原公开仓库 hazelnutsK/Tidal_Echo 的分支与历史继续保留。
其中 ios-build 是此前发布的 iOS 源码快照。
tools/export_public_ios.py 保留为可选工具，但正常编译已不需要 --publish 或跨仓库同步。

公开仓库使用标准 GitHub 托管 runner 的运行分钟免费；iOS Build 仍使用 macos-26。
原生构建需要 macOS/Xcode，普通 Windows 离线检查不等于完成 iOS 编译。
