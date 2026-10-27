#!/usr/bin/env bash
# os/butane/tests/test_units_have_scripts.sh
set -euo pipefail
ign="${1:-}"
# Called with no argument from tests/verify.sh, where no .ign may exist (it needs
# a container engine to compile). Skip explicitly rather than break the gate.
if [ -z "$ign" ] || [ ! -f "$ign" ]; then
  echo "SKIP: no ignition file to check (compile with os/butane/build.sh first)"
  exit 0
fi
fail() { echo "FAIL: $1" >&2; exit 1; }
for p in /usr/local/sbin/oc-secrets /usr/local/sbin/oc-acr-login \
         /usr/local/sbin/oc-idle-check /usr/local/sbin/oc-snapshot \
         /usr/local/sbin/oc-tailnet /usr/local/sbin/oc-tailnet-up \
         /usr/local/sbin/lib-imds.sh; do
  jq -e --arg p "$p" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "not baked into the image: $p"
done
# Every ExecStart must point at a path the config actually provides, unless it is
# a binary the OS image already ships. rpm-ostree is the rebase tool; it is not
# something this repo bakes in, and requiring it here would be a false failure.
SHIPPED_BINARIES='/usr/bin/rpm-ostree /usr/bin/systemctl /usr/bin/touch'
for exe in $(jq -r '.systemd.units[]?.contents // empty' "$ign" \
             | grep -oE '^ExecStart=[^ ]+' | cut -d= -f2 | sort -u); do
  case " $SHIPPED_BINARIES " in
    *" $exe "*) continue ;;
  esac
  jq -e --arg p "$exe" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "unit runs a missing executable: $exe"
done
# Modes are load-bearing: a non-executable script is not run by systemd, and the
# quadlet is data rather than a program.
mode_of() { jq -r --arg p "$1" '.storage.files[] | select(.path == $p) | .mode' "$ign"; }
while read -r p; do
  [ "$(mode_of "$p")" = "493" ] || fail "$p is not 0755"
done < <(jq -r '.storage.files[].path | select(startswith("/usr/local/sbin/") and (endswith(".sh") | not))' "$ign")
[ "$(mode_of /usr/local/sbin/lib-imds.sh)" = "420" ] || fail "lib-imds.sh is not 0644"
[ "$(mode_of /etc/containers/systemd/opencode.container)" = "420" ] \
  || fail "quadlet is not 0644"

# Terraform ships this compiled artifact, not ucore.bu. Source-level tests alone
# leave the deployed host broken when only the .bu was changed, so the two units
# whose absence made the box unreachable are checked here as well.
jq -e '.systemd.units[] | select(.name == "tailscaled.service") | .enabled' "$ign" >/dev/null \
  || fail "tailscaled.service is not enabled in the compiled Ignition"

net="$(jq -r '.systemd.units[] | select(.name == "oc-tailnet.service") | .contents // empty' "$ign")"
[ -n "$net" ] || fail "oc-tailnet.service has no contents in the compiled Ignition"
printf '%s\n' "$net" | grep -Eq '^EnvironmentFile=/etc/devbox/oc-secrets\.env$' \
  || fail "oc-tailnet.service does not load the env file naming its vault in the compiled Ignition"

echo "all units reference baked-in scripts"
