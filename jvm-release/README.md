# JVM artifact

This branch is Wire's CoreCrypto v10.5.2 with the changes this fork proposes upstream (SchwarzDigits/core-crypto#5, #6
and #7), plus the scripts in this directory. It builds a `core-crypto-jvm` artifact for the JVM target:

- **Coordinates:** `schwarz.opensource.natrium:core-crypto-jvm:10.5.2-digits.N`. `digits` marks the patch set of Schwarz
  Digits on Wire's 10.5.2, and `N` counts its revisions.
- **Kotlin bindings:** Wire's `com.wire:core-crypto-jvm:10.5.2`, unchanged. The natives come from the same release with
  the same features, so the API checksums that the bindings check when they load the library match.
- **Natives:** macOS arm64, Linux x86_64 and arm64 (glibc 2.28 or newer), Windows x86_64 (Windows 10 or newer).
- **Keystore:** SQLite3 Multiple Ciphers in SQLCipher's format, version 4, instead of SQLCipher and OpenSSL. Keystores
  stay interchangeable with Wire's builds.

## Build

`jvm-release/build.sh` builds one native library with the make rules of this branch, as Wire's release build does
(`RELEASE=1`), into `target/<target>/release/`:

```sh
jvm-release/build.sh aarch64-apple-darwin       # on a Mac with rustup
jvm-release/build.sh aarch64-unknown-linux-gnu  # Docker, in the manylinux_2_28 container
jvm-release/build.sh x86_64-unknown-linux-gnu   # Docker, in the manylinux_2_28 container; emulated on Apple silicon
jvm-release/build.sh x86_64-pc-windows-gnu      # Docker, cross-compiled with MinGW
```

On a Linux host of the right architecture, the Linux rules run directly. Otherwise the script runs them in an Ubuntu
container that uses the host's Docker socket for the manylinux container. The containers keep their Rust toolchain under
`target/jvm-release/`. The Rust version is the channel of `rust-toolchain.toml`.

## Package

`jvm-release/package-jar.sh` packs Wire's jar of the same version with the four natives and installs the result into the
local Maven repository (`~/.m2/repository`):

```sh
v=10.5.2
for f in core-crypto-jvm-$v.jar core-crypto-jvm-$v.pom; do
  curl -fsSLO https://repo1.maven.org/maven2/com/wire/core-crypto-jvm/$v/$f
done
VERSION=$v-digits.1 jvm-release/package-jar.sh core-crypto-jvm-$v.jar core-crypto-jvm-$v.pom
```

The manifest of the jar records the commit it was built from, the checksum of Wire's jar and the checksum of each native
library.
