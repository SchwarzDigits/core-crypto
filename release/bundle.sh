#!/usr/bin/env bash
# Signs the publication of core-crypto-kmp that release/publish-kmp.sh built, adds the checksums and
# zips it for the Central Portal (https://central.sonatype.com, "Publish Component").
#
#   VERSION=10.5.2-digits.1 SIGNING_KEY=<OpenPGP key id> release/bundle.sh
#
# GnuPG asks for the key's passphrase, so run it in a terminal. The tag v<VERSION> has to point at the
# current commit, which the publication was built from. UNRELEASED=1 skips that check, for tests.
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
: "${SIGNING_KEY:?set SIGNING_KEY to the id of the OpenPGP key to sign with}"
GROUP=schwarz.opensource.natrium
cd "$(dirname "$0")/.."
maven=target/digits/maven
bundle="target/digits/core-crypto-kmp-$VERSION-bundle.zip"
dirs=("$maven/$(tr . / <<<"$GROUP")"/core-crypto-kmp*/"$VERSION")
[ -d "${dirs[0]}" ] || { echo "no publication of $VERSION in $maven; run release/publish-kmp.sh" >&2; exit 1; }

commit="$(git rev-parse HEAD)"
tagged="$(git rev-parse -q --verify "refs/tags/v$VERSION^{commit}" || true)"
if [ "$commit" != "$tagged" ] && [ "${UNRELEASED:-}" != 1 ]; then
  echo "tag v$VERSION points at ${tagged:-nothing}, not at $commit, which the publication was built from" >&2
  exit 1
fi

export GPG_TTY="${GPG_TTY:-$(tty)}"
rm -f "$bundle"
for dir in "${dirs[@]}"; do
  rm -f "$dir"/*.{asc,md5,sha1,sha256,sha512}
  for f in "$dir"/*; do
    gpg --local-user "$SIGNING_KEY" --armor --detach-sign "$f"
  done
done
python3 - "${dirs[@]}" <<'EOF'
import hashlib, pathlib, sys
for directory in sys.argv[1:]:
    for f in sorted(pathlib.Path(directory).iterdir()):
        if f.suffix != ".asc":
            for alg in ("md5", "sha1", "sha256", "sha512"):
                pathlib.Path(f"{f}.{alg}").write_text(hashlib.new(alg, f.read_bytes()).hexdigest())
EOF
python3 release/check.py --signed "$VERSION"
(cd "$maven" && zip -qrX "../$(basename "$bundle")" "${dirs[@]#"$maven/"}")
echo "bundle: $bundle"
