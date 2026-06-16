# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 常用命令

此仓库主要通过 GitHub Actions 构建固件；仓库本身没有 Node/Python/Go 等应用级依赖管理，也没有配置自动化单元测试框架。

### GitHub Actions 构建

```bash
# 1) 构建通用 armsr/armv8 rootfs，并上传到 Release
# 需要仓库已配置 secrets.GH_TOKEN
# network_settings 可选 dhcp 或 static；static 时 ipaddr/gateway 会写入首次启动脚本
gh workflow run St1_Build-Rootfs-release.yml \
  -f build_version=20260417 \
  -f network_settings=dhcp \
  -f ipaddr=192.168.5.88 \
  -f gateway=192.168.5.1

# 2) 基于 St1 产出的 rootfs 打包设备固件 .img.gz
gh workflow run St2_Build-iStoreOS-ib.yml \
  -f openwrt_board=s905d_s905x3_s912_s922x-ct2000 \
  -f openwrt_kernel=6.6.y \
  -F auto_kernel=true \
  -f openwrt_rootfs=RELEASE \
  -f network_settings=dhcp

# 3) 备用 SNAPSHOT 路径：下载外部预构建 rootfs 后打包设备固件
gh workflow run StX_Build-iStoreOS-src.yml \
  -f openwrt_board=s905d_s905x3_s912_s922x-ct2000 \
  -f openwrt_kernel=6.6.y \
  -F auto_kernel=true
```

### 本地语法检查

```bash
# Shell 脚本语法检查
bash -n arm64/build24.sh shell/*.sh
sh -n files/etc/uci-defaults/99-custom.sh files/etc/rc.local

# 检查补丁中的空白错误
git diff --check
```

没有“单个测试”命令；修改某个 shell 脚本时，至少对该文件运行对应的 `bash -n <file>` 或 `sh -n <file>`。

### 本地复现 rootfs 构建

本地构建需要在 Linux/Ubuntu 环境中下载并展开 iStoreOS ImageBuilder；`arm64/Makefile` 不能直接在仓库根目录运行，因为它依赖 ImageBuilder 内部的 `rules.mk`、`include/`、`scripts/` 等文件。

```bash
sudo apt-get update
sudo apt-get install -y build-essential libncurses5-dev zstd curl unzip tree

curl -L -o imagebuilder.tar.zst \
  https://github.com/Kwonelee/iStoreOS-Actions/releases/download/iStoreOS-ImageBuilder/20260417-istoreos-imagebuilder-armsr-armv8.Linux-x86_64.tar.zst
tar --use-compress-program=unzstd -xvf imagebuilder.tar.zst
mv istoreos-imagebuilder-* imagebuilder

cp arm64/{build24.sh,Makefile} imagebuilder/
cp shell/{prepare-packages.sh,custom-packages.sh} imagebuilder/
find files/packages/ -name "*.ipk" -exec cp {} imagebuilder/packages/ \;
mkdir -p imagebuilder/files/etc/{uci-defaults,banner1}
cp files/etc/uci-defaults/99-custom.sh imagebuilder/files/etc/uci-defaults/
cp files/etc/banner imagebuilder/files/etc/banner1/
cp files/etc/rc.local imagebuilder/files/etc/

cd imagebuilder
sed -i 's/# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' .config
sed -i 's|CONFIG_TARGET_ROOTFS_SQUASHFS=.*|# CONFIG_TARGET_ROOTFS_SQUASHFS is not set|g' .config
sed -i 's|CONFIG_TARGET_IMAGES_GZIP=.*|# CONFIG_TARGET_IMAGES_GZIP is not set|g' .config
bash ./build24.sh
```

在 ImageBuilder 目录内可用的辅助命令：

```bash
make info
make manifest PROFILE=generic PACKAGES="<packages>" STRIP_ABI=1
make package_depends PACKAGE=<package-name>
make package_whatdepends PACKAGE=<package-name>
make clean
```

## 架构概览

这是一个 iStoreOS/OpenWrt 固件装配仓库，不是传统应用源码仓库。核心流程分两段：先用 ImageBuilder 生成通用 rootfs，再用 ophub/amlogic-s9xxx-openwrt 将 rootfs 打包成不同开发板/电视盒子的可刷写镜像。

- `.github/workflows/St1_Build-Rootfs-release.yml`：下载指定版本的 iStoreOS ImageBuilder，复制本仓库的构建脚本、rootfs overlay 和本地 `.ipk`，根据输入选择 static/dhcp 首次启动网络配置，构建 `armsr/armv8` 的 `generic-rootfs.tar.gz`，并发布到 `iStoreOS-${VERSION}-RELEASE-${network_settings}`。
- `.github/workflows/St2_Build-iStoreOS-ib.yml`：从本仓库 Release 下载 St1 产出的 rootfs，调用 `ophub/amlogic-s9xxx-openwrt@main` 为所选 `openwrt_board` 和内核系列打包 `.img.gz`，再上传到同一个版本/网络配置对应的 Release。
- `.github/workflows/StX_Build-iStoreOS-src.yml`：备用打包路径，rootfs 来自 `Kwonelee/Rootfs-Actions` 的 `generic-rootfs` Release，打包 action 使用 `Kwonelee/amlogic-s9xxx-openwrt@main`，产物发布为 SNAPSHOT。
- `arm64/build24.sh`：rootfs 的主要包清单和构建入口。它会 source `custom-packages.sh`，按 iStoreOS 24.10 组件清单组装 `PACKAGES`，追加/排除本地第三方插件，最后执行 `make image PROFILE=generic PACKAGES="$PACKAGES" FILES="files"`。
- `shell/custom-packages.sh`：仓库外第三方插件开关和移除组件开关；通过向 `CUSTOM_PACKAGES` 追加包名或 `-包名` 影响最终 ImageBuilder 包集合。
- `shell/prepare-packages.sh`：当启用仓库外插件时，整理 `extra-packages` 中的 `.run`/`.ipk` 到 ImageBuilder 的 `packages/` 本地软件源。
- `arm64/Makefile`：随 ImageBuilder 使用的 OpenWrt Makefile 变体，包解析指向 `repositories.conf` 和本地 `packages/`；常用目标包括 `image`、`manifest`、`package_depends`、`package_whatdepends`。
- `files/`：rootfs overlay。`files/etc/uci-defaults/99-custom.sh` 是首次启动一次性配置脚本；`files/etc/banner` 在构建时替换 `版本号` 占位符；`files/etc/rc.local` 当前用于启动后重新挂载根分区为可读写；`files/packages/**` 存放会被复制进 ImageBuilder 本地源的 `.ipk`。

## 修改时需要同步的点

- 版本号集中出现在三个 workflow 的 `env.VERSION`，以及 `arm64/repositories.conf` 的 OpenWrt 版本/内核 kmods URL。升级 iStoreOS/OpenWrt 版本时要同时检查这些位置，并确认 St1 Release tag 与 St2 下载 URL 仍匹配。
- `St1_Build-Rootfs-release.yml` 通过 `sed` 行号删除 `99-custom.sh` 中的 static 或 dhcp 网络配置块。改动 `files/etc/uci-defaults/99-custom.sh` 的网络配置块时，必须同步更新 workflow 中的删除行号，否则会保留错误配置或删错内容。
- `St2_Build-iStoreOS-ib.yml` 与 `StX_Build-iStoreOS-src.yml` 维护了几乎相同的 `openwrt_board` 选项列表；新增或重命名设备时通常要同步两个 workflow，并按需更新 `README.md` 的支持设备表。
- `files/packages/**` 中新增 `.ipk` 后，若希望默认集成，需要在 `arm64/build24.sh` 末尾的第三方可选插件区域取消/新增对应包名；仅放入目录不会自动安装。
