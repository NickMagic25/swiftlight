#!/bin/bash
set -euo pipefail
: "${SIGNING_KEYCHAIN_PATH:?Set SIGNING_KEYCHAIN_PATH to the temporary signing keychain}"
target="${1:?Pass the ZIP or DMG to submit to Apple}"
report="${2:?Pass the output JSON report path}"
mkdir -p "$(dirname "$report")"
auth=(--keychain-profile swiftlight-notary --keychain "$SIGNING_KEYCHAIN_PATH")
status=0
xcrun notarytool submit "$target" "${auth[@]}" --wait --timeout 30m --output-format json > "$report" || status=$?
# Always retrieve Apple's diagnostic log when there is a submission ID, including rejection.
submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$report")"
if [[ -n "$submission_id" ]]; then
  xcrun notarytool log "$submission_id" "${auth[@]}" "${report%.json}-log.json" || true
fi
if [[ "$status" -ne 0 ]]; then
  cat "$report"
  exit "$status"
fi
python3 - "$report" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit(f"ERROR: Apple notarization did not accept this submission: {result}")
print(f"Notarization accepted: {result['id']}")
PY
