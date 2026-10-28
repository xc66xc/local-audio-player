#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--dry-run' ) ]]; then
  printf '用法：bash scripts/publish-release.sh [--dry-run]\n' >&2
  exit 1
fi
[[ "$(git branch --show-current)" == main ]] || { printf '请切换到 main 后发布。\n' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { printf '工作区存在未提交修改，停止发布。\n' >&2; exit 1; }
[[ -f "releases/v${APP_VERSION}.md" ]] || { printf '缺少本版本的发布说明。\n' >&2; exit 1; }
git fetch origin main --tags
RELEASE_COMMIT="$(git rev-parse HEAD)"
[[ "$RELEASE_COMMIT" == "$(git rev-parse origin/main)" ]] || { printf '本地 main 与远端不同，请先同步。\n' >&2; exit 1; }
RELEASE_TAG="v${APP_VERSION}"
if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  printf '标签 %s 已存在；不能重新发布同一版本，请升级版本号。\n' "$RELEASE_TAG" >&2
  exit 1
fi
while IFS= read -r existing_tag; do
  existing_version="${existing_tag#v}"
  if is_release_version "$existing_version" && ! release_version_greater_than "$APP_VERSION" "$existing_version"; then
    printf '新版本 %s 必须高于已有版本 %s。\n' "$APP_VERSION" "$existing_version" >&2
    exit 1
  fi
done < <(git tag --list 'v*')
CI_CONCLUSION="$(gh run list --workflow ci.yml --branch main --event push --commit "$RELEASE_COMMIT" --limit 1 --json conclusion --jq '.[0].conclusion // ""')"
[[ "$CI_CONCLUSION" == success ]] || { printf '当前 main 的 CI 尚未通过，停止发布。\n' >&2; exit 1; }
if [[ "${1:-}" == '--dry-run' ]]; then
  printf '检查通过：可为 %s 创建 %s，未创建或推送标签。\n' "$RELEASE_COMMIT" "$RELEASE_TAG"
  exit 0
fi
git tag -a "$RELEASE_TAG" "$RELEASE_COMMIT" -m "Release $RELEASE_TAG"
git push origin "refs/tags/$RELEASE_TAG"
printf '已推送 %s。GitHub Release 工作流将测试、打包并发布。\n' "$RELEASE_TAG"
