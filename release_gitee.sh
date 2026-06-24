#!/usr/bin/env bash
# 把当前 tag 的 release 同步到 Gitee（创建 release + 上传 DMG）
#
# 用法：
#   ./release_gitee.sh              # 用最新 tag
#   ./release_gitee.sh v0.2.1       # 指定 tag
#
# 前置：
#   1. ~/.config/mixcut/gitee.env 内含 Gitee Personal Access Token
#      生成入口：https://gitee.com/profile/personal_access_tokens
#      文件格式：
#        GITEE_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#        GITEE_OWNER=jinxiushanhehao
#        GITEE_REPO=mixed_cut
#      chmod 600 文件权限避免其它进程读取
#   2. ~/Desktop/MixCut.dmg 已通过 Release 构建并打包
#   3. 当前 tag 已 push 到 Gitee（或开启了 GitHub→Gitee 同步会自动带过去）
#
# 行为：
#   - 若 Gitee 上对应 tag 的 release 已存在（同步过来的）→ 直接上传 DMG 附件
#   - 否则从 GitHub release 拉取 notes 创建 Gitee release，再上传 DMG

set -euo pipefail

TAG="${1:-$(git describe --tags --abbrev=0)}"
DMG="${HOME}/Desktop/MixCut.dmg"
CONFIG="${HOME}/.config/mixcut/gitee.env"

# --- 校验 ---
if [[ ! -f "$CONFIG" ]]; then
    cat >&2 <<EOF
❌ 缺少 $CONFIG
请按下面格式创建后再跑：
   mkdir -p ~/.config/mixcut
   cat > ~/.config/mixcut/gitee.env <<E
   GITEE_TOKEN=你的 Personal Access Token
   GITEO_OWNER=jinxiushanhehao
   GITEE_REPO=mixed_cut
   E
   chmod 600 ~/.config/mixcut/gitee.env
EOF
    exit 1
fi
if [[ ! -f "$DMG" ]]; then
    echo "❌ 找不到 $DMG，请先用 Release 配置编译并打包 DMG" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"
: "${GITEE_TOKEN:?GITEE_TOKEN 未设置}"
: "${GITEE_OWNER:?GITEE_OWNER 未设置}"
: "${GITEE_REPO:?GITEE_REPO 未设置}"

API="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"

echo "🔍 检查 Gitee 是否已有 ${TAG} 的 release..."
LIST=$(curl -sS "${API}/releases?access_token=${GITEE_TOKEN}")
RELEASE_ID=$(echo "$LIST" | jq -r --arg tag "$TAG" '.[] | select(.tag_name == $tag) | .id // empty' | head -1)

if [[ -n "$RELEASE_ID" ]]; then
    echo "✓ Release 已存在（id=${RELEASE_ID}）"
else
    echo "📝 Gitee 上没有，创建 release ${TAG}..."
    BODY_FILE=$(mktemp)
    trap 'rm -f "$BODY_FILE"' EXIT

    # 优先从 GitHub release 复用 notes
    if command -v gh >/dev/null 2>&1; then
        gh release view "$TAG" --json body --jq .body > "$BODY_FILE" 2>/dev/null || true
    fi
    if [[ ! -s "$BODY_FILE" ]]; then
        echo "MixCut ${TAG}" > "$BODY_FILE"
    fi

    PAYLOAD=$(jq -Rs \
        --arg token "$GITEE_TOKEN" \
        --arg tag "$TAG" \
        --arg name "MixCut ${TAG}" \
        --arg branch "main" \
        '{access_token: $token, tag_name: $tag, name: $name, body: ., prerelease: false, target_commitish: $branch}' \
        < "$BODY_FILE")

    RESP=$(curl -sS -X POST "${API}/releases" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")
    RELEASE_ID=$(echo "$RESP" | jq -r '.id // empty')
    if [[ -z "$RELEASE_ID" ]]; then
        echo "❌ 创建 release 失败: $RESP" >&2
        exit 1
    fi
    echo "✓ Release 已创建（id=${RELEASE_ID}）"
fi

# Gitee 的 attach_files 不会覆盖同名附件，而是新增一个重复 asset；
# 下载链接按文件名路由，会"先上传者优先"，导致拿到旧版。
# 所以上传前必须先删掉同名旧附件，否则会发出版本过期的包（v0.4.0 踩过这个坑）。
DMG_NAME=$(basename "$DMG")
echo "🧹 清理同名旧附件（${DMG_NAME}）..."
OLD_IDS=$(curl -sS "${API}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" \
    | jq -r --arg name "$DMG_NAME" '.[] | select(.name == $name) | .id')
for AID in $OLD_IDS; do
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        "${API}/releases/${RELEASE_ID}/attach_files/${AID}?access_token=${GITEE_TOKEN}")
    echo "   删除旧附件 id=${AID} (HTTP ${CODE})"
done

echo "📤 上传 DMG ($(du -h "$DMG" | cut -f1)) 到 Gitee..."
UPLOAD=$(curl -sS -X POST \
    "${API}/releases/${RELEASE_ID}/attach_files" \
    -F "access_token=${GITEE_TOKEN}" \
    -F "file=@${DMG}")

URL=$(echo "$UPLOAD" | jq -r '.browser_download_url // empty')
if [[ -z "$URL" ]]; then
    echo "⚠️  附件上传响应异常: $UPLOAD" >&2
    exit 1
fi

echo "✅ Gitee Release ${TAG} 完成"
echo "   附件: $URL"
echo "   页面: https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/tag/${TAG}"
