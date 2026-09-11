#!/usr/bin/env bash
# Signs the publication that jvm-release/package.sh built, adds the checksums and zips it for the
# Central Portal (https://central.sonatype.com, "Publish Component").
#
#   VERSION=10.5.2-digits.1 SIGNING_KEY=<OpenPGP key id> jvm-release/bundle.sh
#
# GnuPG asks for the key's passphrase, so run it in a terminal. The tag v<VERSION> has to point at
# the commit the jar was built from. UNRELEASED=1 skips that check, for tests.
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
: "${SIGNING_KEY:?set SIGNING_KEY to the id of the OpenPGP key to sign with}"
GROUP=schwarz.opensource.natrium
ARTIFACT=core-crypto-jvm
cd "$(dirname "$0")/.."
path="$(tr . / <<<"$GROUP")/$ARTIFACT/$VERSION"
out="target/jvm-release/maven/$path"
bundle="target/jvm-release/$ARTIFACT-$VERSION-bundle.zip"
[ -f "$out/$ARTIFACT-$VERSION.jar" ] || { echo "no publication in $out; run jvm-release/package.sh" >&2; exit 1; }

built="$(unzip -p "$out/$ARTIFACT-$VERSION.jar" META-INF/MANIFEST.MF | tr -d '\r' | sed -n 's/^Built-From: [^ ]* //p')"
tagged="$(git rev-parse -q --verify "refs/tags/v$VERSION^{commit}" || true)"
if [ "$built" != "$tagged" ] && [ "${UNRELEASED:-}" != 1 ]; then
  echo "the jar was built from $built, but tag v$VERSION points at ${tagged:-nothing}" >&2
  exit 1
fi

export GPG_TTY="${GPG_TTY:-$(tty)}"
rm -f "$out"/*.{asc,md5,sha1,sha256,sha512} "$bundle"
for f in "$out"/*; do
  gpg --local-user "$SIGNING_KEY" --armor --detach-sign "$f"
done
python3 - "$out" <<'EOF'
import hashlib, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).iterdir()):
    if f.suffix != ".asc":
        for alg in ("md5", "sha1", "sha256", "sha512"):
            pathlib.Path(f"{f}.{alg}").write_text(hashlib.new(alg, f.read_bytes()).hexdigest())
EOF
python3 jvm-release/check.py --signed "$VERSION"
(cd target/jvm-release/maven && zip -qrX "../$(basename "$bundle")" "$path")
echo "bundle: $bundle"
