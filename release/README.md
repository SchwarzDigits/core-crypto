# Release

This branch is Wire's CoreCrypto v10.5.2 with the changes proposed upstream in wireapp/core-crypto#2582, #2583 and
#2584, plus the scripts in this directory. It builds `schwarz.opensource.natrium:core-crypto-kmp`, CoreCrypto for Kotlin
Multiplatform:

- **Coordinates:** `schwarz.opensource.natrium:core-crypto-kmp:10.5.2-digits.N`. `digits` marks the patch set of Schwarz
  Digits on Wire's 10.5.2, and `N` counts its revisions.
- **Platforms:** the JVM on Linux x86_64 and arm64 (glibc 2.28 or newer), macOS arm64 and Windows x86_64 (Windows 10 or
  newer); Android (arm64-v8a, armeabi-v7a, x86_64); iOS devices and the simulator on Apple silicon; Kotlin/Native on
  macOS arm64.
- **Keystore:** on the JVM and macOS, SQLite3 Multiple Ciphers in SQLCipher's format, version 4, instead of SQLCipher
  and OpenSSL; keystores stay interchangeable with Wire's builds. Android and iOS keep SQLCipher and OpenSSL, as in
  Wire's build.

## Build

`release/build.sh` builds one native library with the make rules of this branch, as Wire's release build does
(`RELEASE=1`), into `target/<target>/release/`. The publication needs ten:

```sh
release/build.sh ffi-library                # the host library the Kotlin bindings are generated from
release/build.sh aarch64-apple-darwin       # on a Mac with rustup
release/build.sh aarch64-unknown-linux-gnu  # Docker, in the manylinux_2_28 container
release/build.sh x86_64-unknown-linux-gnu   # Docker, in the manylinux_2_28 container; emulated on Apple silicon
release/build.sh x86_64-pc-windows-gnu      # Docker, cross-compiled with MinGW
release/build.sh aarch64-linux-android      # likewise armv7-linux-androideabi and x86_64-linux-android; the NDK
release/build.sh aarch64-apple-ios          # likewise aarch64-apple-ios-sim; on a Mac with Xcode
```

On a Linux host of the right architecture, the Linux rules run directly. Otherwise the script runs them in an Ubuntu
container that uses the host's Docker socket for the manylinux container. The containers keep their Rust toolchain under
`target/digits/`. The Android builds need the NDK in `ANDROID_NDK_HOME`. The Rust version is the channel of
`rust-toolchain.toml`. The script records the commit it built from in `target/digits/built/<target>`.

The iOS libraries are built without `cancellable-transactions`, which Wire's make rules add for the Swift package. The
feature adds a variant to `CoreCryptoError`, and the Kotlin bindings, generated from `ffi-library` without it, couldn't
read the errors of such a library.

The builds are reproducible. `SOURCE_DATE_EPOCH` is the commit time, the paths of the Rust sources outside the
repository are remapped, and the make rules always run, so cargo decides what to rebuild. CoreCrypto also embeds the
branch name and `git describe`, so a release is built from a detached checkout of its tag. Anyone who checks out the tag
and runs `build.sh` gets the libraries whose checksums the SBOMs list.

## Publication

`release/publish-kmp.sh` publishes core-crypto-kmp with Wire's Gradle build of this branch into `target/digits/maven/`;
`--m2` also copies it into `~/.m2/repository`:

```sh
VERSION=10.5.2-digits.1 release/publish-kmp.sh --m2
```

- **`core-crypto-kmp`:** the common module, which names the platform modules.
- **`core-crypto-kmp-jvm`:** the four JVM libraries, in the directories where JNA looks for them. Wire's
  `core-crypto-kmp-jvm` carries none: Gobley puts the host's library into a separate jar that the published metadata
  doesn't name.
- **`core-crypto-kmp-android`:** the three Android libraries in the aar.
- **`core-crypto-kmp-iosarm64`, `-iossimulatorarm64`, `-macosarm64`:** the static library in the cinterop klib.

Wire's build file stays as it is: `release/kmp.init.gradle`, which the script passes with `--init-script`, adds the JVM
libraries and the licence files. Each module has its SBOM next to it, `<module>-<version>-cyclonedx.json`, in CycloneDX
1.5. The jvm jar and the aar carry `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES.txt` in `META-INF/core-crypto-kmp/`; the
klib modules have the notices next to them, `<module>-<version>-third-party-notices.txt`.

The script publishes only libraries that `build.sh` built from the current commit; `UNRELEASED=1` skips that check, for
tests. Gradle needs JDK 25 (`JAVA_HOME`) and the Android SDK (`ANDROID_HOME`). At the end, `release/check.py` checks the
publication: the libraries in each module against `target/`, the licence files, the POMs and the SBOMs.

## Licences and SBOM

`release/third-party.py` lists what a module contains:

- the Rust crates linked into `core-crypto-ffi` for the module's targets (`cargo tree`, normal dependencies without
  proc-macros, which only run at build time),
- the C libraries these crates compile in: SQLite3 Multiple Ciphers on the JVM and macOS, SQLCipher and OpenSSL on
  Android and iOS,
- for the SBOM, also the Maven dependencies of its POM.

`THIRD_PARTY_NOTICES.txt` has the licence texts of the crates and C libraries: each crate's own licence files, or the
standard text in `release/licenses/` for crates that ship none. The crates of CoreCrypto under GPL-3.0 are the artifact
itself and aren't listed.

## CI

`.github/workflows/digits-release.yml` runs these scripts in the fork:

- A push to a `jvm/` branch builds the ten libraries on four runners (Linux x86_64 with Windows, Linux arm64, Android,
  and macOS for the Apple ones, with Xcode 16.4), publishes into `target/digits/maven/` and checks the publication,
  without signing or uploading. The version is `<Wire's version>-digits.0`.
- A tag `v<Wire's version>-digits.<n>` does the same, then signs, bundles and uploads the publication to Maven Central,
  which publishes it without a manual step.

The last step runs in the environment `maven-central`, which only these tags may use. It holds the secrets:

- `SIGNING_IN_MEMORY_KEY`: the ASCII-armoured secret key, `gpg --armor --export-secret-keys <key id>`,
- `SIGNING_IN_MEMORY_KEY_PASSWORD`: its passphrase,
- `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_PASSWORD`: a user token of the Central Portal.

Wire's own workflows come along with each merge from upstream, and some of them start on any tag. After a merge,
`release/disable-upstream-workflows.sh` disables all workflows in the fork but this one.

## Release

1. Tag the commit as `v10.5.2-digits.1` and push the tag to SchwarzDigits/core-crypto. CI then builds, publishes and
   uploads it. The steps below do the same by hand. The notices and SBOMs refer to the tag.

1. Check out the tag (`git switch --detach v10.5.2-digits.1`), build the ten libraries, then run `publish-kmp.sh`.

1. Sign and bundle, in a terminal, since GnuPG asks for the passphrase:

   ```sh
   VERSION=10.5.2-digits.1 SIGNING_KEY=<key id> release/bundle.sh
   ```

   It checks that the tag points at the current commit, signs each file, adds MD5, SHA-1, SHA-256 and SHA-512 checksums,
   runs `check.py --signed` and writes `target/digits/core-crypto-kmp-<version>-bundle.zip`.

1. Upload the bundle in the [Central Portal](https://central.sonatype.com/publishing) ("Publish Component"), wait for
   the validation, and publish. Central checks the signatures against the public key on a key server such as
   keys.openpgp.org.
