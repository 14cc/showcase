#!/bin/bash
# a5 源一键构建（在 Mac 上运行）
#   用法:  ./build-a5.sh            构建 + 生成源 + 本地起服务
#          NO_SERVE=1 ./build-a5.sh 只构建不起服务
#          REPO_URL=https://xxx/ ./build-a5.sh   指定正式源地址（默认用本机局域网 IP:8000）
#          RELEASE=1 ./build-a5.sh  正式发布（版本号不加 +dev 后缀）
set -euo pipefail

TOP="$(cd "$(dirname "$0")" && pwd)"          # publicsource/
SC="$TOP/showcase"
SH="$TOP/share"
OUT="$TOP/repo"                               # 生成的 a5 源
WORK="$TOP/.build"
PORT="${PORT:-8000}"
REAL_CERT="${REAL_CERT:-$TOP/../embedded_cert.real.h}"

step(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 0. 检查工具 ----------
step "检查工具链"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" || die "找不到 iPhoneOS SDK，先装 Xcode 并 xcode-select -s"
for t in ldid dpkg-deb python3; do command -v $t >/dev/null || die "缺少 ${t}（brew install ldid dpkg）"; done
[ -f "$REAL_CERT" ] || die "找不到内置证书头文件 $REAL_CERT"
grep -q "EMB_CERT_PRESENT 1" "$REAL_CERT" || die "$REAL_CERT 不是有效的证书头"
CC=(xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=12.0)
echo "SDK: $SDK"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
REPO_URL="${REPO_URL:-http://$IP:$PORT/}"
REPO_URL="${REPO_URL%/}/"
echo "源地址: $REPO_URL"

. "$SC/packaging/scripts/version.sh"
# 测试构建自动加 +dev时间戳，同一个版本号不会对应两份不同的包；正式发布用 RELEASE=1 ./build-a5.sh
DEV=""
if [ "${RELEASE:-0}" != 1 ]; then DEV="+dev$(date +%Y%m%d%H%M)"; PACKAGE_VERSION="$PACKAGE_VERSION$DEV"; fi
# App 里显示的版本（错误报告、设置页）带上我们的发布号：1.0~beta5.1-8 -> "1.0 Beta 5.1.8"
APP_DISPLAY_VERSION="$DISPLAY_VERSION.${PACKAGE_VERSION##*-}"
echo "版本: $PACKAGE_VERSION ($APP_DISPLAY_VERSION)"

rm -rf "$WORK"; mkdir -p "$WORK/bin" "$OUT/debs"
if [ "${KEEP_SHOWCASE:-0}" = 1 ]; then
  ls "$OUT/debs/"com.rostane.showcase*.deb >/dev/null 2>&1 || die "KEEP_SHOWCASE=1 但 repo/debs 里没有 Showcase 包"
  echo "沿用已有 Showcase 包: $(cd "$OUT/debs" && ls com.rostane.showcase*.deb | tr '\n' ' ')"
  rm -f "$OUT/debs/"com.rostane.share_*.deb
else
  rm -f "$OUT/debs/"*.deb
fi


# 新版 Xcode 会把 CoreMedia 链到 @rpath/libswiftCoreMedia.dylib（老系统没有，启动即闪退），改回系统框架
fix_links(){ for b in "$@"; do
  install_name_tool -change @rpath/libswiftCoreMedia.dylib /System/Library/Frameworks/CoreMedia.framework/CoreMedia "$b" 2>/dev/null || true
  if otool -L "$b" | grep -q '@rpath/libswift'; then die "$b 仍依赖 Swift 运行库：$(otool -L "$b" | grep @rpath)"; fi
done; }

# KEEP_SHOWCASE=1：只重打 share，沿用 repo/debs 里已发布的 Showcase 包（避免同一版本号对应两份不同的包）
if [ "${KEEP_SHOWCASE:-0}" != 1 ]; then

# ---------- 1. 内置证书（构建完自动还原空壳，绝不入库） ----------
step "烤入内置证书"
cp "$SC/source/embedded_cert.h" "$WORK/embedded_cert.h.shell"
restore(){ cp "$WORK/embedded_cert.h.shell" "$SC/source/embedded_cert.h" 2>/dev/null || true; }
trap restore EXIT
cp "$REAL_CERT" "$SC/source/embedded_cert.h"

# ---------- 2. BTstack（BTdaemon + libBTstack.dylib） ----------
step "编译 BTstack"
BT="$SC/btstack-rootless"
# HAVE_UNIX_SOCKETS：BTdaemon 由 launchd 在 /tmp/BTstack 上监听，客户端库必须走这个 unix socket（不加会去连 TCP 13333，bt_open 直接返回 -1）
BTCF=(-DHAVE_UNIX_SOCKETS -fno-objc-arc -O2 -I"$BT/port/ios" -I"$BT/port/ios/src" -I"$BT/platform/daemon/src"
      -I"$BT/platform/posix" -I"$BT/platform/corefoundation" -I"$BT/src" -I"$BT/src/ble"
      -Wno-deprecated-declarations -Wno-deprecated-non-prototype -Wno-incompatible-pointer-types
      -Wno-pointer-sign -Wno-unused-command-line-argument -Wno-incompatible-function-pointer-types -Wno-int-conversion)
# carplay_bt 用的是老版 libBTstack 的名字，新源码改了名：老函数名由 tools/btstack_compat.c 接上，
# 老命令名用链接别名补。少了这些，程序一启动就报 symbol not found（-undefined dynamic_lookup 编译时不报错）。
BTCOMPAT="$TOP/tools/btstack_compat.c"
BTALIAS=()
for c in rfcomm_register_service rfcomm_accept_connection rfcomm_create_channel \
         sdp_client_query_rfcomm_services sdp_register_service_record; do
  BTALIAS+=("-Wl,-alias,_${c}_cmd,_${c}")
done
# 检查 CarDisplaySim 要的 BTstack 符号库里都有（$1 程序，$2 动态库；静态链接时只传 $1，要求一个都不缺）
check_bt_syms(){
  local need have miss
  need="$(xcrun nm -u "$1" | sed 's/^_//' | { grep -E '^(bt_|run_loop_|btstack_|hci_|rfcomm_|sdp_|l2cap_)' || true; } | sort -u)"
  if [ -n "${2:-}" ]; then have="$(xcrun nm -gU "$2" | awk '{print $3}' | sed 's/^_//' | sort -u)"; else have=""; fi
  miss="$(comm -23 <(printf '%s\n' "$need") <(printf '%s\n' "$have") | grep -v '^$' || true)"
  [ -z "$miss" ] || die "$(basename "$1") 需要的 BTstack 符号库里没有：$(echo $miss)"
  # 自己编的库必须连 unix socket /tmp/BTstack（上游老库本来就是）
  grep -aq '/tmp/BTstack' "${2:-$1}" || die "$(basename "${2:-$1}") 里没有 /tmp/BTstack，连不上 BTdaemon（缺 -DHAVE_UNIX_SOCKETS？）"
}
SDK="$SDK" ENT="$SC/source/ent_btdaemon.xml" OUT="$WORK/bin/BTdaemon" zsh "$BT/build_btdaemon.sh"
"${CC[@]}" "${BTCF[@]}" -dynamiclib -install_name /var/jb/usr/lib/libBTstack.dylib \
  "$BT/src/btstack_linked_list.c" "$BT/src/btstack_run_loop.c" "$BT/src/hci_cmd.c" \
  "$BT/src/hci_dump.c" "$BT/src/btstack_util.c" "$BT/platform/daemon/src/btstack.c" \
  "$BT/platform/daemon/src/daemon_cmds.c" "$BT/platform/daemon/src/socket_connection.c" \
  "$BT/platform/corefoundation/btstack_run_loop_corefoundation.m" "$BT/platform/posix/btstack_run_loop_posix.c" \
  "$BT/src/classic/sdp_util.c" "$BT/src/classic/spp_server.c" "$BTCOMPAT" "${BTALIAS[@]}" \
  -framework Foundation -framework CoreFoundation -Wl,-undefined,dynamic_lookup \
  -o "$WORK/bin/libBTstack.dylib"

BTSRC=("$BT/src/btstack_linked_list.c" "$BT/src/btstack_run_loop.c" "$BT/src/hci_cmd.c"
  "$BT/src/hci_dump.c" "$BT/src/btstack_util.c" "$BT/platform/daemon/src/btstack.c"
  "$BT/platform/daemon/src/daemon_cmds.c" "$BT/platform/daemon/src/socket_connection.c"
  "$BT/platform/corefoundation/btstack_run_loop_corefoundation.m" "$BT/platform/posix/btstack_run_loop_posix.c"
  "$BT/src/classic/sdp_util.c" "$BT/src/classic/spp_server.c" "$BTCOMPAT")

# ---------- 3. Showcase 三个二进制 ----------
step "编译 Showcase"
S="$SC/source"
OBJC=(-fobjc-arc -DSHOWCASE_ROOTLESS=1)
"${CC[@]}" "${OBJC[@]}" -DAPP_VERSION="\"$APP_DISPLAY_VERSION\"" -o "$WORK/bin/Showcase" "$S/Showcase.m" \
  -framework UIKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
  -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
"${CC[@]}" "${OBJC[@]}" -I"$S" -o "$WORK/bin/CarDisplaySim" "$S/carplay_bt.m" "$WORK/bin/libBTstack.dylib" \
  -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
"${CC[@]}" "${OBJC[@]}" -I"$S" -o "$WORK/bin/CarPlay Simulator" "$S/carplay_services.m" "$S/carplay_pair.c" \
  "$S/vendor/monocypher/monocypher.c" "$S/vendor/monocypher/monocypher-ed25519.c" "$S/vendor/libtommath/tommath.c" \
  -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup


fix_links "$WORK/bin/Showcase" "$WORK/bin/CarDisplaySim" "$WORK/bin/CarPlay Simulator"
check_bt_syms "$WORK/bin/CarDisplaySim" "$WORK/bin/libBTstack.dylib"

# ---------- 3b. rootful 版（checkra1n / unc0ver 等有根越狱） ----------
if [ "${ROOTFUL:-1}" = 1 ]; then
  step "准备 rootful 版 BTstack"
  FN=""; RF="$WORK/rootful"; mkdir -p "$RF/bin" "$RF/payload"
  # 优先用上游 Beta5 rootful 包里经过验证的 BTstack 运行库
  if curl -fsSL --retry 2 --connect-timeout 15 https://aminerostane.com/repo/Packages -o "$RF/Packages" 2>/dev/null; then
    FN="$(awk '/^Package: /{p=($2=="com.rostane.showcase");a=""} p&&/^Architecture: /{a=$2} p&&a=="iphoneos-arm"&&/^Filename: /{print $2; exit}' "$RF/Packages")"
    if [ -n "$FN" ] && curl -fsSL "https://aminerostane.com/repo/$FN" -o "$RF/up.deb"; then
      dpkg-deb -x "$RF/up.deb" "$RF/payload" || true
    fi
  fi
  if [ -f "$RF/payload/usr/lib/libBTstack.dylib" ] && [ -f "$RF/payload/usr/bin/BTdaemon" ]; then
    echo "使用上游 rootful BTstack（${FN}）"
    cp "$RF/payload/usr/lib/libBTstack.dylib" "$RF/payload/usr/bin/BTdaemon" "$RF/bin/"
    cp "$RF/payload/Library/LaunchDaemons/ch.ringwald.BTstack.plist" "$RF/bin/" 2>/dev/null || true
  else
    echo "下载上游失败，改用源码编译 rootful BTstack"
    SDK="$SDK" ENT="$SC/source/ent_btdaemon.xml" OUT="$RF/bin/BTdaemon" zsh "$BT/build_btdaemon.sh"
    "${CC[@]}" "${BTCF[@]}" -dynamiclib -install_name /usr/lib/libBTstack.dylib -Wl,-not_for_dyld_shared_cache \
      "$BT/src/btstack_linked_list.c" "$BT/src/btstack_run_loop.c" "$BT/src/hci_cmd.c" \
      "$BT/src/hci_dump.c" "$BT/src/btstack_util.c" "$BT/platform/daemon/src/btstack.c" \
      "$BT/platform/daemon/src/daemon_cmds.c" "$BT/platform/daemon/src/socket_connection.c" \
      "$BT/platform/corefoundation/btstack_run_loop_corefoundation.m" "$BT/platform/posix/btstack_run_loop_posix.c" \
      "$BT/src/classic/sdp_util.c" "$BT/src/classic/spp_server.c" "$BTCOMPAT" "${BTALIAS[@]}" \
      -framework Foundation -framework CoreFoundation -Wl,-undefined,dynamic_lookup \
      -o "$RF/bin/libBTstack.dylib"
  fi
  [ -f "$RF/bin/ch.ringwald.BTstack.plist" ] || cp "$BT/port/ios/layout/Library/LaunchDaemons/ch.ringwald.BTstack.plist" "$RF/bin/"

  step "编译 rootful 版 Showcase"
  "${CC[@]}" -fobjc-arc -DAPP_VERSION="\"$APP_DISPLAY_VERSION\"" -o "$RF/bin/Showcase" "$S/Showcase.m" \
    -framework UIKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  "${CC[@]}" -fobjc-arc -I"$S" -o "$RF/bin/carplay_bt" "$S/carplay_bt.m" "$RF/bin/libBTstack.dylib" \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  "${CC[@]}" -fobjc-arc -I"$S" -o "$RF/bin/carplay_services" "$S/carplay_services.m" "$S/carplay_pair.c" \
    "$S/vendor/monocypher/monocypher.c" "$S/vendor/monocypher/monocypher-ed25519.c" "$S/vendor/libtommath/tommath.c" \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  fix_links "$RF/bin/Showcase" "$RF/bin/carplay_bt" "$RF/bin/carplay_services"
  check_bt_syms "$RF/bin/carplay_bt" "$RF/bin/libBTstack.dylib"
fi

# ---------- 3c. RootHide（隐根）版 ----------
# 隐根的越狱目录每台设备都不一样（.jbroot-随机串），程序运行时自己找（source/jbroot.h）。
# BTstack 静态链进 CarDisplaySim：setuid 程序不能用相对路径加载动态库，绝对路径又不固定。
if [ "${ROOTHIDE:-1}" = 1 ]; then
  step "编译 RootHide（隐根）版 Showcase"
  RH="$WORK/roothide"; mkdir -p "$RH/bin" "$RH/obj"
  for f in "${BTSRC[@]}"; do
    b="$(basename "$f")"; "${CC[@]}" "${BTCF[@]}" -c "$f" -o "$RH/obj/${b%.*}.o"
  done
  xcrun --sdk iphoneos libtool -static -o "$RH/libBTstack.a" "$RH/obj/"*.o
  RHF=(-fobjc-arc -DSHOWCASE_ROOTLESS=1 -DSHOWCASE_ROOTHIDE=1)
  "${CC[@]}" "${RHF[@]}" -I"$S" -DAPP_VERSION="\"$APP_DISPLAY_VERSION\"" -o "$RH/bin/Showcase" "$S/Showcase.m" \
    -framework UIKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  "${CC[@]}" "${RHF[@]}" -I"$S" -o "$RH/bin/CarDisplaySim" "$S/carplay_bt.m" "$RH/libBTstack.a" "${BTALIAS[@]}" \
    -framework Foundation -framework CoreFoundation -framework Security -Wl,-undefined,dynamic_lookup
  "${CC[@]}" "${RHF[@]}" -I"$S" -o "$RH/bin/CarPlay Simulator" "$S/carplay_services.m" "$S/carplay_pair.c" \
    "$S/vendor/monocypher/monocypher.c" "$S/vendor/monocypher/monocypher-ed25519.c" "$S/vendor/libtommath/tommath.c" \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  fix_links "$RH/bin/Showcase" "$RH/bin/CarDisplaySim" "$RH/bin/CarPlay Simulator"
  if otool -L "$RH/bin/CarDisplaySim" | grep -q libBTstack; then die "隐根版 CarDisplaySim 不应动态链接 libBTstack"; fi
  check_bt_syms "$RH/bin/CarDisplaySim"
fi

# ---------- 3d. Taurine 版（iOS 14 的 Taurine 越狱，蓝牙接管方式不同） ----------
# 照上游 build-taurine-deb.sh：Showcase 加 SHOWCASE_TAURINE（等蓝牙更久、先起 BTstack），
# 用 btstack-rootless 的新版 BTdaemon，并带上 BTQuiet 插件（压住蓝牙客户端的重连风暴）。
# carplay_bt / carplay_services 和有根版完全一样，直接复用。
if [ "${TAURINE:-1}" = 1 ] && [ "${ROOTFUL:-1}" = 1 ]; then
  step "编译 Taurine 版 Showcase"
  TA="$WORK/taurine"; mkdir -p "$TA/bin"
  "${CC[@]}" -fobjc-arc -DSHOWCASE_TAURINE -DAPP_VERSION="\"$APP_DISPLAY_VERSION\"" -o "$TA/bin/Showcase" "$S/Showcase.m" \
    -framework UIKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
    -framework Foundation -framework Security -Wl,-undefined,dynamic_lookup
  fix_links "$TA/bin/Showcase"
  xcrun --sdk iphoneos clang -isysroot "$SDK" -miphoneos-version-min=12.0 -arch arm64 -arch arm64e -Os \
    -dynamiclib -o "$TA/bin/BTQuiet.dylib" "$SC/tweak/BTQuiet.m"
fi
restore   # 所有二进制编完，立刻还原证书空壳

# ---------- 4. 打 Showcase deb ----------
step "打包 Showcase deb"
R="$WORK/rootfs"; APP="$R/var/jb/Applications/Showcase.app"
mkdir -p "$APP" "$R/var/jb/usr/bin" "$R/var/jb/usr/lib" "$R/var/jb/usr/share/showcase" \
         "$R/var/jb/Library/LaunchDaemons" "$R/DEBIAN"
cp "$WORK/bin/Showcase" "$WORK/bin/CarDisplaySim" "$WORK/bin/CarPlay Simulator" "$APP/"
cp "$WORK/bin/BTdaemon" "$R/var/jb/usr/bin/"
cp "$WORK/bin/libBTstack.dylib" "$R/var/jb/usr/lib/"
sed 's#/usr/bin/BTdaemon#/var/jb/usr/bin/BTdaemon#g' \
  "$BT/port/ios/layout/Library/LaunchDaemons/ch.ringwald.BTstack.plist" \
  > "$R/var/jb/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
fill_version "$S/Info.plist" > "$APP/Info.plist"
for e in ent_app ent_bt ent_svc ent_btdaemon; do cp "$S/$e.xml" "$R/var/jb/usr/share/showcase/"; done
cp "$SC/icon/generated/"*.png "$APP/"
cp -R "$S/Localizations/"*.lproj "$APP/"

ldid -S"$S/ent_app.xml" "$APP/Showcase"
ldid -S"$S/ent_bt.xml"  "$APP/CarDisplaySim"
ldid -S"$S/ent_svc.xml" "$APP/CarPlay Simulator"
ldid -S"$S/ent_btdaemon.xml" "$R/var/jb/usr/bin/BTdaemon"
ldid -S "$R/var/jb/usr/lib/libBTstack.dylib"

chmod 0755 "$APP" "$APP/"*.lproj; chmod 0644 "$APP/Info.plist" "$APP/"*.png "$APP/"*.lproj/*
chmod 4755 "$APP/Showcase" "$APP/CarDisplaySim" "$APP/CarPlay Simulator"
chmod 0755 "$R/var/jb/usr/bin/BTdaemon" "$R/var/jb/usr/lib/libBTstack.dylib"

# control：a5 名称、介绍页指向本源
fill_version "$SC/packaging/control-rootless/control" | sed \
  -e "s#^Name: .*#Name: Showcase · a5#" \
  -e "s#^Maintainer: .*#Maintainer: a5#" \
  -e "s#^Icon: .*#Icon: ${REPO_URL}icons/showcase.png#" \
  -e "s#^Depiction: .*#Depiction: ${REPO_URL}depictions/cydia.html#" \
  -e "s#^SileoDepiction: .*#SileoDepiction: ${REPO_URL}depictions/sileo.json#" \
  -e "s#^Homepage: .*#Homepage: https://github.com/amineross/showcase#" \
  > "$R/DEBIAN/control"
printf ' .\n a5 版：基于开源项目 Showcase (GPL) 改编，仅新增内置证书离线认证。\n' >> "$R/DEBIAN/control"
for f in postinst prerm postrm; do cp "$SC/packaging/control-rootless/$f" "$R/DEBIAN/"; chmod 0755 "$R/DEBIAN/$f"; done
find "$R" \( -name .DS_Store -o -name '._*' \) -delete
xattr -cr "$R" 2>/dev/null || true
(cd "$R" && find . -path ./DEBIAN -prune -o -type f -print | sed 's#^\./##' | while read -r f; do
   printf '%s  %s\n' "$(md5 -q "$f")" "$f"; done > DEBIAN/md5sums)
COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b "$R" \
  "$OUT/debs/com.rostane.showcase_${PACKAGE_VERSION}_iphoneos-arm64.deb"


# ---------- 4b. 打 rootful deb ----------
if [ "${ROOTFUL:-1}" = 1 ]; then
  step "打包 rootful Showcase deb"
  R2="$WORK/rootfs-rootful"; APP2="$R2/Applications/Showcase.app"
  mkdir -p "$APP2" "$R2/usr/bin" "$R2/usr/lib" "$R2/Library/LaunchDaemons" "$R2/DEBIAN"
  cp "$RF/bin/Showcase" "$RF/bin/carplay_bt" "$RF/bin/carplay_services" "$APP2/"
  cp "$RF/bin/BTdaemon" "$R2/usr/bin/"; cp "$RF/bin/libBTstack.dylib" "$R2/usr/lib/"
  cp "$RF/bin/ch.ringwald.BTstack.plist" "$R2/Library/LaunchDaemons/"
  fill_version "$S/Info.plist" > "$APP2/Info.plist"
  cp "$SC/icon/generated/"*.png "$APP2/"
  cp -R "$S/Localizations/"*.lproj "$APP2/"
  ldid -S"$S/ent_app.xml" "$APP2/Showcase"
  ldid -S"$S/ent_bt.xml"  "$APP2/carplay_bt"
  ldid -S"$S/ent_svc.xml" "$APP2/carplay_services"
  ldid -S "$R2/usr/lib/libBTstack.dylib"   # 动态库也必须签名，否则 carplay_bt 加载失败
  ldid -S"$S/ent_btdaemon.xml" "$R2/usr/bin/BTdaemon"
  chmod 0755 "$APP2" "$APP2/"*.lproj; chmod 0644 "$APP2/Info.plist" "$APP2/"*.png "$APP2/"*.lproj/*
  chmod 4755 "$APP2/Showcase" "$APP2/carplay_bt" "$APP2/carplay_services"
  chmod 0755 "$R2/usr/bin/BTdaemon" "$R2/usr/lib/libBTstack.dylib"
  chmod 0644 "$R2/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
  fill_version "$SC/packaging/control/control" | sed \
    -e "s#^Name: .*#Name: Showcase · a5 (Rootful)#" \
    -e "s#^Maintainer: .*#Maintainer: a5#" \
    -e "s#^Icon: .*#Icon: ${REPO_URL}icons/showcase.png#" \
    -e "s#^Depiction: .*#Depiction: ${REPO_URL}depictions/cydia.html#" \
    -e "s#^SileoDepiction: .*#SileoDepiction: ${REPO_URL}depictions/sileo.json#" \
    -e "s#^Homepage: .*#Homepage: https://github.com/amineross/showcase#" \
    > "$R2/DEBIAN/control"
  printf ' .\n a5 版：基于开源项目 Showcase (GPL) 改编，仅新增内置证书离线认证。\n' >> "$R2/DEBIAN/control"
  for f in postinst prerm postrm; do cp "$SC/packaging/control/$f" "$R2/DEBIAN/"; chmod 0755 "$R2/DEBIAN/$f"; done
  find "$R2" \( -name .DS_Store -o -name '._*' \) -delete
  xattr -cr "$R2" 2>/dev/null || true
  (cd "$R2" && find . -path ./DEBIAN -prune -o -type f -print | sed 's#^\./##' | while read -r f; do
     printf '%s  %s\n' "$(md5 -q "$f")" "$f"; done > DEBIAN/md5sums)
  COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b "$R2" \
    "$OUT/debs/com.rostane.showcase_${PACKAGE_VERSION}_iphoneos-arm.deb"
fi

# ---------- 4c. 打 RootHide（隐根）deb ----------
if [ "${ROOTHIDE:-1}" = 1 ]; then
  step "打包 RootHide（隐根）Showcase deb"
  R3="$WORK/rootfs-roothide"; APP3="$R3/Applications/Showcase.app"   # 包内路径相对隐根目录
  mkdir -p "$APP3" "$R3/usr/bin" "$R3/usr/share/showcase" "$R3/Library/LaunchDaemons" "$R3/DEBIAN"
  cp "$RH/bin/Showcase" "$RH/bin/CarDisplaySim" "$RH/bin/CarPlay Simulator" "$APP3/"
  cp "$WORK/bin/BTdaemon" "$R3/usr/bin/"
  # 启动项保留 /usr/bin/BTdaemon，安装时 postinst（和程序启动时）换成本机真实路径
  cp "$BT/port/ios/layout/Library/LaunchDaemons/ch.ringwald.BTstack.plist" "$R3/Library/LaunchDaemons/"
  fill_version "$S/Info.plist" > "$APP3/Info.plist"
  for e in ent_app ent_bt ent_svc ent_btdaemon; do cp "$S/$e.xml" "$R3/usr/share/showcase/"; done
  cp "$SC/icon/generated/"*.png "$APP3/"
  cp -R "$S/Localizations/"*.lproj "$APP3/"
  ldid -S"$S/ent_app.xml" "$APP3/Showcase"
  ldid -S"$S/ent_bt.xml"  "$APP3/CarDisplaySim"
  ldid -S"$S/ent_svc.xml" "$APP3/CarPlay Simulator"
  ldid -S"$S/ent_btdaemon.xml" "$R3/usr/bin/BTdaemon"
  chmod 0755 "$APP3" "$APP3/"*.lproj; chmod 0644 "$APP3/Info.plist" "$APP3/"*.png "$APP3/"*.lproj/*
  chmod 4755 "$APP3/Showcase" "$APP3/CarDisplaySim" "$APP3/CarPlay Simulator"
  chmod 0755 "$R3/usr/bin/BTdaemon"; chmod 0644 "$R3/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
  fill_version "$SC/packaging/control-roothide/control" | sed \
    -e "s#^Name: .*#Name: Showcase · a5 (RootHide)#" \
    -e "s#^Maintainer: .*#Maintainer: a5#" \
    -e "s#^Icon: .*#Icon: ${REPO_URL}icons/showcase.png#" \
    -e "s#^Depiction: .*#Depiction: ${REPO_URL}depictions/cydia.html#" \
    -e "s#^SileoDepiction: .*#SileoDepiction: ${REPO_URL}depictions/sileo.json#" \
    -e "s#^Homepage: .*#Homepage: https://github.com/amineross/showcase#" \
    > "$R3/DEBIAN/control"
  printf ' .\n a5 版：基于开源项目 Showcase (GPL) 改编，仅新增内置证书离线认证。\n' >> "$R3/DEBIAN/control"
  for f in postinst prerm postrm; do cp "$SC/packaging/control-roothide/$f" "$R3/DEBIAN/"; chmod 0755 "$R3/DEBIAN/$f"; done
  find "$R3" \( -name .DS_Store -o -name '._*' \) -delete
  xattr -cr "$R3" 2>/dev/null || true
  (cd "$R3" && find . -path ./DEBIAN -prune -o -type f -print | sed 's#^\./##' | while read -r f; do
     printf '%s  %s\n' "$(md5 -q "$f")" "$f"; done > DEBIAN/md5sums)
  COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b "$R3" \
    "$OUT/debs/com.rostane.showcase_${PACKAGE_VERSION}_iphoneos-arm64e.deb"
fi

# ---------- 4d. 打 Taurine deb（单独的包名 com.rostane.showcase-taurine） ----------
if [ "${TAURINE:-1}" = 1 ] && [ "${ROOTFUL:-1}" = 1 ]; then
  step "打包 Taurine Showcase deb"
  R4="$WORK/rootfs-taurine"; APP4="$R4/Applications/Showcase.app"
  MS="$R4/Library/MobileSubstrate/DynamicLibraries"
  mkdir -p "$APP4" "$R4/usr/bin" "$R4/usr/lib" "$R4/Library/LaunchDaemons" "$MS" "$R4/DEBIAN"
  cp "$TA/bin/Showcase" "$RF/bin/carplay_bt" "$RF/bin/carplay_services" "$APP4/"
  cp "$WORK/bin/BTdaemon" "$R4/usr/bin/"          # btstack-rootless 的新版 BTdaemon（不带 /var/jb 路径）
  cp "$RF/bin/libBTstack.dylib" "$R4/usr/lib/"
  cp "$RF/bin/ch.ringwald.BTstack.plist" "$R4/Library/LaunchDaemons/"
  cp "$TA/bin/BTQuiet.dylib" "$SC/tweak/BTQuiet.plist" "$MS/"
  fill_version "$S/Info.plist" > "$APP4/Info.plist"
  cp "$SC/icon/generated/"*.png "$APP4/"
  cp -R "$S/Localizations/"*.lproj "$APP4/"
  ldid -S"$S/ent_app.xml" "$APP4/Showcase"
  ldid -S"$S/ent_bt.xml"  "$APP4/carplay_bt"
  ldid -S"$S/ent_svc.xml" "$APP4/carplay_services"
  ldid -S"$S/ent_btdaemon.xml" "$R4/usr/bin/BTdaemon"
  ldid -S "$R4/usr/lib/libBTstack.dylib"
  ldid -S "$MS/BTQuiet.dylib"
  chmod 0755 "$APP4" "$APP4/"*.lproj; chmod 0644 "$APP4/Info.plist" "$APP4/"*.png "$APP4/"*.lproj/*
  chmod 4755 "$APP4/Showcase" "$APP4/carplay_bt" "$APP4/carplay_services"
  chmod 0755 "$R4/usr/bin/BTdaemon" "$R4/usr/lib/libBTstack.dylib"
  chmod 0644 "$R4/Library/LaunchDaemons/ch.ringwald.BTstack.plist" "$MS/"*
  fill_version "$SC/packaging/control-taurine/control" | sed \
    -e "s#^Name: .*#Name: Showcase · a5 (Taurine)#" \
    -e "s#^Maintainer: .*#Maintainer: a5#" \
    -e "s#^Icon: .*#Icon: ${REPO_URL}icons/showcase.png#" \
    -e "s#^Depiction: .*#Depiction: ${REPO_URL}depictions/cydia.html#" \
    -e "s#^SileoDepiction: .*#SileoDepiction: ${REPO_URL}depictions/sileo.json#" \
    -e "s#^Homepage: .*#Homepage: https://github.com/amineross/showcase#" \
    > "$R4/DEBIAN/control"
  printf ' .\n a5 版：基于开源项目 Showcase (GPL) 改编，仅新增内置证书离线认证。只适用于 iOS 14 的 Taurine 越狱。\n' >> "$R4/DEBIAN/control"
  for f in postinst prerm postrm; do cp "$SC/packaging/control-taurine/$f" "$R4/DEBIAN/"; chmod 0755 "$R4/DEBIAN/$f"; done
  find "$R4" \( -name .DS_Store -o -name '._*' \) -delete
  xattr -cr "$R4" 2>/dev/null || true
  (cd "$R4" && find . -path ./DEBIAN -prune -o -type f -print | sed 's#^\./##' | while read -r f; do
     printf '%s  %s\n' "$(md5 -q "$f")" "$f"; done > DEBIAN/md5sums)
  COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b "$R4" \
    "$OUT/debs/com.rostane.showcase-taurine_${PACKAGE_VERSION}_iphoneos-arm.deb"
fi

fi  # KEEP_SHOWCASE

# ---------- 5. 打 share deb（程序未改动；比上游多一个隐根包，用它自带 build.sh） ----------
step "打包 share deb"
(cd "$SH" && SDK="$SDK" VERSION_SUFFIX="$DEV" ./build.sh)
cp "$SH"/build/com.rostane.share_*_iphoneos-arm64.deb "$OUT/debs/"
cp "$SH"/build/com.rostane.share_*_iphoneos-arm.deb "$OUT/debs/" 2>/dev/null || true
if [ "${ROOTHIDE:-1}" = 1 ]; then cp "$SH"/build/com.rostane.share_*_iphoneos-arm64e.deb "$OUT/debs/"; fi

# ---------- 6. 生成 a5 源索引 ----------
step "生成 a5 源"
sed -e 's/"Origin: Rostane"/"Origin: a5"/' -e 's/"Label: Rostane"/"Label: a5"/' \
    -e 's#Icon: https://aminerostane.com/repo/CydiaIcon.png#Icon: '"$REPO_URL"'CydiaIcon.png#' \
    -e 's/Description: Rostane jailbreak package repository/Description: a5 · 基于开源项目改编的 Showcase 源/' \
    "$SC/packaging/scripts/generate-apt-repo.py" > "$WORK/gen.py"
cp -R "$SC/packaging/depictions" "$SC/packaging/assets" "$WORK/"     # 生成器按自身位置找 depictions/assets
mkdir -p "$WORK/scripts"; mv "$WORK/gen.py" "$WORK/scripts/gen.py"
python3 "$WORK/scripts/gen.py" "$OUT"
# 源 logo 用 a5 自己的图（site/logo.png），替换上游作者的头像
cp "$TOP/site/logo.png" "$OUT/CydiaIcon.png"; cp "$TOP/site/logo.png" "$OUT/icon.png"; cp "$TOP/site/logo.png" "$OUT/icons/profile.png"
# 包图标用压缩过的小图（上游 1024x1024 原图 1.1MB，Sileo 每次刷新都要下载）
if [ -f "$TOP/site/showcase-icon.png" ]; then cp "$TOP/site/showcase-icon.png" "$OUT/icons/showcase.png"; fi
# 源主页（手机优先）
{ printf '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>body{margin:0}</style></head><body>\n'
  sed "s#https://&lt;部署后填入你的地址&gt;/#${REPO_URL}#" "$TOP/site/index.src.html"
  printf '\n</body></html>\n'; } > "$OUT/index.html"

step "检查打出来的包"
python3 "$TOP/tools/audit-debs.py" "$OUT" --cert "$REAL_CERT" || die "包检查没通过，上面 ✗ 的项目要先修好，不要装到设备上"

step "完成"
ls -la "$OUT/debs"
echo "源目录: $OUT"
echo "iPad 上在 Sileo 添加:  $REPO_URL"

if [ "${NO_SERVE:-0}" != 1 ]; then
  step "本地服务已启动（Ctrl+C 停止）"
  cd "$OUT" && python3 -m http.server "$PORT"
fi
