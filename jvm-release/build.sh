#!/usr/bin/env bash
# Builds one of CoreCrypto's native libraries with the make rules of this branch, as Wire's release
# build does (RELEASE=1):
#   aarch64-apple-darwin       make jvm-darwin, on a Mac with rustup; also the macOS static library
#   x86_64-unknown-linux-gnu   make jvm-linux, in the manylinux_2_28 container
#   aarch64-unknown-linux-gnu  make jvm-linux-arm64, in the manylinux_2_28 container
#   x86_64-pc-windows-gnu      make jvm-windows, cross-compiled with MinGW
#   aarch64-linux-android      make android-armv8, with the Android NDK in ANDROID_NDK_HOME
#   armv7-linux-androideabi    make android-armv7, with the Android NDK
#   x86_64-linux-android       make android-x86, with the Android NDK
#   aarch64-apple-ios          make ios-device, on a Mac with Xcode
#   aarch64-apple-ios-sim      make ios-simulator-arm, on a Mac with Xcode
#   ffi-library                make ffi-library, the host library the Kotlin bindings come from
# On a Linux host of the right architecture, the Linux rules run directly. Otherwise they run in an
# Ubuntu container that uses the host's Docker socket; so does the Windows build.
#
#   jvm-release/build.sh <target>
set -euo pipefail

target="$1"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
# The channel of rust-toolchain.toml, without the mobile targets it lists.
RUSTUP_TOOLCHAIN="$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)"
export RUSTUP_TOOLCHAIN
# Reproducible builds: the build time that CoreCrypto embeds is the commit time, and the paths in
# panic messages don't depend on where this machine keeps the Rust sources.
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
remap_cargo() { echo "--remap-path-prefix=$1=/cargo"; }
# For builds on this host. With the rust-src component, the standard library's paths would be this
# machine's too.
host_rustflags() {
  local sysroot rustc_commit
  sysroot="$(rustup run "$RUSTUP_TOOLCHAIN" rustc --print sysroot)"
  rustc_commit="$(rustup run "$RUSTUP_TOOLCHAIN" rustc -vV | sed -n 's/^commit-hash: //p')"
  echo "$(remap_cargo "${CARGO_HOME:-$HOME/.cargo}") --remap-path-prefix=$sysroot/lib/rustlib/src/rust=/rustc/$rustc_commit"
}
# make's prerequisites don't cover these flags or the commit, so the library goes first and make
# always runs its rule; cargo decides what to rebuild. (make -B would reach OpenSSL's own make
# through MAKEFLAGS and break its build.)
out="target/$target/release"
[ "$target" != ffi-library ] || out=target/release
rm -f "$out"/*core_crypto_ffi.*

# Runs a command in an Ubuntu container for <platform>, with this repository at the same path, the
# host's Docker socket, and a Rust toolchain under target/jvm-release/<arch>.
in_linux() {
  local platform="$1"
  shift
  local home="$repo/target/jvm-release/${platform#linux/}"
  mkdir -p "$home"
  local volumes=(--volume /var/run/docker.sock:/var/run/docker.sock --volume "$repo:$repo")
  # make and the build scripts call git. In a linked worktree, the git directory lies outside it.
  local git_dir
  git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
  if [ "${git_dir#"$repo"/}" = "$git_dir" ]; then
    volumes+=(--volume "$git_dir:$git_dir")
  fi
  docker run --rm --platform "$platform" "${volumes[@]}" --workdir "$repo" \
    --env CARGO_HOME="$home/cargo" --env RUSTUP_HOME="$home/rustup" --env RUSTUP_TOOLCHAIN \
    --env RUSTFLAGS="$(remap_cargo "$home/cargo")" --env SOURCE_DATE_EPOCH \
    buildpack-deps:noble bash -euo pipefail -c '
      git config --global --add safe.directory "*"
      apt-get update -qq
      apt-get install -qq --yes --no-install-recommends fd-find gcc-mingw-w64-x86-64 >/dev/null
      ln -sf "$(command -v fdfind)" /usr/local/bin/fd
      if ! command -v docker >/dev/null; then
        base="https://download.docker.com/linux/static/stable/$(uname -m)"
        tgz="$(curl -fsSL "$base/" | grep -oE "docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz" | sort -V | tail -1)"
        curl -fsSL "$base/$tgz" | tar -xz -C /usr/local/bin --strip-components=1 docker/docker
      fi
      export PATH="$CARGO_HOME/bin:$PATH"
      command -v rustup >/dev/null ||
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --quiet --no-modify-path --default-toolchain none
      rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target x86_64-pc-windows-gnu
      '"$*"
}

linux_rule() {
  local arch="$1" platform="$2" rule="$3"
  if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = "$arch" ]; then
    RUSTFLAGS="$(remap_cargo "${CARGO_HOME:-$HOME/.cargo}")" make "$rule" RELEASE=1 JVM_LINUX_MANYLINUX=1
  else
    in_linux "$platform" make "$rule" RELEASE=1 JVM_LINUX_MANYLINUX=1
  fi
}

case "$target" in
  aarch64-apple-darwin | aarch64-apple-ios | aarch64-apple-ios-sim)
    rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target "$target"
    case "$target" in
      aarch64-apple-darwin) rule=jvm-darwin ;;
      aarch64-apple-ios) rule=ios-device ;;
      *) rule=ios-simulator-arm ;;
    esac
    # The linker would name the library by its path in target/, and derive its UUID from the paths
    # and times of the object files.
    flags="$(host_rustflags) -C link-arg=-Wl,-install_name,@rpath/libcore_crypto_ffi.dylib"
    flags+=" -C link-arg=-Wl,-reproducible -C link-arg=-Wl,-oso_prefix,$repo/"
    # The iOS rules build with cancellable-transactions, for Wire's Swift package. That feature adds a
    # variant to CoreCryptoError before Other, so the Kotlin bindings, which come from ffi-library
    # without it, couldn't read the errors of these libraries.
    RUSTFLAGS="$flags" make "$rule" RELEASE=1 SWIFT_CARGO_BUILD_ARGS=--release
    ;;
  aarch64-linux-android | armv7-linux-androideabi | x86_64-linux-android)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
    rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target "$target"
    case "$target" in
      aarch64-linux-android) rule=android-armv8 ;;
      armv7-linux-androideabi) rule=android-armv7 ;;
      *) rule=android-x86 ;;
    esac
    RUSTFLAGS="$(host_rustflags)" make "$rule" RELEASE=1
    ;;
  ffi-library)
    rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal
    RUSTFLAGS="$(host_rustflags)" make ffi-library RELEASE=1
    ;;
  x86_64-unknown-linux-gnu) linux_rule x86_64 linux/amd64 jvm-linux ;;
  aarch64-unknown-linux-gnu) linux_rule aarch64 linux/arm64 jvm-linux-arm64 ;;
  x86_64-pc-windows-gnu) in_linux "linux/$(docker version --format '{{.Server.Arch}}')" make jvm-windows RELEASE=1 ;;
  *)
    echo "unsupported target: $target" >&2
    exit 1
    ;;
esac
ls -la "$out"/*core_crypto_ffi.*
# jvm-release/package.sh packages the library only with the commit it was built from, in a clean and
# detached checkout: CoreCrypto embeds the branch name, and a checkout of the tag has none.
mkdir -p target/jvm-release/built
branch="$(git symbolic-ref -q --short HEAD || true)"
echo "$(git rev-parse HEAD)$([ -z "$(git status --porcelain)" ] || echo ' (dirty)')${branch:+ (on branch $branch)}" \
  > "target/jvm-release/built/$target"
