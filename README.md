# 本地音频播放器

用于 macOS 的极简本地音频播放器，无账号或联网播放功能。应用包含所需解码工具，使用时无需安装其他软件。

## 项目预览

实际 macOS 应用界面：左侧播放控制，右侧播放列表，支持多种本地音频格式与自动连播。

![本地音频播放器主界面](assets/project-preview.png)

<details>
<summary>查看播放设置：自定义前进、后退秒数和长按倍速</summary>

![本地音频播放器播放设置](assets/playback-settings-preview.png)

</details>

截图使用生成的示例音频文件，展示当前应用的实际运行效果。

## 使用

界面采用左侧正在播放、右侧播放列表的双栏布局。点击右下角“播放设置”可调整跳转秒数和长按倍速。

从 [Releases 下载最新版本](https://github.com/xc66xc/local-audio-player/releases/latest) 中的 `LocalAudioPlayer-v版本号-macOS-arm64.zip`，解压后打开“本地音频播放器.app”。当前提供 Apple Silicon 版，未接入 Developer ID 签名或 Apple 公证，其他 Mac 从网络下载后可能被 Gatekeeper 阻止打开，详见对应 Release 说明。

从源码构建后，应用位于 `dist/本地音频播放器.app`。

1. 点击“添加音频”（或 Command-O），选择一个或多个本地音频文件。
2. 点击“播放”播放第一首；双击列表中的其他文件可切换播放。
3. 空格播放/暂停；← 后退，→ 短按快进（松开时跳转），前进/后退秒数可分别输入设置，范围 1–600 秒，默认各 5 秒。
4. 播放时按住 → 约 0.35 秒进入所选倍速（1.25×、1.5×、1.75× 或 2×），松开或切换窗口恢复正常速度，不额外快进。暂停时长按不会开始播放；设置仅在本次运行生效。
5. 勾选“自动连播”后，当前音频正常播完会播放下一首；未勾选则停止。最后一首播完停止，不循环。
6. 垃圾桶按钮只从列表移除所选项，不删除磁盘上的文件。

支持 MP3（CBR/VBR）、M4A（AAC/ALAC）、AAC/ADTS、WAV（PCM/浮点）、FLAC、AIFF/AIF、OGG（Vorbis/Opus）、Opus，并支持未加密的 M4B 和 CAF（PCM）。相同扩展名可以包含不同编码；损坏文件、不支持的编码及 DRM 加密内容会提示无法播放，APE、WMA、DSD 暂不在支持范围内。

OGG/Opus 使用内置的 FFmpeg 精简工具进行本地流式解码，其余使用系统播放器。流式路径保持少量 PCM 缓冲，不生成整首解码缓存；支持相同的跳转、临时倍速和自动连播。列表时长取自实际文件。

默认不自动连播。关闭窗口停止播放并退出；列表和进度不跨次启动保存。手动快进到结尾不会自动切歌。

## 构建与测试

需要 macOS、Swift 5.9 或更新版本的编译工具，以及系统的 make、curl、tar。首次构建会下载并校验固定版本的 FFmpeg 源码，编译仅含 Ogg 解码与 PCM 输出的本地工具，后续复用 `.build/decoder`；不包含网络协议。测试另需含 libvorbis、libopus、libmp3lame 编码器的 `ffmpeg` 来生成合成样本；它不是应用的运行依赖。新版 Homebrew 的基础 ffmpeg 不含 libvorbis，可安装 `brew install ffmpeg-full`，然后用 `PATH="$(brew --prefix ffmpeg-full)/bin:$PATH" bash test.sh` 运行测试。

```sh
bash build-app.sh
bash test.sh
```

脚本生成适用于当前编译机器架构的 `.app`，使用本机临时签名，不含开发者签名和公证。当前构建为 Apple Silicon 版本。部署目标为 macOS 13，旧系统兼容性需要在对应系统另行验证。

自动测试生成合成音频，覆盖 AAC/ALAC、MP3 CBR/VBR、AAC ADTS、24 位/浮点 WAV、FLAC、AIFF、M4B、CAF、Vorbis/Opus，以及跳转、暂停、倍速、正常结束与自动连播、损坏文件、过期回调和键盘事件。不会读取用户音频文件。

## 贡献与许可

主分支为 `main`。改动在短期功能分支开发并提交 commit，通过 PR 审查后合入。外部开发者可以 Fork 后提 PR，具体见 [贡献指南](CONTRIBUTING.md)。

本项目采用 [MIT 许可证](LICENSE)。构建产物和测试音频不提交到 Git；应用分发使用 GitHub Releases。

应用随附独立的 [FFmpeg](https://ffmpeg.org/) 8.1.2 精简工具，采用 LGPL 2.1 或更新许可，不启用 GPL/nonfree 组件。许可证位于应用 `Contents/Resources/FFmpeg-LICENSE.txt`；对应未修改源码 `ffmpeg-8.1.2.tar.xz` 随 [Releases](https://github.com/xc66xc/local-audio-player/releases/latest) 提供，完整构建选项和校验值见 [build-decoder.sh](build-decoder.sh)。应用自身源码继续采用 MIT。

## 发布

`VERSION` 是唯一版本来源：修复增加修订号（1.0.1），兼容功能增加次版本（1.1.0），不兼容变化增加主版本（2.0.0）。只改文档或开发配置时不单独发版。

更新版本号通过 PR 合入 main，等待 CI 成功后，在干净且已同步的 main 上执行：

```sh
git switch main
git pull --ff-only
VERSION="$(cat VERSION)"
git tag -a "v$VERSION" -m "Release v$VERSION"
git push origin "v$VERSION"
```

Tag 必须是递增的新版本。推送后 GitHub Actions 自动验证主分支来源、运行测试、打包并发布 ZIP 与校验文件，发布说明根据 PR 自动生成。已发布的 Tag 禁止修改或删除。

本地打包和校验使用 `bash build-app.sh --package`，无需额外发布辅助脚本。

## ☕ 赞赏支持

| 支付宝 | 微信支付 |
| :---: | :---: |
| <img src="assets/alipay.png" alt="支付宝赞赏二维码" width="240"> | <img src="assets/wechat-pay.png" alt="微信支付赞赏二维码" width="240"> |

> 本项目免费开源。如果它对你有帮助，欢迎自愿赞赏，支持后续维护。不论赞赏与否，都感谢你的支持与使用！
