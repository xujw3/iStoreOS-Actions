#!/bin/bash
set -euo pipefail

# 此脚本在 x86_64 ImageBuilder 根目录运行。
# x86_64 使用 ImageBuilder profile 默认包集合，仅追加本仓库的可选包/排除项，
# 避免把 armsr/armv8 的完整包清单和本地 aarch64 ipk 混入 x86 固件。
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
STORE_REPO_URL="${STORE_REPO_URL:-https://github.com/wukongdaily/store.git}"
STORE_REPO_REF="${STORE_REPO_REF:-12f44797a69adf76de006386963c6af9de4f4c40}"
STORE_RUN_ARCH="${STORE_RUN_ARCH:-x86_64}"

. ./custom-packages.sh
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
echo "第三方软件包: $CUSTOM_PACKAGES"

load_package_list() {
  local list_file="$1"

  if [ ! -f "$list_file" ]; then
    echo "⚪️ 未找到软件包清单，跳过: $list_file"
    return 0
  fi

  while IFS= read -r package; do
    case "$package" in
      ''|'#'*) continue ;;
    esac
    PACKAGES="$PACKAGES $package"
  done < "$list_file"
}

has_positive_custom_package() {
  local package

  for package in $CUSTOM_PACKAGES; do
    case "$package" in
      -*) ;;
      *) return 0 ;;
    esac
  done

  return 1
}

sync_extra_packages() {
  echo "🔄 正在同步第三方软件仓库: $STORE_REPO_URL@$STORE_REPO_REF"
  rm -rf /tmp/store-run-repo
  git init /tmp/store-run-repo
  git -C /tmp/store-run-repo remote add origin "$STORE_REPO_URL"
  git -C /tmp/store-run-repo fetch --depth=1 origin "$STORE_REPO_REF"
  git -C /tmp/store-run-repo checkout --detach FETCH_HEAD

  mkdir -p extra-packages
  if [ ! -d "/tmp/store-run-repo/run/$STORE_RUN_ARCH" ]; then
    echo "❌ 第三方软件仓库缺少 run/$STORE_RUN_ARCH 目录"
    echo "如只是要排除内置包，请仅使用 -包名；如要安装第三方包，请确认插件仓库提供 x86_64 版本。"
    exit 1
  fi

  cp -r "/tmp/store-run-repo/run/$STORE_RUN_ARCH"/* extra-packages/

  echo "✅ Run files copied to extra-packages:"
  if ls extra-packages/*.run >/dev/null 2>&1; then
    ls -lh extra-packages/*.run
  else
    echo "未发现 .run 文件，仅整理 .ipk 文件。"
  fi

  sh prepare-packages.sh
  echo "打印 imagebuilder/packages 目录结构"
  ls -lah packages/
}

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建 x86_64 固件..."

PACKAGES=""
load_package_list package-lists/build-required.txt
load_package_list package-lists/local-default.txt

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择任何第三方软件包或排除项"
elif has_positive_custom_package; then
  sync_extra_packages
else
  echo "⚪️ 自定义包仅包含排除项，不同步第三方插件仓库"
fi

PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 构建镜像
echo "开始构建......打印追加/排除包名===="
echo "$PACKAGES"

if ! make image PROFILE=generic PACKAGES="$PACKAGES" FILES="files"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - x86_64 构建成功."
