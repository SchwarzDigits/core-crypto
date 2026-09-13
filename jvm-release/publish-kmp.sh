#!/usr/bin/env bash
# Publishes CoreCrypto's Kotlin Multiplatform artifact, schwarz.opensource.natrium:core-crypto-kmp,
# with Wire's Gradle build of this branch into target/jvm-release/maven/ (Maven layout):
#   core-crypto-kmp                     the common metadata
#   core-crypto-kmp-jvm                 the libraries of Linux x86_64 and arm64, macOS arm64, Windows x86_64
#   core-crypto-kmp-android             arm64-v8a, armeabi-v7a, x86_64
#   core-crypto-kmp-iosarm64            iOS devices
#   core-crypto-kmp-iossimulatorarm64   the iOS simulator on Apple silicon
#   core-crypto-kmp-macosarm64          Kotlin/Native on macOS arm64
#
#   VERSION=10.5.2-digits.1 jvm-release/publish-kmp.sh [--m2]
#
# --m2 also copies the publication into the local Maven repository (~/.m2/repository). The native
# libraries come from target/<target>/release, where jvm-release/build.sh puts them; each has to be
# built from the current commit, in a clean and detached checkout. UNRELEASED=1 skips that check, for
# tests. Gradle needs JDK 25 (JAVA_HOME) and the Android SDK (ANDROID_HOME).
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
GROUP=schwarz.opensource.natrium
REPO_URL=https://github.com/SchwarzDigits/core-crypto
TARGETS=(ffi-library aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android
  armv7-linux-androideabi x86_64-linux-android aarch64-unknown-linux-gnu x86_64-pc-windows-gnu
  x86_64-unknown-linux-gnu)
cd "$(dirname "$0")/.."
repo="$(pwd)"

commit="$(git rev-parse HEAD)"
for target in "${TARGETS[@]}"; do
  stamp="$(cat "target/jvm-release/built/$target" 2>/dev/null || true)"
  if [ "$stamp" != "$commit" ] && [ "${UNRELEASED:-}" != 1 ]; then
    echo "$target was built from ${stamp:-an unknown commit}, not $commit; run jvm-release/build.sh $target" >&2
    exit 1
  fi
done

out="$repo/target/jvm-release/maven"
group_dir="$(tr . / <<<"$GROUP")"
rm -rf "$out/$group_dir"/core-crypto-kmp*
(
  cd crypto-ffi/bindings
  RELEASE=1 ./gradlew --console=plain -Dmaven.repo.local="$out" \
    -PGROUP="$GROUP" -PVERSION_NAME="$VERSION" \
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

if [ "${1:-}" = --m2 ]; then
  mkdir -p "$HOME/.m2/repository/$group_dir"
  for dir in "$out/$group_dir"/core-crypto-kmp*; do
    rm -rf "$HOME/.m2/repository/$group_dir/$(basename "$dir")/$VERSION"
    mkdir -p "$HOME/.m2/repository/$group_dir/$(basename "$dir")"
    cp -R "$dir/$VERSION" "$HOME/.m2/repository/$group_dir/$(basename "$dir")/"
  done
fi
find "$out/$group_dir" -path "*core-crypto-kmp*/$VERSION/*" -type f | sed "s|$out/||" | sort
