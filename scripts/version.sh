#!/bin/bash
# Shared by local builds, packaging, and the release workflow.
RELEASE_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

is_release_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

release_version_greater_than() {
  local -a left right
  local index
  IFS=. read -r -a left <<< "$1"
  IFS=. read -r -a right <<< "$2"
  for index in 0 1 2; do
    if [[ ${#left[$index]} -ne ${#right[$index]} ]]; then
      [[ ${#left[$index]} -gt ${#right[$index]} ]]
      return
    fi
    if [[ "${left[$index]}" != "${right[$index]}" ]]; then
      [[ "${left[$index]}" > "${right[$index]}" ]]
      return
    fi
  done
  return 1
}

APP_VERSION="$(cat "$RELEASE_PROJECT_ROOT/VERSION")"
if ! is_release_version "$APP_VERSION"; then
  printf 'VERSION 必须是无前导零的 X.Y.Z 正式版本号。\n' >&2
  exit 1
fi
