#!/usr/bin/env bash
# Packs Wire's core-crypto-jvm jar of the same version with the JVM natives of this branch into
# one jar, and installs it into the local Maven repository (~/.m2/repository).
#
# The Kotlin classes stay Wire's, byte for byte. The natives replace Wire's and add two platforms:
#   darwin-aarch64/libcore_crypto_ffi.dylib   aarch64-apple-darwin
#   linux-x86-64/libcore_crypto_ffi.so        x86_64-unknown-linux-gnu
#   linux-aarch64/libcore_crypto_ffi.so       aarch64-unknown-linux-gnu
#   win32-x86-64/core_crypto_ffi.dll          x86_64-pc-windows-gnu
# They come from target/<target>/release, where jvm-release/build.sh puts them.
#
#   VERSION=10.5.2-digits.1 jvm-release/package-jar.sh <Wire's core-crypto-jvm jar> <its pom>
# GROUP defaults to schwarz.opensource.natrium.
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
GROUP="${GROUP:-schwarz.opensource.natrium}"
WIRE_JAR="$1"
WIRE_POM="$2"
ARTIFACT=core-crypto-jvm
repo="$(cd "$(dirname "$0")/.." && pwd)"

natives=(
  "darwin-aarch64/libcore_crypto_ffi.dylib:aarch64-apple-darwin/release/libcore_crypto_ffi.dylib"
  "linux-x86-64/libcore_crypto_ffi.so:x86_64-unknown-linux-gnu/release/libcore_crypto_ffi.so"
  "linux-aarch64/libcore_crypto_ffi.so:aarch64-unknown-linux-gnu/release/libcore_crypto_ffi.so"
  "win32-x86-64/core_crypto_ffi.dll:x86_64-pc-windows-gnu/release/core_crypto_ffi.dll"
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/jar"
unzip -q "$WIRE_JAR" -d "$work/jar"
rm -rf "$work/jar/darwin-aarch64" "$work/jar/linux-x86-64" "$work/jar/META-INF/MANIFEST.MF"

{
  echo "Implementation-Title: core-crypto-jvm with JVM natives"
  echo "Implementation-Version: $VERSION"
  echo "Built-From: https://github.com/SchwarzDigits/core-crypto $(git -C "$repo" rev-parse HEAD)$(git -C "$repo" diff --quiet HEAD || echo ' (dirty)')"
  echo "Kotlin-Bindings-From: $(basename "$WIRE_JAR") sha256=$(shasum -a 256 "$WIRE_JAR" | cut -d' ' -f1)"
  for entry in "${natives[@]}"; do
    resource="${entry%%:*}"
    built="$repo/target/${entry#*:}"
    [ -f "$built" ] || { echo "missing native library: $built" >&2; exit 1; }
    mkdir -p "$work/jar/$(dirname "$resource")"
    cp "$built" "$work/jar/$resource"
    echo "Native-SHA256-$(dirname "$resource"): $(shasum -a 256 "$built" | cut -d' ' -f1)"
  done
} > "$work/manifest.txt"

m2="$HOME/.m2/repository/$(echo "$GROUP" | tr . /)/$ARTIFACT/$VERSION"
mkdir -p "$m2"
jar --create --file "$m2/$ARTIFACT-$VERSION.jar" --manifest "$work/manifest.txt" -C "$work/jar" .

# Wire's POM with our coordinates: the first groupId and version are the project's own; its
# dependencies stay as they are. There is no Gradle module metadata, so its marker goes.
GROUP="$GROUP" VERSION="$VERSION" perl -0pe '
  s|<groupId>com\.wire</groupId>|<groupId>$ENV{GROUP}</groupId>|;
  s|<version>[^<]*</version>|<version>$ENV{VERSION}</version>|;
  s|[ \t]*<!-- do_not_remove: published-with-gradle-metadata -->\n||;
' "$WIRE_POM" > "$m2/$ARTIFACT-$VERSION.pom"

unzip -l "$m2/$ARTIFACT-$VERSION.jar" | grep -E 'core_crypto_ffi|MANIFEST'
echo "installed: $m2"
