# 公开 iOS 编译，私人仓库开发

从 2026-10-15 起采用以下流程：

1. 修改代码后，检查、提交并推送到私人仓库 hazelnutsK/Tidal_Echo-workspace。
2. 需要打包时，明确选定已推送的源码提交。以最新完成的功能分支为基础，核对最近成功编译的提交，不用旧运行目录的 iOS。
3. 导出这个提交的 ios/、现有 LICENSE 和手动编译工作流，发布到公开仓库 hazelnutsK/Tidal_Echo 的 ios-build 分支。
4. 手动运行公开仓库的 iOS Build，选择 ios-build；检查构建结果，下载 TidalEcho-unsigned-ipa 产物。

小雪只需说“把这个版本同步到公开仓库并编译”。助手完成步骤 2–4。
说“先别编译”时仍推送私人源码，构建保持未触发。

## 导出命令

在包含此脚本的私人仓库任务分支中运行。先预览：

    python3 tools/export_public_ios.py --ref <已提交的源码版本>

只发布源码：

    python3 tools/export_public_ios.py --ref <已推送的源码版本> --publish

发布后编译：

    python3 tools/export_public_ios.py --ref <已推送的源码版本> --publish --build

只做原生界面验收，不打 IPA：

    python3 tools/export_public_ios.py --ref <已推送的源码版本> --publish --build --review-only

Windows 可使用已配置的 Python 路径，代替 python3。
脚本默认不访问 GitHub，只导出到临时目录并检查。
发布和编译使用当前电脑的 GitHub 凭据，或 GH_TOKEN/GITHUB_TOKEN 环境变量。
凭据仅在内存/子进程环境中使用，不写进仓库、Git URL 或导出文件。
VPS 的 deploy key 只授权私人仓库：VPS CC 改完并推送私人分支后，
由有公开仓库权限的电脑执行发布/编译即可。

## 公开内容和版本对应

公开分支只包含 iOS 源码、资源、测试、手动工作流、LICENSE、
简短 README 和 source-manifest.json。后端、网页、对话、附件、
实际人设及私人 Git 历史不会进入这条分支。

首次发布创建独立的 Git 历史；以后按普通快进更新，绝不 force push。
原公开仓库的 main 和 ios-space-redesign 分支保留。
source-manifest.json 记录私人源提交、完整 iOS tree 和每个文件的 SHA-256。
导出后的 iOS tree 必须与指定源提交完全一致，否则拒绝发布。
导出拒绝已跟踪的运行数据、数据库、密钥和常见凭据格式，并与本机已知应用密钥比对。

当前工作流只有 workflow_dispatch。发布源码本身不会编译。
公开工作流无需拉取私人仓库，构建的是已经公开的源码。
原生构建仍需 macOS/Xcode；本地离线检查不等于完成 iOS 编译。

## 手动网页操作

打开 https://github.com/hazelnutsK/Tidal_Echo/actions/workflows/ios-build.yml
点击 Run workflow，分支选择 ios-build，然后再次点击 Run workflow。
构建成功后在该次运行页面的 Artifacts 中下载 TidalEcho-unsigned-ipa。

公开和私人仓库的标准 runner 计费不同；公开构建用于公开的 iOS 源码。
不要在公开构建步骤或日志里添加私人配置、账号令牌或真实聊天数据。

## 检查导出工具

    python3 -m unittest discover -s tools -p test_export_public_ios.py

