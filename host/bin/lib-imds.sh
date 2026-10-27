# shellcheck shell=bash
# One managed-identity token path, so three scripts cannot drift apart.
IMDS_ENDPOINT="http://169.254.169.254/metadata/identity/oauth2/token"

imds_token() {
  local resource="${1:-https://management.azure.com/}" enc
  enc="$(printf '%s' "$resource" | jq -sRr @uri)"
  curl -fsS -m 10 -H Metadata:true \
    "${IMDS_ENDPOINT}?api-version=2018-02-01&resource=${enc}" \
    | jq -r '.access_token'
}

kv_secret() {
  local vault="$1" name="$2" token
  token="$(imds_token https://vault.azure.net)" || return 1
  curl -fsS -m 20 -H "Authorization: Bearer ${token}" \
    "https://${vault}.vault.azure.net/secrets/${name}?api-version=7.4" | jq -r '.value'
}
