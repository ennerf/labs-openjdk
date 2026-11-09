#!/bin/bash
# Builds the static mobile libraries of one target into <out>/<target>/sdk and packs them as
# <out>/graalvm-<version>-<target>-static.zip: the JDK archives of the module targets, the GraalVM
# C libraries (svm-libs.sh), the CAP caches (capgen.py) and the legal texts. CI and local builds
# both run this script.
#
# usage: build-target.sh <target> <jdk source> <graal source> <out>
#
# GRAALVM_HOME is the GraalVM whose JDK this branch is: the boot JDK, and native-image for the CAP
# query programs. Android needs ANDROID_NDK_HOME, iOS needs CUPS_INCLUDE, a CUPS source tree,
# because configure wants its headers even for a headless build.
set -euxo pipefail
target=$1
jdk=$(cd "$2" && pwd)
graal=$(cd "$3" && pwd)
mkdir -p "$4"
out=$(cd "$4" && pwd)
mobile=$(cd "$(dirname "$0")" && pwd)
modules="java.base java.prefs jdk.net jdk.management"
libs="java nio net zip jsig prefs extnet management_ext"
version=$(sed -n 's/^GRAALVM_VERSION="\(.*\)"$/\1/p' "$GRAALVM_HOME/release")
export PATH="$GRAALVM_HOME/bin:$PATH"

case "$target" in
  android-aarch64) ;;
  ios-arm64)
    sdk=iphoneos
    min=-miphoneos-version-min=15.0
    triple=arm64-apple-ios15.0 ;;
  ios-arm64-simulator)
    sdk=iphonesimulator
    min=-mios-simulator-version-min=15.0
    triple=arm64-apple-ios15.0-simulator ;;
  *)
    echo "unknown target $target" >&2
    exit 1 ;;
esac

# The whole static-libs-image does not build on Android (libsaproc needs API 28), the module targets do
common=(--with-conf-name="$target" --enable-headless-only --with-boot-jdk="$GRAALVM_HOME" --with-jvm-variants=minimal
  --disable-warnings-as-errors --with-native-debug-symbols=none --disable-precompiled-headers)
cd "$jdk"
if [ "$target" = android-aarch64 ]; then
  toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
  bash configure "${common[@]}" --with-toolchain-type=clang --with-toolchain-path="$toolchain/bin" \
    --with-sysroot="$toolchain/sysroot" --build=x86_64-pc-linux-gnu --host=aarch64-linux-android --target=aarch64-linux-android
else
  bash configure "${common[@]}" --openjdk-target=aarch64-macos-ios --with-cups-include="$CUPS_INCLUDE" \
    --with-sysroot="$(xcrun --sdk $sdk --show-sdk-path)" --with-extra-cflags=$min --with-extra-cxxflags=$min --with-extra-ldflags=$min
fi
make CONF="$target" $(for m in $modules; do echo $m-static-libs; done)
cd - > /dev/null

sdk_dir="$out/$target/sdk"
rm -rf "$sdk_dir"
mkdir -p "$sdk_dir/lib" "$sdk_dir/cap"
for l in $libs; do
  cp "$jdk"/build/$target/support/native/*/lib$l/static/lib$l.a "$sdk_dir/lib/"
done
bash "$mobile/svm-libs.sh" "$target" "$graal" "$jdk" "$sdk_dir/lib"

# The CAP caches are generated without running anything on the target: native-image writes the
# query programs and capgen.py compiles them for the target, reading the values back from the IR.
# Android images only build on a Linux host, so the cross-arch FFM ABI comes from CABI
probe=$(mktemp -d)
mkdir -p "$probe/classes"
javac -d "$probe/classes" "$mobile/Probe.java"
if [ "$target" = android-aarch64 ]; then
  platform=ANDROID_AARCH64
  target_args="-Dsvm.targetArch=aarch64 -J-Djdk.internal.foreign.CABI=LINUX_AARCH_64"
  clang="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  cflags="--target=aarch64-linux-android24 -I$GRAALVM_HOME/include -I$GRAALVM_HOME/include/linux"
else
  platform=IOS_AARCH64
  target_args="-Dsvm.targetName=iOS -Dsvm.targetArch=arm64 -H:PageSize=16384"
  clang=$(xcrun -sdk $sdk -f clang)
  cflags="-ObjC -target $triple -isysroot $(xcrun --sdk $sdk --show-sdk-path) -I$GRAALVM_HOME/include -I$GRAALVM_HOME/include/darwin"
fi
(cd "$probe" && native-image --shared -cp classes -o probe "-Dsvm.platform=org.graalvm.nativeimage.Platform\$$platform" $target_args \
  -H:+UnlockExperimentalVMOptions -H:+ForeignAPISupport -H:+ExitAfterQueryCodeGeneration -H:QueryCodeDir="$probe/query")
python3 "$mobile/capgen.py" "$clang" "$probe/query" "$probe/cap" $cflags
cp "$probe"/cap/*.cap "$sdk_dir/cap/"
rm -rf "$probe"

for m in $modules; do
  mkdir -p "$sdk_dir/legal/$m"
  cp "$jdk/LICENSE" "$jdk/ASSEMBLY_EXCEPTION" "$jdk/ADDITIONAL_LICENSE_INFO" "$sdk_dir/legal/$m/"
  for d in share unix; do
    if [ -d "$jdk/src/$m/$d/legal" ]; then cp "$jdk"/src/$m/$d/legal/* "$sdk_dir/legal/$m/"; fi
  done
done
mkdir -p "$sdk_dir/legal/substratevm"
cp "$graal/substratevm/LICENSE" "$sdk_dir/legal/substratevm/"

zip_name="graalvm-$version-$target-static.zip"
rm -f "$out/$zip_name"
(cd "$out/$target" && zip -qr "../$zip_name" sdk)
ls -l "$sdk_dir/lib" "$sdk_dir/cap" "$out/$zip_name"
