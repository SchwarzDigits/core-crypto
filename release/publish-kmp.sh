#!/usr/bin/env bash
# Publishes CoreCrypto's Kotlin Multiplatform artifact, schwarz.opensource.natrium:core-crypto-kmp,
# with Wire's Gradle build of this branch into target/digits/maven/ (Maven layout):
#   core-crypto-kmp                     the common module
#   core-crypto-kmp-jvm                 the libraries of Linux x86_64 and arm64, macOS arm64, Windows x86_64
#   core-crypto-kmp-android             arm64-v8a, armeabi-v7a, x86_64
#   core-crypto-kmp-iosarm64            iOS devices
#   core-crypto-kmp-iossimulatorarm64   the iOS simulator on Apple silicon
#   core-crypto-kmp-macosarm64          Kotlin/Native on macOS arm64
# Each module gets its SBOM, <module>-<version>-cyclonedx.json. The jvm jar and the aar carry LICENSE,
# NOTICE and THIRD_PARTY_NOTICES.txt in META-INF/core-crypto-kmp/; the klib modules get the notices
# next to them, <module>-<version>-third-party-notices.txt.
#
#   VERSION=10.5.2-digits.1 release/publish-kmp.sh [--m2]
#
# --m2 also copies the publication into the local Maven repository (~/.m2/repository). The native
# libraries come from target/<target>/release, where release/build.sh puts them; each has to be
# built from the current commit, in a clean and detached checkout. UNRELEASED=1 skips that check, for
# tests. Gradle needs JDK 25 (JAVA_HOME) and the Android SDK (ANDROID_HOME).
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-digits\.[0-9]+$ ]] ||
  { echo "VERSION must be Wire's version with the patch set, e.g. 10.5.2-digits.1" >&2; exit 1; }
WIRE_VERSION="${BASH_REMATCH[1]}"
GROUP=schwarz.opensource.natrium
REPO_URL=https://github.com/SchwarzDigits/core-crypto
TARGETS=(ffi-library aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android
  armv7-linux-androideabi x86_64-linux-android aarch64-unknown-linux-gnu x86_64-pc-windows-gnu
  x86_64-unknown-linux-gnu)
cd "$(dirname "$0")/.."
repo="$(pwd)"

commit="$(git rev-parse HEAD)"
for target in "${TARGETS[@]}"; do
  stamp="$(cat "target/digits/built/$target" 2>/dev/null || true)"
  if [ "$stamp" != "$commit" ] && [ "${UNRELEASED:-}" != 1 ]; then
    echo "$target was built from ${stamp:-an unknown commit}, not $commit; run release/build.sh $target" >&2
    exit 1
  fi
done

notice() {
  cat <<EOF
core-crypto-kmp $VERSION
Copyright (C) Wire Swiss GmbH
Copyright (C) $(git log -1 --format=%cd --date=format:%Y) Schwarz Digits KG

This is CoreCrypto by Wire Swiss GmbH (https://github.com/wireapp/core-crypto), release
$WIRE_VERSION, with changes by Schwarz Digits KG, built from $REPO_URL,
tag v$VERSION. It is licensed under the GNU General Public License v3.0; see LICENSE.

The third-party components it contains, and the crates of CoreCrypto under other licences, are
licensed under their own terms. THIRD_PARTY_NOTICES.txt lists them with their licence texts. Each
module of core-crypto-kmp has its SBOM next to it, <module>-$VERSION-cyclonedx.json.
EOF
}

# The licence files of the jvm jar and the aar, which Gradle adds as resources (-PnoticesDir).
notices="$repo/target/digits/notices"
rm -rf "$notices"
for variant in jvm android; do
  dir="$notices/$variant/META-INF/core-crypto-kmp"
  mkdir -p "$dir"
  cp LICENSE "$dir/"
  notice > "$dir/NOTICE"
  python3 release/third-party.py notices "core-crypto-kmp-$variant" "$VERSION" "$dir/THIRD_PARTY_NOTICES.txt"
done

out="$repo/target/digits/maven"
group_dir="$(tr . / <<<"$GROUP")"
rm -rf "$out/$group_dir"/core-crypto-kmp*
(
  cd crypto-ffi/bindings
  RELEASE=1 ./gradlew --console=plain -Dmaven.repo.local="$out" \
    -PGROUP="$GROUP" -PVERSION_NAME="$VERSION" -PnoticesDir="$notices" \
    -PPOM_NAME=CoreCrypto \
    -PPOM_DESCRIPTION="CoreCrypto for Kotlin Multiplatform, a fork of wireapp/core-crypto: Android, iOS, and the JVM on Linux x86_64 and arm64 (glibc 2.28 or newer), macOS arm64 and Windows x86_64" \
    -PPOM_URL="$REPO_URL" \
    -PPOM_LICENSE_NAME="GNU General Public License v3.0" \
    -PPOM_LICENSE_URL=https://www.gnu.org/licenses/gpl-3.0.html \
    -PPOM_LICENSE_DIST=repo \
    -PPOM_SCM_URL="$REPO_URL" \
    -PPOM_SCM_CONNECTION=scm:git:git://github.com/SchwarzDigits/core-crypto.git \
    -PPOM_SCM_DEV_CONNECTION=scm:git:ssh://git@github.com/SchwarzDigits/core-crypto.git \
    -PPOM_DEVELOPER_NAME="Schwarz Digits" \
    -PPOM_DEVELOPER_EMAIL=opensource@digits.schwarz \
    :core-crypto-kmp:publishToMavenLocal
)

# The SBOM of each module, with the native libraries in it, and the notices of the klib modules.
sbom() {
  local module="$1" stem="$out/$group_dir/$1/$VERSION/$1-$VERSION"
  local artifact="$stem$2"
  shift 2
  python3 release/third-party.py sbom "$module" "$VERSION" "$stem-cyclonedx.json" "$stem.pom" "$artifact" "$@"
}
sbom core-crypto-kmp .jar
sbom core-crypto-kmp-jvm .jar \
  linux-x86-64/libcore_crypto_ffi.so=target/x86_64-unknown-linux-gnu/release/libcore_crypto_ffi.so \
  linux-aarch64/libcore_crypto_ffi.so=target/aarch64-unknown-linux-gnu/release/libcore_crypto_ffi.so \
  darwin-aarch64/libcore_crypto_ffi.dylib=target/aarch64-apple-darwin/release/libcore_crypto_ffi.dylib \
  win32-x86-64/core_crypto_ffi.dll=target/x86_64-pc-windows-gnu/release/core_crypto_ffi.dll
sbom core-crypto-kmp-android .aar \
  jni/arm64-v8a/libcore_crypto_ffi.so=target/aarch64-linux-android/release/libcore_crypto_ffi.so \
  jni/armeabi-v7a/libcore_crypto_ffi.so=target/armv7-linux-androideabi/release/libcore_crypto_ffi.so \
  jni/x86_64/libcore_crypto_ffi.so=target/x86_64-linux-android/release/libcore_crypto_ffi.so
for entry in iosarm64:aarch64-apple-ios iossimulatorarm64:aarch64-apple-ios-sim macosarm64:aarch64-apple-darwin; do
  module="core-crypto-kmp-${entry%%:*}"
  sbom "$module" .klib "libcore_crypto_ffi.a=target/${entry#*:}/release/libcore_crypto_ffi.a"
  python3 release/third-party.py notices "$module" "$VERSION" \
    "$out/$group_dir/$module/$VERSION/$module-$VERSION-third-party-notices.txt"
done
python3 release/check.py "$VERSION"

if [ "${1:-}" = --m2 ]; then
  mkdir -p "$HOME/.m2/repository/$group_dir"
  for dir in "$out/$group_dir"/core-crypto-kmp*; do
    rm -rf "$HOME/.m2/repository/$group_dir/$(basename "$dir")/$VERSION"
    mkdir -p "$HOME/.m2/repository/$group_dir/$(basename "$dir")"
    cp -R "$dir/$VERSION" "$HOME/.m2/repository/$group_dir/$(basename "$dir")/"
  done
fi
find "$out/$group_dir" -path "*core-crypto-kmp*/$VERSION/*" -type f | sed "s|$out/||" | sort
