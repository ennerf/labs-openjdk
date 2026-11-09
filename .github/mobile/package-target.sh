#!/bin/bash
# Packs the static libraries of one mobile target into <out>/<target>/sdk and
# <out>/graalvm-<version>-<target>-static.zip: the JDK archives native-image links from the
# static-libs-graal bundle that build-android.yml or build-ios.yml uploaded, the GraalVM C
# libraries (svm-libs.sh), the CAP caches (capgen.py) and the legal texts. CI and local builds
# both run this script.
#
# usage: package-target.sh <target> <bundle> <jdk source> <graal source> <out>
#
# GRAALVM_HOME is the GraalVM whose JDK this branch is, its native-image writes the CAP query
# programs. Android needs ANDROID_NDK_HOME.
set -euxo pipefail
target=$1
bundle=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
jdk=$(cd "$3" && pwd)
graal=$(cd "$4" && pwd)
mkdir -p "$5"
out=$(cd "$5" && pwd)
mobile=$(cd "$(dirname "$0")" && pwd)
modules="java.base java.prefs jdk.net jdk.management"
libs="java nio net zip jsig prefs extnet management_ext"
version=$(sed -n 's/^GRAALVM_VERSION="\(.*\)"$/\1/p' "$GRAALVM_HOME/release")
export PATH="$GRAALVM_HOME/bin:$PATH"

case "$target" in
  android-aarch64) ;;
  ios-arm64)
    sdk=iphoneos
    triple=arm64-apple-ios15.0 ;;
  ios-arm64-simulator)
    sdk=iphonesimulator
    triple=arm64-apple-ios15.0-simulator ;;
  *)
    echo "unknown target $target" >&2
    exit 1 ;;
esac

sdk_dir="$out/$target/sdk"
rm -rf "$sdk_dir"
mkdir -p "$sdk_dir/lib" "$sdk_dir/cap"
unpacked=$(mktemp -d)
tar xzf "$bundle" -C "$unpacked"
for l in $libs; do
  cp "$(find "$unpacked" -name "lib$l.a")" "$sdk_dir/lib/"
done
rm -rf "$unpacked"
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
  cflags="--target=aarch64-linux-android28 -I$GRAALVM_HOME/include -I$GRAALVM_HOME/include/linux"
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
