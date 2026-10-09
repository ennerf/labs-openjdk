#!/bin/bash
# Builds the GraalVM C libraries a native image links against for one mobile target, with the
# flags mx uses: libchelper, libjvm (JvmFuncs.c plus fallbacks for every JVM_ symbol the JDK
# archives in <out> need) and libsvm_container (Android) or libdarwin (iOS).
#
# usage: svm-libs.sh <target> <graal source> <jdk source> <out>
set -euo pipefail
target=$1
S=$2/substratevm/src
JDK=$3
out=$4
work=$(mktemp -d)

case "$target" in
  android-aarch64)
    bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    CC="$bin/clang --target=aarch64-linux-android24"
    CXX="$bin/clang++ --target=aarch64-linux-android24"
    AR="$bin/llvm-ar"
    NM="$bin/llvm-nm"
    os=linux ;;
  ios-arm64)
    CC="xcrun -sdk iphoneos clang -target arm64-apple-ios15.0"
    AR="xcrun ar"
    NM="xcrun nm"
    os=darwin ;;
  ios-arm64-simulator)
    CC="xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator"
    AR="xcrun ar"
    NM="xcrun nm"
    os=darwin ;;
  *)
    echo "unknown target $target" >&2
    exit 1 ;;
esac
JNI="-I$JDK/src/java.base/share/native/include -I$JDK/src/java.base/unix/native/include"
CHELPER_INCLUDE="-I$S/com.oracle.svm.native.libchelper/include"

mkdir -p "$work/chelper"
for f in "$S"/com.oracle.svm.native.libchelper/src/*.c; do
  $CC -g -fPIC -O2 -D_LITTLE_ENDIAN -ffunction-sections -fdata-sections -fvisibility=hidden -D_FORTIFY_SOURCE=0 \
    $CHELPER_INCLUDE $JNI -c "$f" -o "$work/chelper/$(basename "$f" .c).o"
done
$AR rcs "$out/liblibchelper.a" "$work"/chelper/*.o

mkdir -p "$work/jvm"
J=$S/com.oracle.svm.native.jvm.posix/src/JvmFuncs.c
for a in "$out"/lib*.a; do $NM -u "$a"; done | grep -o "JVM_[A-Za-z0-9_]*" | sort -u > "$work/jvm-needed.txt"
grep -o "JNICALL JVM_[A-Za-z0-9_]*" "$J" | sed "s/JNICALL //" | sort -u > "$work/jvm-impl.txt"
comm -23 "$work/jvm-needed.txt" "$work/jvm-impl.txt" > "$work/jvm-fallbacks.txt"
python3 "$(dirname "$0")/jvm-fallbacks.py" "$work/jvm-fallbacks.txt" "$work/jvm/JvmFuncsFallbacks.c"
for f in "$J" "$work/jvm/JvmFuncsFallbacks.c"; do
  $CC -g -fPIC -O2 -ffunction-sections -fdata-sections -fvisibility=hidden -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE \
    $CHELPER_INCLUDE $JNI -c "$f" -o "$work/jvm/$(basename "$f" .c).o"
done
$AR rcs "$out/libjvm.a" "$work"/jvm/*.o
echo "$(wc -l < "$work/jvm-fallbacks.txt") JVM_ fallbacks"

if [ "$os" = linux ]; then
  # HotSpot's cgroup code
  mkdir -p "$work/container"
  C=$S/com.oracle.svm.native.libcontainer/src
  find "$C" -name "*.cpp" | while read -r f; do
    $CXX -O2 -fno-rtti -fno-exceptions -fvisibility=hidden -fPIC -DNATIVE_IMAGE -DLINUX -DINCLUDE_SUFFIX_COMPILER=_gcc \
      -I"$C/java.base/share/native/include" -I"$C/java.base/unix/native/include" -I"$C/hotspot" -I"$C/hotspot/share" \
      -I"$C/hotspot/os/linux" -I"$C/hotspot/os/posix" -I"$C/hotspot/os/posix/include" -I"$C/svm" -I"$C/svm/share" \
      -std=c++14 -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -D__STDC_CONSTANT_MACROS \
      -c "$f" -o "$work/container/$(echo "${f#$C/}" | sed 's|/|_|g; s|\.cpp$|.o|')"
  done
  $AR rcs "$out/libsvm_container.a" "$work"/container/*.o
else
  mkdir -p "$work/darwin"
  for f in "$S"/com.oracle.svm.native.darwin/src/*.c; do
    $CC -ObjC -fPIC -O1 -D_LITTLE_ENDIAN -ffunction-sections -fdata-sections -fvisibility=hidden -D_FORTIFY_SOURCE=0 \
      $JNI -c "$f" -o "$work/darwin/$(basename "$f" .c).o"
  done
  $AR rcs "$out/libdarwin.a" "$work"/darwin/*.o
fi
