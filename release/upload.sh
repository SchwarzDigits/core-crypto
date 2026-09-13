#!/usr/bin/env bash
# Uploads the bundle that release/bundle.sh wrote to the Central Portal and waits until Maven Central
# has published it (https://central.sonatype.org/publish/publish-portal-api/).
#
#   VERSION=10.5.2-digits.1 MAVEN_CENTRAL_USERNAME=<token name> MAVEN_CENTRAL_PASSWORD=<token> release/upload.sh
#
# The credentials are a user token of the Central Portal. With PUBLISHING_TYPE=USER_MANAGED, Central
# only validates the bundle, and it's published in the Portal.
set -euo pipefail
: "${VERSION:?set VERSION, e.g. 10.5.2-digits.1}"
: "${MAVEN_CENTRAL_USERNAME:?set MAVEN_CENTRAL_USERNAME to the name of a Central Portal user token}"
: "${MAVEN_CENTRAL_PASSWORD:?set MAVEN_CENTRAL_PASSWORD to the Central Portal user token}"
PUBLISHING_TYPE="${PUBLISHING_TYPE:-AUTOMATIC}"
API=https://central.sonatype.com/api/v1/publisher
cd "$(dirname "$0")/.."
bundle="target/digits/core-crypto-kmp-$VERSION-bundle.zip"
[ -f "$bundle" ] || { echo "no bundle $bundle; run release/bundle.sh" >&2; exit 1; }

# The header goes to curl through stdin, so the token isn't on a command line.
auth="Authorization: Bearer $(printf '%s:%s' "$MAVEN_CENTRAL_USERNAME" "$MAVEN_CENTRAL_PASSWORD" | base64 | tr -d '\n')"
id="$(curl -fsS -X POST -H @- -F "bundle=@$bundle;type=application/octet-stream" \
  "$API/upload?name=core-crypto-kmp-$VERSION&publishingType=$PUBLISHING_TYPE" <<<"$auth")"
echo "deployment $id ($PUBLISHING_TYPE)"

done_state=PUBLISHED
[ "$PUBLISHING_TYPE" = AUTOMATIC ] || done_state=VALIDATED
state=unknown
for _ in $(seq 1 120); do
  status="$(curl -fsS -X POST -H @- "$API/status?id=$id" <<<"$auth")"
  state="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["deploymentState"])' <<<"$status")"
  echo "$(date +%T) $state"
  case "$state" in
    "$done_state") exit 0 ;;
    FAILED) echo "$status" >&2; exit 1 ;;
  esac
  sleep 30
done
echo "deployment $id is still $state after an hour" >&2
exit 1
