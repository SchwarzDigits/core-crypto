#!/usr/bin/env bash
# Builds CoreCrypto's JVM native library for one JVM target with the make rules of this branch,
# as Wire's release build does (RELEASE=1):
#   aarch64-apple-darwin       make jvm-darwin, on a Mac with rustup
#   x86_64-unknown-linux-gnu   make jvm-linux, in the manylinux_2_28 container
#   aarch64-unknown-linux-gnu  make jvm-linux-arm64, in the manylinux_2_28 container
#   x86_64-pc-windows-gnu      make jvm-windows, cross-compiled with MinGW
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
    make "$rule" RELEASE=1 JVM_LINUX_MANYLINUX=1
  else
    in_linux "$platform" make "$rule" RELEASE=1 JVM_LINUX_MANYLINUX=1
  fi
}

case "$target" in
  aarch64-apple-darwin)
    rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target aarch64-apple-darwin
    make jvm-darwin RELEASE=1
    ;;
  x86_64-unknown-linux-gnu) linux_rule x86_64 linux/amd64 jvm-linux ;;
  aarch64-unknown-linux-gnu) linux_rule aarch64 linux/arm64 jvm-linux-arm64 ;;
  x86_64-pc-windows-gnu) in_linux "linux/$(docker version --format '{{.Server.Arch}}')" make jvm-windows RELEASE=1 ;;
  *)
    echo "unsupported target: $target" >&2
    exit 1
    ;;
esac
ls -la target/"$target"/release/*core_crypto_ffi.*
# jvm-release/package.sh packages the library only with the commit it was built from.
mkdir -p target/jvm-release/built
echo "$(git rev-parse HEAD)$([ -z "$(git status --porcelain)" ] || echo ' (dirty)')" > "target/jvm-release/built/$target"
