# GitHub 协作流程

## 当前采用的分支模型

`main` 是稳定主分支，功能、修复与文档修改各建一个短期分支，通过 PR 合入。当前不需要长期 `develop`；只有同时维护多个正式版本时再增加 `release/X.Y`。

```text
main ────────────────●─────────●
       \            / \       /
        feat/功能 ──   fix/修复
```

## 每次更新怎么做

先保证当前工作区的改动已妥善处理，再同步主分支：

```sh
git switch main
git pull --ff-only
git switch -c fix/player-controls
```

完成修改后先测试。以下以修改 `PlayerView.swift` 为例，只暂存本次实际修改的文件：

```sh
bash test.sh
bash build-app.sh
git add Sources/LocalAudioPlayer/PlayerView.swift
git commit -m "fix: 修复播放器控件交互"
git push -u origin HEAD
gh pr create --base main --fill
```

代码可以按完整意图分成多个 commit，不需要一个 PR 只有一个 commit。检查通过并审查后，在 GitHub 选择 Squash and merge；仓库主分支最终保留一个表达完整变化的提交。合并后回到本地 `main`，再次 `git pull --ff-only`，再开始下一项改动。

commit 是本地版本记录，push 才是上传，PR 是请求审查与合并，Release 是向用户发布安装包。它们分别执行、分别报告状态。

## 外部开发者提 PR

贡献者 Fork 公开仓库 → 从上游最新 `main` 建立自己的功能分支 → 修改、验证、commit、push 到自己的 Fork → 向本仓库 `main` 提 PR → 维护者审查及 CI 通过 → 维护者合并。

陌生开发者不需要本仓库写权限；能提出 PR 不代表能自行合并。较大的功能先用 Issue 对齐范围。CI 成功只是必要检查，是否符合项目方向仍由维护者判断。

## 仓库设置目标

- 默认分支：`main`。
- 主分支要求 PR 和 `macOS build and tests` 检查通过，要求分支包含最新主分支，要求讨论解决，禁止强推与删除；规则同时应用于管理员。
- 初期只有一个维护者时，审批人数为 0，仍要求 PR，避免作者无法审批自己的 PR。外部贡献仍由维护者人工审查后操作合并。
- 有第二位可信维护者后，可调整为至少 1 人批准、必要时引入 CODEOWNERS，再授权其维护仓库。
- 只启用 Squash merge，合并后自动删除仓库内已合入的短期远端分支。
- 普通自动检查使用只读权限和 `pull_request` 事件，不向外部 PR 暴露凭据；只有维护者推送版本 Tag 才触发具有发布权限的 Release 工作流。

以上规则已于 2026-10-28 在远端设置并通过 API 回读核实。后续以实际 GitHub 设置为准。首次推送需要先建立主分支，然后才能启用其保护规则。

## 发布、回滚与项目扩大

从已验证的主分支 commit 创建 `vX.Y.Z` 标签，使用 [发布规则](发布规则.md) 中的脚本触发自动测试、打包、校验并上传 Release。每次更新先 commit，通过 PR 合入；只有准备向用户发布时才打标签。日常源码仓库不保存构建产物和用户音频。

已合入的问题通过修复 PR 或 revert PR 处理，不重写主分支历史。项目参与人数增多时，先补充 Issue 模板、版本变更记录和维护者分工；出现并行维护多个版本的实际需求后，再引入长期版本分支。

## 性能和成本

版本管理与协作配置不改变播放器运行时的延迟、吞吐、CPU 或内存。Git 历史增加少量源码存储；初次提交后本地 Git 对象约 112 KiB，未包含应用或构建缓存。每次 PR 与合入主分支会触发云端编译和测试，增加开发反馈等待时间；并发的新运行会取消同一分支的旧运行。首轮远端 macOS 作业实测运行约 45 秒，其中音频与行为检查约 20 秒、Release 构建约 14 秒，不含排队时间；后续时间取决于 runner、缓存和代码变化。

按 GitHub 当前文档，公开仓库的标准托管 runner 使用免费；本项目不配置付费大型 runner。外部调用仅发生在开发协作与 CI 阶段，不增加播放器对外部服务的依赖。

参考：[GitHub 分支保护](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)、[Fork 与 PR](https://docs.github.com/en/get-started/exploring-projects-on-github/contributing-to-a-project)、[Actions 计费](https://docs.github.com/en/actions/concepts/billing-and-usage)。
