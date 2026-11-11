#!/usr/bin/env bash
# vm/tests/test_overlay_merge.sh
#
# The VM overlay is the seam between the shipped Ignition and the harness. If it
# replaces storage.files or systemd.units instead of appending, the VM boots but
# proves nothing because the quadlets and secret files are gone. These cases run
# the real merge and inspect the document it produced.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/base.json" <<'EOF'
{
  "ignition": {"version": "3.5.0"},
  "storage": {
    "files": [
      {"path": "/etc/base.conf", "mode": 420, "contents": {"source": "data:,base"}},
      {"path": "/etc/containers/systemd/opencode.container", "mode": 420, "contents": {"source": "data:,quadlet"}}
    ],
    "links": [
      {"path": "/etc/systemd/system/multi-user.target.wants/tailscaled.service", "target": "/usr/lib/systemd/system/tailscaled.service"}
    ],
    "directories": [
      {"path": "/var/srv", "mode": 493}
    ]
  },
  "systemd": {
    "units": [
      {"name": "base.service", "enabled": true, "contents": "[Unit]\nDescription=base\n"},
      {"name": "ucore-autorebase.service", "enabled": true, "contents": "[Unit]\nDescription=rebase\n"}
    ]
  }
}
EOF
before="$(sha256sum "$tmp/base.json" | cut -d' ' -f1)"

# T1: the merge keeps the base document and adds each harness entry once.
"$vm/overlay-ignition.sh" "$tmp/base.json" "$tmp/out.json" >/dev/null \
  || fail "T1: overlay merge failed"

jq -e '.ignition.version == "3.5.0"' "$tmp/out.json" >/dev/null \
  || fail "T1: ignition version changed"

for path in /etc/base.conf /etc/containers/systemd/opencode.container \
            /usr/local/sbin/devbox-vm-check /etc/devbox-vm/devbox-vm-data \
            /etc/devbox-vm/agent.env /etc/devbox-vm/repart/10-data.conf \
            /etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin.conf; do
  jq -e --arg p "$path" '[.storage.files[] | select(.path == $p)] | length == 1' \
    "$tmp/out.json" >/dev/null || fail "T1: expected exactly one file at $path"
done

for unit in base.service ucore-autorebase.service devbox-vm-check.service devbox-vm-data.service; do
  jq -e --arg n "$unit" '[.systemd.units[] | select(.name == $n)] | length == 1' \
    "$tmp/out.json" >/dev/null || fail "T1: expected exactly one unit $unit"
done

# The base links and directories are load-bearing too (the quadlet boot
# enablement is a link), so a merge that replaces them is a silent regression.
jq -e '[.storage.links[] | select(.path == "/etc/systemd/system/multi-user.target.wants/tailscaled.service")] | length == 1' \
  "$tmp/out.json" >/dev/null || fail "T1: the merge dropped the base link"
jq -e '[.storage.directories[] | select(.path == "/var/srv")] | length == 1' \
  "$tmp/out.json" >/dev/null || fail "T1: the merge dropped the base directory"
jq -e '[.storage.links[] | select(.path == "/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service")] | length == 1' \
  "$tmp/out.json" >/dev/null || fail "T1: expected exactly one serial getty link"

# T2: the harness script and env are executable and carry the values the guest
#     reads back. A mode written as 0755 in jq would be decimal 755, not 493.
jq -e '[.storage.files[] | select(.path == "/usr/local/sbin/devbox-vm-check")][0].mode == 493' \
  "$tmp/out.json" >/dev/null || fail "T2: check script mode is not 0755"

jq -r '[.storage.files[] | select(.path == "/etc/devbox-vm/agent.env")][0].contents.source' \
  "$tmp/out.json" | sed 's/^data:;base64,//' | base64 -d > "$tmp/agent.env" \
  || fail "T2: agent.env is not a base64 data URL"
grep -qx 'EXPECTED_IMAGE=ghcr.io/ultus-net/devbox:prod' "$tmp/agent.env" \
  || fail "T2: agent.env does not name the published image"
grep -qx 'EXPECTED_HOSTNAME=devbox-vm' "$tmp/agent.env" \
  || fail "T2: agent.env does not name the VM hostname"
grep -qx 'ROLLBACK_REPO=' "$tmp/agent.env" \
  || fail "T2: a normal run must not ask the guest for a rollback"

# T2b: a rollback run carries the fixture registry and marks it insecure, since
#      the guest reaches it over plain HTTP on the qemu user network.
VM_REGISTRY="10.0.2.2:5000" VM_ROLLBACK_REPO="10.0.2.2:5000/devbox" \
  "$vm/overlay-ignition.sh" "$tmp/base.json" "$tmp/registry.json" >/dev/null \
  || fail "T2b: overlay merge with a fixture registry failed"
conf="/etc/containers/registries.conf.d/000-devbox-vm-registry.conf"
jq -e --arg p "$conf" '[.storage.files[] | select(.path == $p)] | length == 1' \
  "$tmp/registry.json" >/dev/null || fail "T2b: the registry drop-in is missing"
jq -r --arg p "$conf" '[.storage.files[] | select(.path == $p)][0].contents.source' \
  "$tmp/registry.json" | sed 's/^data:;base64,//' | base64 -d > "$tmp/registry.conf" \
  || fail "T2b: the registry drop-in is not a base64 data URL"
grep -qx 'location = "10.0.2.2:5000"' "$tmp/registry.conf" \
  || fail "T2b: the drop-in does not name the fixture host"
grep -qx 'insecure = true' "$tmp/registry.conf" \
  || fail "T2b: the drop-in does not mark the fixture host insecure"
jq -r '[.storage.files[] | select(.path == "/etc/devbox-vm/agent.env")][0].contents.source' \
  "$tmp/registry.json" | sed 's/^data:;base64,//' | base64 -d > "$tmp/registry.env"
grep -qx 'ROLLBACK_REPO=10.0.2.2:5000/devbox' "$tmp/registry.env" \
  || fail "T2b: agent.env does not carry the rollback repo"

# T3: a second merge of its own output is byte-identical. A non-idempotent
#     append would duplicate a path, which Ignition rejects at boot.
"$vm/overlay-ignition.sh" "$tmp/out.json" "$tmp/out2.json" >/dev/null \
  || fail "T3: second merge failed"
cmp -s "$tmp/out.json" "$tmp/out2.json" || fail "T3: merge is not idempotent"
VM_REGISTRY="10.0.2.2:5000" VM_ROLLBACK_REPO="10.0.2.2:5000/devbox" \
  "$vm/overlay-ignition.sh" "$tmp/registry.json" "$tmp/registry2.json" >/dev/null \
  || fail "T3: second registry merge failed"
cmp -s "$tmp/registry.json" "$tmp/registry2.json" \
  || fail "T3: the registry merge is not idempotent"

# T4: invalid input fails before an output file is published.
echo '{}' > "$tmp/bad.json"
if "$vm/overlay-ignition.sh" "$tmp/bad.json" "$tmp/bad-out.json" >/dev/null 2>&1; then
  fail "T4: a document without ignition.version was accepted"
fi
[ ! -e "$tmp/bad-out.json" ] || fail "T4: a rejected merge left an output file"

# T5: the base document is input only.
after="$(sha256sum "$tmp/base.json" | cut -d' ' -f1)"
[ "$before" = "$after" ] || fail "T5: the merge modified its input"

echo "vm overlay keeps the shipped Ignition and is idempotent"
