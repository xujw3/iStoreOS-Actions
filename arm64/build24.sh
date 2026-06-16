#!/bin/bash
set -euo pipefail

# 此脚本在 ImageBuilder 根目录运行
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
STORE_REPO_URL="${STORE_REPO_URL:-https://github.com/wukongdaily/store.git}"
STORE_REPO_REF="${STORE_REPO_REF:-12f44797a69adf76de006386963c6af9de4f4c40}"

. ./custom-packages.sh
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> "$LOGFILE"

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库 run/ipk。默认固定 commit，便于复现；如需跟随上游可覆盖 STORE_REPO_REF。
  echo "🔄 正在同步第三方软件仓库: $STORE_REPO_URL@$STORE_REPO_REF"
  rm -rf /tmp/store-run-repo
  git init /tmp/store-run-repo
  git -C /tmp/store-run-repo remote add origin "$STORE_REPO_URL"
  git -C /tmp/store-run-repo fetch --depth=1 origin "$STORE_REPO_REF"
  git -C /tmp/store-run-repo checkout --detach FETCH_HEAD

  # 拷贝 run/arm64 下所有 run 文件和 ipk 文件到 extra-packages 目录
  mkdir -p extra-packages
  if [ ! -d /tmp/store-run-repo/run/arm64 ]; then
    echo "❌ 第三方软件仓库缺少 run/arm64 目录"
    exit 1
  fi
  cp -r /tmp/store-run-repo/run/arm64/* extra-packages/

  echo "✅ Run files copied to extra-packages:"
  if ls extra-packages/*.run >/dev/null 2>&1; then
    ls -lh extra-packages/*.run
  else
    echo "未发现 .run 文件，仅整理 .ipk 文件。"
  fi
  # 解压并拷贝 ipk 到 packages 目录
  sh prepare-packages.sh
  echo "打印imagebuilder/packages目录结构"
  ls -lah packages/ | grep partexp || true
fi

load_package_list() {
  local list_file="$1"

  if [ ! -f "$list_file" ]; then
    echo "❌ 找不到软件包清单: $list_file"
    exit 1
  fi

  while IFS= read -r package; do
    case "$package" in
      ''|'#'*) continue ;;
    esac
    PACKAGES="$PACKAGES $package"
  done < "$list_file"
}

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= iStoreOS 24.10 官方集成插件===================
# 包清单拆分在 package-lists/ 下，便于维护和审查 diff。
PACKAGES=""
load_package_list package-lists/official.txt
load_package_list package-lists/build-required.txt
load_package_list package-lists/local-default.txt

# N1无线：此固件未考虑无线，需自行研究
# 如需尝试，可在 package-lists/local-default.txt 或 custom-packages.sh 中追加：
# kmod-brcmfmac wpad-basic-mbedtls

# 追加自定义包
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 构建镜像
echo "开始构建......打印所有包名===="
echo "$PACKAGES"

if ! make image PROFILE=generic PACKAGES="$PACKAGES" FILES="files"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建成功."
