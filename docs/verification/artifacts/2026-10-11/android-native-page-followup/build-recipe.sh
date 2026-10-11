#!/usr/bin/env bash
set -euo pipefail
abi="$1"
case "$abi" in
  arm64) target=android-arm64; triple=aarch64-linux-android21 ;;
  x86_64) target=android-x86_64; triple=x86_64-linux-android21 ;;
  *) exit 64 ;;
esac
export ANDROID_NDK_HOME=/c/Users/Administrator/AppData/Local/Android/Sdk/ndk/28.2.13676358
export PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin:$ANDROID_NDK_HOME/prebuilt/windows-x86_64/bin:/usr/bin:$PATH"
root="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$root/build-$abi" "$root/install-$abi"
cd "$root/build-$abi"
export PERL5LIB=../perl-support
if [[ "${2:-}" != resume ]]; then
perl ../source/openssl-1.1.1q/Configure "$target" \
  -D__ANDROID_API__=21 no-sctp shared \
  "--prefix=$root/install-$abi" "--openssldir=$root/install-$abi" \
  -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
fi
make -j2 SHLIB_EXT=.so PERL=perl SHELL=C:/Progra~1/Git/usr/bin/sh.exe \
  "CC=clang --target=$triple" build_libs
