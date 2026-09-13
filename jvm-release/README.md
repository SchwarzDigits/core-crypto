# JVM artifact

This branch is Wire's CoreCrypto v10.5.2 with the changes proposed upstream in wireapp/core-crypto#2582, #2583 and
#2584, plus the scripts in this directory. It builds a `core-crypto-jvm` artifact for the JVM target:

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
`target/jvm-release/`. The Rust version is the channel of `rust-toolchain.toml`. The script records the commit it built
from in `target/jvm-release/built/<target>`.

The builds are reproducible. `SOURCE_DATE_EPOCH` is the commit time, the paths of the Rust sources outside the
repository are remapped, and the make rules always run, so cargo decides what to rebuild. CoreCrypto also embeds the
branch name and `git describe`, so a release is built from a detached checkout of its tag. Anyone who checks out the tag
and runs `build.sh` gets the libraries whose checksums the jar's manifest lists.

## Package

`jvm-release/package.sh` builds the Maven publication into `target/jvm-release/maven/` and installs it into the local
Maven repository (`~/.m2/repository`):

```sh
VERSION=10.5.2-digits.1 jvm-release/package.sh
```

- **`.jar`:** Wire's Kotlin classes, byte for byte, the four natives, and `META-INF/LICENSE`, `NOTICE` and
  `THIRD_PARTY_NOTICES.txt`.
- **`-sources.jar`:** Wire's Kotlin sources, and `NATIVE-SOURCES.md`, which names the tag the natives are built from.
- **`-javadoc.jar`:** Wire's documentation.
- **`.pom`:** Wire's dependencies, with this project's name, description, licence, developer and repository.
- **`-cyclonedx.json`:** the SBOM, in CycloneDX 1.5.

The script downloads Wire's files of the same version from Maven Central into `target/jvm-release/wire/` and checks them
against Central's SHA-512. It packages the natives only if `build.sh` built them from the current commit, and only from
a working tree without changes. `UNRELEASED=1` skips both checks for a test build; the manifest then says `(dirty)`.

The manifest of the jar records the commit, the checksum of Wire's jar and the checksum of each native library. At the
end, `jvm-release/check.py` compares the publication with Wire's release and checks the POM and the SBOM.

## Kotlin Multiplatform

`jvm-release/publish-kmp.sh` publishes `schwarz.opensource.natrium:core-crypto-kmp` with Wire's Gradle build of this
branch into `target/jvm-release/maven/`; `--m2` also copies it into `~/.m2/repository`:

```sh
VERSION=10.5.2-digits.1 jvm-release/publish-kmp.sh --m2
```

- **jvm:** the libraries of Linux x86_64 and arm64, macOS arm64 and Windows x86_64, in the directories where JNA looks
  for them. Wire's `core-crypto-kmp-jvm` carries none: Gobley puts the host's library into a separate jar that the
  published metadata doesn't name.
- **android:** arm64-v8a, armeabi-v7a and x86_64. The keystore uses SQLCipher and OpenSSL, as in Wire's build.
- **iosarm64, iossimulatorarm64:** the static libraries in the cinterop klibs, also with SQLCipher and OpenSSL.
- **macosarm64:** Kotlin/Native on macOS, with SQLite3 Multiple Ciphers.

The script needs the ten libraries of `build.sh`, built from the current commit: the four JVM ones, the three Android
ones (with the NDK in `ANDROID_NDK_HOME`), the two iOS ones (with Xcode) and `ffi-library`, the host library Gradle
generates the Kotlin bindings from. Gradle needs JDK 25 (`JAVA_HOME`) and the Android SDK (`ANDROID_HOME`).

## Licences and SBOM

`jvm-release/third-party.py` lists what an artifact contains:

- the Rust crates linked into `core-crypto-ffi` for the artifact's targets (`cargo tree`, normal dependencies without
  proc-macros, which only run at build time),
- the C libraries these crates compile in,
- for the SBOM, also Wire's Kotlin bindings and the Maven dependencies of the POM.

`THIRD_PARTY_NOTICES.txt` has the licence texts of the crates and C libraries: each crate's own licence files, or the
standard text in `jvm-release/licenses/` for crates that ship none. The crates of CoreCrypto under GPL-3.0 are the
artifact itself and aren't listed.

The script also knows the Android and iOS artifacts, which contain SQLCipher and OpenSSL instead of SQLite3 Multiple
Ciphers:

```sh
jvm-release/third-party.py notices android 10.5.2-digits.1 THIRD_PARTY_NOTICES.txt
```

## Publish

1. Tag the commit as `v10.5.2-digits.1` and push the tag to SchwarzDigits/core-crypto. `NATIVE-SOURCES.md` and the
   notices refer to it.

1. Check out the tag (`git switch --detach v10.5.2-digits.1`), build the four natives, then run `package.sh`.

1. Sign and bundle, in a terminal, since GnuPG asks for the passphrase:

   ```sh
   VERSION=10.5.2-digits.1 SIGNING_KEY=<key id> jvm-release/bundle.sh
   ```

   It checks that the tag points at the commit in the manifest, signs each file, adds MD5, SHA-1, SHA-256 and SHA-512
   checksums, runs `check.py --signed` and writes `target/jvm-release/core-crypto-jvm-<version>-bundle.zip`.

1. Upload the bundle in the [Central Portal](https://central.sonatype.com/publishing) ("Publish Component"), wait for
   the validation, and publish. Central checks the signatures against the public key on a key server such as
   keys.openpgp.org.
