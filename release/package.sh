#!/usr/bin/env bash
# Builds the Maven publication of core-crypto-jvm from Wire's release of the same version and the
# JVM natives of this branch, into target/digits/maven/ and the local Maven repository
# (~/.m2/repository):
#
#   core-crypto-jvm-<version>.jar             Wire's Kotlin classes, byte for byte, the natives of this
#                                             branch, and LICENSE, NOTICE and THIRD_PARTY_NOTICES.txt
#   core-crypto-jvm-<version>-sources.jar     Wire's Kotlin sources, and NATIVE-SOURCES.md
#   core-crypto-jvm-<version>-javadoc.jar     Wire's documentation
#   core-crypto-jvm-<version>.pom             Wire's dependencies, with this project's data
#   core-crypto-jvm-<version>-cyclonedx.json  the SBOM, in CycloneDX 1.5
#
#   VERSION=10.5.2-digits.1 release/package.sh
#
# VERSION is Wire's version with the patch set. Wire's files of that version are downloaded from
# Maven Central into target/digits/wire/ and checked against Central's SHA-512 checksums.
# The natives come from target/<target>/release, where release/build.sh puts them.
#
# A publication needs a clean working tree. UNRELEASED=1 allows local changes, for tests.
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-digits\.[0-9]+$ ]] ||
  { echo "VERSION must be Wire's version with the patch set, e.g. 10.5.2-digits.1" >&2; exit 1; }
WIRE_VERSION="${BASH_REMATCH[1]}"
GROUP=schwarz.opensource.natrium
ARTIFACT=core-crypto-jvm
REPO_URL=https://github.com/SchwarzDigits/core-crypto
cd "$(dirname "$0")/.."

dirty="$(git status --porcelain)"
if [ -n "$dirty" ] && [ "${UNRELEASED:-}" != 1 ]; then
  echo "the working tree has changes; commit them, or set UNRELEASED=1 for a test" >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
date="$(git log -1 --format=%cI)"

natives=(
  "darwin-aarch64/libcore_crypto_ffi.dylib:aarch64-apple-darwin/release/libcore_crypto_ffi.dylib"
  "linux-x86-64/libcore_crypto_ffi.so:x86_64-unknown-linux-gnu/release/libcore_crypto_ffi.so"
  "linux-aarch64/libcore_crypto_ffi.so:aarch64-unknown-linux-gnu/release/libcore_crypto_ffi.so"
  "win32-x86-64/core_crypto_ffi.dll:x86_64-pc-windows-gnu/release/core_crypto_ffi.dll"
)

wire="target/digits/wire/$WIRE_VERSION"
mkdir -p "$wire"
for f in $ARTIFACT-$WIRE_VERSION{.jar,-sources.jar,-javadoc.jar,.pom}; do
  url="https://repo1.maven.org/maven2/com/wire/$ARTIFACT/$WIRE_VERSION/$f"
  for g in "$f" "$f.sha512"; do
    [ -f "$wire/$g" ] || { curl -fsSL -o "$wire/$g.part" "${url%"$f"}$g" && mv "$wire/$g.part" "$wire/$g"; }
  done
  [ "$(cut -d' ' -f1 "$wire/$f.sha512")" = "$(shasum -a 512 "$wire/$f" | cut -d' ' -f1)" ] ||
    { echo "$wire/$f does not match Maven Central's SHA-512" >&2; rm -f "$wire/$f"; exit 1; }
done

out="target/digits/maven/$(tr . / <<<"$GROUP")/$ARTIFACT/$VERSION"
base="$out/$ARTIFACT-$VERSION"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 release/third-party.py notices jvm "$VERSION" "$work/THIRD_PARTY_NOTICES.txt"
cat > "$work/NOTICE" <<EOF
$ARTIFACT $VERSION
Copyright (C) Wire Swiss GmbH
Copyright (C) ${date:0:4} Schwarz Digits KG

This is CoreCrypto by Wire Swiss GmbH (https://github.com/wireapp/core-crypto), release
$WIRE_VERSION, with changes by Schwarz Digits KG. It is licensed under the GNU General Public
License v3.0; see LICENSE.

The Kotlin classes are those of Wire's release com.wire:$ARTIFACT:$WIRE_VERSION, unchanged. The
native libraries are built from $REPO_URL, tag v$VERSION.

The third-party components it contains, and the crates of CoreCrypto under other licences, are
licensed under their own terms. THIRD_PARTY_NOTICES.txt lists them with their licence texts.
The SBOM $ARTIFACT-$VERSION-cyclonedx.json, published next to the jar, lists
them with their versions.
EOF

# The jar: Wire's classes, our natives. Its manifest records where each part comes from.
mkdir "$work/jar"
unzip -q "$wire/$ARTIFACT-$WIRE_VERSION.jar" -d "$work/jar"
rm -rf "$work/jar/darwin-aarch64" "$work/jar/linux-x86-64" "$work/jar/META-INF/MANIFEST.MF"
unknown="$(cd "$work/jar" && find . -name '*core_crypto_ffi*')"
if [ -n "$unknown" ]; then
  echo "Wire's jar has natives this script doesn't know: $unknown" >&2
  exit 1
fi
built=()
{
  echo "Implementation-Title: $ARTIFACT"
  echo "Implementation-Vendor: Schwarz Digits KG"
  echo "Implementation-Version: $VERSION"
  echo "Built-From: $REPO_URL $commit${dirty:+ (dirty)}"
  echo "Kotlin-Bindings-From: com.wire:$ARTIFACT:$WIRE_VERSION sha256=$(shasum -a 256 "$wire/$ARTIFACT-$WIRE_VERSION.jar" | cut -d' ' -f1)"
  for entry in "${natives[@]}"; do
    resource="${entry%%:*}"
    library="target/${entry#*:}"
    triple="${entry#*:}"
    triple="${triple%%/*}"
    [ -f "$library" ] || { echo "missing native library: $library" >&2; exit 1; }
    stamp="$(cat "target/digits/built/$triple" 2>/dev/null || true)"
    if [ "$stamp" != "$commit" ] && [ "${UNRELEASED:-}" != 1 ]; then
      echo "$library was built from ${stamp:-an unknown commit}, not $commit; run release/build.sh $triple" >&2
      exit 1
    fi
    mkdir -p "$work/jar/$(dirname "$resource")"
    cp "$library" "$work/jar/$resource"
    echo "Native-SHA256-$(dirname "$resource"): $(shasum -a 256 "$library" | cut -d' ' -f1)"
  done
} > "$work/manifest.txt"
for entry in "${natives[@]}"; do built+=("${entry%%:*}=target/${entry#*:}"); done
cp LICENSE "$work/NOTICE" "$work/THIRD_PARTY_NOTICES.txt" "$work/jar/META-INF/"
jar --create --date="$date" --file "$base.jar" --manifest "$work/manifest.txt" -C "$work/jar" .

mkdir "$work/sources"
unzip -q "$wire/$ARTIFACT-$WIRE_VERSION-sources.jar" -d "$work/sources"
rm -f "$work/sources/META-INF/MANIFEST.MF"
mkdir -p "$work/sources/META-INF"
cp LICENSE "$work/NOTICE" "$work/sources/META-INF/"
cat > "$work/sources/NATIVE-SOURCES.md" <<EOF
# Native sources

The native libraries in $ARTIFACT-$VERSION.jar are built from the Rust sources of $REPO_URL, tag
v$VERSION (commit $commit), with \`release/build.sh\`. That tag is Wire's CoreCrypto v$WIRE_VERSION
with the changes of Schwarz Digits, which \`release/README.md\` describes. The manifest of the jar
records the SHA-256 of each library.

The Kotlin sources in this jar are those of Wire's release com.wire:$ARTIFACT:$WIRE_VERSION.
EOF
jar --create --date="$date" --file "$base-sources.jar" -C "$work/sources" .

mkdir "$work/javadoc"
unzip -q "$wire/$ARTIFACT-$WIRE_VERSION-javadoc.jar" -d "$work/javadoc"
rm -f "$work/javadoc/META-INF/MANIFEST.MF"
mkdir -p "$work/javadoc/META-INF"
cp LICENSE "$work/NOTICE" "$work/javadoc/META-INF/"
jar --create --date="$date" --file "$base-javadoc.jar" -C "$work/javadoc" .

# Wire's POM with this project's data in place of Wire's; the dependencies stay as they are. There
# is no Gradle module metadata here, so Wire's note about it goes.
cat > "$work/project.xml" <<EOF
  <modelVersion>4.0.0</modelVersion>
  <groupId>$GROUP</groupId>
  <artifactId>$ARTIFACT</artifactId>
  <version>$VERSION</version>
  <name>$ARTIFACT</name>
  <description>CoreCrypto for the JVM target, a fork of wireapp/core-crypto with native libraries for Linux x86_64 and arm64 (glibc 2.28 or newer), macOS arm64 and Windows x86_64</description>
  <url>$REPO_URL</url>
  <licenses>
    <license>
      <name>GNU General Public License v3.0</name>
      <url>https://www.gnu.org/licenses/gpl-3.0.html</url>
      <distribution>repo</distribution>
    </license>
  </licenses>
  <developers>
    <developer>
      <id>schwarzdigits</id>
      <name>Schwarz Digits</name>
      <organization>Schwarz Digits KG</organization>
      <organizationUrl>https://schwarz-it.com</organizationUrl>
    </developer>
  </developers>
  <scm>
    <url>$REPO_URL</url>
    <connection>scm:git:git://github.com/SchwarzDigits/core-crypto.git</connection>
    <developerConnection>scm:git:ssh://git@github.com/SchwarzDigits/core-crypto.git</developerConnection>
  </scm>
EOF
PROJECT="$(cat "$work/project.xml")" perl -0pe '
  s|\s*<!--.*?-->||gs;
  s|\s*<modelVersion>.*?</scm>|\n$ENV{PROJECT}|s;
' "$wire/$ARTIFACT-$WIRE_VERSION.pom" > "$base.pom"

python3 release/third-party.py sbom jvm "$VERSION" "$base-cyclonedx.json" "$base.pom" "$base.jar" "${built[@]}"
python3 release/check.py "$VERSION"

m2="$HOME/.m2/repository/$(tr . / <<<"$GROUP")/$ARTIFACT/$VERSION"
rm -rf "$m2"
mkdir -p "$m2"
cp "$out"/* "$m2/"
echo "publication: $out"
echo "installed:   $m2"
