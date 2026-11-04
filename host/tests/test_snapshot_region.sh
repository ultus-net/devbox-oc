#!/usr/bin/env bash
# host/tests/test_snapshot_region.sh
#
# A snapshot must be created in the region the data disk lives in. The default
# was westeurope, which Azure rejects only after the request is made, so a
# scheduled snapshot would fail silently on a newzealandnorth box.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/host/bin/oc-snapshot"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
bash_bin="$(command -v bash)"
mkdir -p "$tmp/bin"

# Two calls: the IMDS token request, then the PUT whose body carries location.
cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/curl-calls"
case "\$*" in
  *"-X PUT"*) cat > "$tmp/put-body" ;;
  *) printf '{"access_token":"probe"}\n' ;;
esac
EOF
cat > "$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
echo probe
EOF
cat > "$tmp/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/jq" "$tmp/bin/logger"
: > "$tmp/curl-calls"

rc=0
PATH="$tmp/bin:$PATH" DISK_ID=/subscriptions/x/resourceGroups/rg-x/providers/Microsoft.Compute/disks/d \
  RG=rg-x SUBSCRIPTION_ID=x "$bash_bin" "$script" \
  >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] || fail "oc-snapshot exited $rc: $(cat "$tmp/err")"

grep -q '"location": "newzealandnorth"' "$tmp/put-body" \
  || fail "snapshot was not created in newzealandnorth: $(cat "$tmp/put-body")"

# The Terraform default is the VM and disk region. If the two drift, every
# scheduled snapshot fails the region check on the box.
tf_location="$(
  awk '/variable "location"/{seen=1} seen && /default/{gsub(/[",]/,""); print $3; exit}' \
    "$root/terraform/variables.tf"
)"
[ -n "$tf_location" ] || fail "could not read the terraform location default"
grep -q "\"location\": \"$tf_location\"" "$tmp/put-body" \
  || fail "snapshot location does not match terraform default $tf_location: $(cat "$tmp/put-body")"

echo "snapshot is created in the disk region and matches the terraform default"
