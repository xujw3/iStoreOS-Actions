#!/bin/bash
set -euo pipefail

# 此脚本在 x86_64 ImageBuilder 根目录运行。
# x86_64 使用 ImageBuilder profile 默认包集合，仅追加本仓库的可选包/排除项，
# 避免把 armsr/armv8 的完整包清单和本地 aarch64 ipk 混入 x86 固件。
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
STORE_REPO_URL="${STORE_REPO_URL:-https://github.com/wukongdaily/store.git}"
STORE_REPO_REF="${STORE_REPO_REF:-12f44797a69adf76de006386963c6af9de4f4c40}"
STORE_RUN_ARCH="${STORE_RUN_ARCH:-x86_64}"
DAEDE_FEED_BASE_URL="${DAEDE_FEED_BASE_URL:-https://kenzo111.s3.us-west-004.backblazeb2.com/openwrt-feed/daed}"
DAEDE_SDK="${DAEDE_SDK:-24.10}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"
VMLINUX_BTF_VERSION="${VMLINUX_BTF_VERSION:-6.6.141}"
VMLINUX_BTF_SHA256="${VMLINUX_BTF_SHA256:-88bf778b3a4a3d72e509a7cc39f4e6f39b1f959e174a37c2a07a763b2bf75138}"
VMLINUX_BTF_URL="${VMLINUX_BTF_URL:-https://github.com/kenzok8/vmlinux-btf/releases/download/latest/vmlinux-btf_${VMLINUX_BTF_VERSION}-r1_${DAEDE_ARCH}.ipk}"

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

package_requested() {
  local wanted="$1"
  local package

  for package in $PACKAGES $CUSTOM_PACKAGES; do
    [ "$package" = "$wanted" ] && return 0
  done

  return 1
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --show-error --retry 3 --retry-delay 5 -o "$output" "$url"
  else
    wget -O "$output" "$url"
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  [ -n "$expected" ] || return 0
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "❌ $file 校验失败: expected=$expected actual=$actual"
    exit 1
  fi
}

manifest_value() {
  local manifest="$1"
  local key="$2"

  sed -n "s/^$key=//p" "$manifest" | head -n 1
}

download_daede_package() {
  local manifest="$1"
  local base_url="$2"
  local package="$3"
  local file
  local sha

  file=$(manifest_value "$manifest" "$package")
  sha=$(manifest_value "$manifest" "${package}_sha256")
  if [ -z "$file" ]; then
    echo "❌ daede manifest 中找不到包: $package"
    exit 1
  fi

  echo "⏬ 下载 daede 包: $file"
  download_file "$base_url/$file" "packages/$file"
  verify_sha256 "packages/$file" "$sha"
}

download_daede_packages() {
  local base_url="$DAEDE_FEED_BASE_URL/$DAEDE_SDK/$DAEDE_ARCH"
  local manifest="/tmp/manifest-daede.txt"
  local package

  if ! package_requested dae && ! package_requested daed && ! package_requested luci-app-daede && ! package_requested vmlinux-btf; then
    return 0
  fi

  mkdir -p packages

  if package_requested dae || package_requested daed || package_requested luci-app-daede; then
    echo "🔄 下载 daede x86_64 预编译包 manifest: $base_url/manifest-daede.txt"
    download_file "$base_url/manifest-daede.txt" "$manifest"

    # luci-app-daede 默认依赖 daed；即使只显式安装 LuCI，也下载 daed 供本地源解析依赖。
    if package_requested luci-app-daede && ! package_requested dae && ! package_requested daed; then
      download_daede_package "$manifest" "$base_url" daed
    fi

    for package in dae daed luci-app-daede; do
      if package_requested "$package"; then
        download_daede_package "$manifest" "$base_url" "$package"
      fi
    done
  fi

  if package_requested vmlinux-btf; then
    local btf_file
    btf_file=$(basename "$VMLINUX_BTF_URL")
    echo "⏬ 下载 x86_64 vmlinux-btf: $btf_file"
    download_file "$VMLINUX_BTF_URL" "packages/$btf_file"
    verify_sha256 "packages/$btf_file" "$VMLINUX_BTF_SHA256"
  fi
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
download_daede_packages

# 构建镜像
echo "开始构建......打印追加/排除包名===="
echo "$PACKAGES"

if ! make image PROFILE=generic PACKAGES="$PACKAGES" FILES="files"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - x86_64 构建成功."
