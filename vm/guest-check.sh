#!/usr/bin/env bash
# Dogfood check that runs inside the VM, once, on the first ucore boot.
#
# It asserts the properties this repo claims, in the order the host reaches
# them: the rebase finished, the data disk is mounted, the secret writers fail
# closed, then the containers start and stay on loopback. The report is posted
# to the harness agent on the qemu user network, so the host sees a failure as
# a failure instead of reading a log by eye.
set -uo pipefail

report_dir=/var/lib/devbox-vm
report="$report_dir/report.txt"
mkdir -p "$report_dir"
: > "$report"
failures=0

say() { printf '%s\n' "$*" | tee -a "$report"; }
pass() { say "PASS $1: $2"; }
skip() { say "SKIP $1: $2"; }
info() { say "INFO $1: $2"; }
fail() { failures=$((failures + 1)); say "FAIL $1: $2"; }

check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name" "$got"; else fail "$name" "want=$want got=$got"; fi
}

check_contains() {
  local name="$1" want="$2" haystack="$3"
  case "$haystack" in
    *"$want"*) pass "$name" "$want" ;;
    *) fail "$name" "missing '$want' in: $haystack" ;;
  esac
}

check_absent() {
  local name="$1" unwanted="$2" haystack="$3"
  case "$haystack" in
    *"$unwanted"*) fail "$name" "found '$unwanted' in: $haystack" ;;
    *) pass "$name" "absent: $unwanted" ;;
  esac
}

# The harness agent writes this file when it builds the Ignition. A missing file
# means the VM was booted from something other than vm/run-vm.sh.
if [ -r /etc/devbox-vm/agent.env ]; then
  # shellcheck disable=SC1091
  . /etc/devbox-vm/agent.env
else
  echo "missing /etc/devbox-vm/agent.env" >&2
  exit 1
fi
AGENT_URL="${AGENT_URL:-http://10.0.2.2:8123}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-devbox-vm}"
EXPECTED_IMAGE="${EXPECTED_IMAGE:-ghcr.io/ultus-net/devbox:prod}"
ROLLBACK_REPO="${ROLLBACK_REPO:-}"

# The host starts the agent before qemu, but the guest's network is only up
# after the boot completes. Wait for it rather than racing it.
agent_up=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "$AGENT_URL/health" >/dev/null 2>&1; then
    agent_up=1
    break
  fi
  sleep 5
done
if [ "$agent_up" = 0 ]; then
  info agent "unreachable at $AGENT_URL; the report stays at $report"
fi

info release "$(rpm-ostree status --booted 2>/dev/null | tr '\n' ' ')"

# The booted deployment is the one the marker prefixes. `rpm-ostree status`
# prints the staged deployment too, so grepping all of its output accepts a ucore
# that is only staged and not booted. --booted narrows the output, and the marker
# keeps the parse honest if a later edit drops the flag.
booted_line() {
  grep -m1 -e '^●' -e '^\*' || true
}

# 1. The rebase landed. The first boot is Fedora CoreOS; the booted deployment
#    after one reboot must name the ucore image.
booted="$(rpm-ostree status --booted 2>/dev/null | booted_line)"
check_contains booted-image ucore-minimal "$booted"
check hostname "$EXPECTED_HOSTNAME" "$(hostname)"

# 2. The tailnet daemon is installed and enabled by ucore. A keyless build does
#    not join, so only the enabled state is asserted here.
check tailscaled-enabled enabled "$(systemctl is-enabled tailscaled.service 2>&1)"

# 3. The data disk is a separate device, mounted by its label, and the
#    persistent layout exists with the container's uid.
#    `systemctl is-active` prints the ACTIVE state, which is "active" for a
#    mount unit; "mounted" is the unit-type SUB state and never appears here.
check srv-mounted active "$(systemctl is-active var-srv.mount 2>&1)"
data_source="$(findmnt -n -o SOURCE /srv 2>/dev/null || true)"
data_label="$(blkid -s LABEL -o value "$data_source" 2>/dev/null || true)"
check data-label data "$data_label"
# The point of the second disk is that an OS reinstall cannot destroy /srv. A
# mount unit that fails leaves /srv a plain directory on the OS disk, which looks
# the same to every other check, so compare the parent block devices. findmnt
# reports `/dev/vda4[/ostree/deploy/...]` for /var, and a second partition on the
# same disk is still destroyed by a reinstall.
source_device() {
  printf '%s' "${1%%\[*}"
}
parent_device() {
  lsblk -no PKNAME "$(source_device "$1")" 2>/dev/null | head -n1
}
var_source="$(findmnt -n -o SOURCE /var 2>/dev/null || true)"
data_parent="$(parent_device "$data_source")"
var_parent="$(parent_device "$var_source")"
if [ -n "$data_parent" ] && [ "$data_parent" != "$var_parent" ]; then
  pass data-separate-device "/dev/$data_parent is not /dev/$var_parent"
else
  fail data-separate-device "/srv is on ${data_source:-nothing} (parent ${data_parent:-?}), the same disk as /var (parent ${var_parent:-?})"
fi
check srv-owner 1000:1000 "$(stat -c '%u:%g' /srv/repos 2>/dev/null || true)"
check oc-paths active "$(systemctl is-active oc-paths.service 2>&1)"

# 4. Always on: the sleep targets are masked and logind ignores idle.
check sleep-masked masked "$(systemctl is-enabled sleep.target 2>&1)"
check suspend-masked masked "$(systemctl is-enabled suspend.target 2>&1)"
check hibernate-masked masked "$(systemctl is-enabled hibernate.target 2>&1)"
check hybrid-sleep-masked masked "$(systemctl is-enabled hybrid-sleep.target 2>&1)"
check suspend-then-hibernate-masked masked "$(systemctl is-enabled suspend-then-hibernate.target 2>&1)"
# IdleAction is a logind Manager property. `loginctl show -p IdleAction` reports
# the per-session property, which is unset, so it always looks empty.
idle_action="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager IdleAction 2>/dev/null | awk '{print $2}' | tr -d '"')"
check idle-action ignore "$idle_action"

# 5. One door: sshd is masked, Cockpit is rebound to loopback.
check sshd-masked masked "$(systemctl is-enabled sshd.service 2>&1)"
if systemctl is-enabled cockpit.socket >/dev/null 2>&1; then
  listeners="$(ss -ltn 2>/dev/null | awk 'NR > 1 { print $4 }')"
  check_contains cockpit-loopback 127.0.0.1:9090 "$listeners"
else
  skip cockpit-loopback "cockpit.socket is not enabled on this image"
fi

# 6. Fail closed before the operator writes secrets.env. This is the state the
#    install doc says an unprovisioned box is in, and it must not serve requests.
env_state=absent
[ -e /etc/opencode/env ] && env_state=present
check env-not-written absent "$env_state"
# The quadlet is `Requires=oc-env.service`, so before secrets exist the writer
# must have run and failed, and the container must not be up. Without the boot
# enablement below, both assertions pass for the wrong reason: nothing ran.
check oc-env-failed failed "$(systemctl is-failed oc-env.service 2>&1)"
check opencode-inactive inactive "$(systemctl is-active opencode.service 2>&1)"

# Quadlet units are generated by podman and cannot be `systemctl enable`d, so
# the generator applies the quadlet's [Install] section at generation time. Ask
# systemd for the resulting WantedBy property; the generator does not write a
# symlink under /etc/systemd/system, so looking there reports a false failure.
# Without a boot target the box comes up serving nothing after a reboot.
for unit in opencode.service hermes.service; do
  wanted="$(systemctl show -p WantedBy --value "$unit" 2>/dev/null || true)"
  case " $wanted " in
    *" default.target "*|*" multi-user.target "*)
      pass "quadlet-boot-$unit" "wanted by $wanted" ;;
    *) fail "quadlet-boot-$unit" "no boot target wants it (WantedBy=${wanted:-none})" ;;
  esac
done

# 7. Provision dummy secrets exactly as docs/install.md tells the operator to,
#    then bring the workloads up.
install -d -m 0700 /etc/devbox
umask 077
cat > /etc/devbox/secrets.env <<'EOF'
OPENCODE_PASSWORD=vm-dogfood-not-a-secret
API_SERVER_KEY=vm-dogfood-not-a-secret
OPENROUTER_API_KEY=vm-dogfood-not-a-secret
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=vm-dogfood-not-a-secret
RESTIC_REPOSITORY=s3:http://127.0.0.1:9000/devbox
RESTIC_PASSWORD=vm-dogfood-not-a-secret
EOF
chmod 0600 /etc/devbox/secrets.env
info secrets "wrote dummy /etc/devbox/secrets.env"

# 8. Pull the published image before starting the units, so a slow pull is
#    reported as a pull failure rather than as a health-check timeout.
if podman pull "$EXPECTED_IMAGE" >/dev/null 2>&1; then
  pass image-pull "$EXPECTED_IMAGE"
else
  fail image-pull "$EXPECTED_IMAGE"
fi

systemctl daemon-reload
systemctl restart oc-env.service hermes-env.service >/dev/null 2>&1
check oc-env-ok active "$(systemctl is-active oc-env.service 2>&1)"
check hermes-env-ok active "$(systemctl is-active hermes-env.service 2>&1)"
check opencode-env-perms 600 "$(stat -c '%a' /etc/opencode/env 2>/dev/null || true)"
check hermes-env-perms 600 "$(stat -c '%a' /etc/hermes/env 2>/dev/null || true)"

wait_health() {
  local name="$1" status=""
  for _ in $(seq 1 120); do
    status="$(podman inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
    if [ "$status" = healthy ]; then
      pass "$name-healthy" healthy
      return 0
    fi
    sleep 5
  done
  fail "$name-healthy" "last=${status:-unknown}"
}

systemctl start opencode.service hermes.service >/dev/null 2>&1
wait_health opencode
wait_health hermes
version="$(podman exec opencode opencode --version 2>&1 || true)"
# The CLI prints "opencode v2.1.4", so match a semver token rather than an
# anchored number. A bare error message must not pass.
if printf '%s\n' "$version" | grep -qE '(^| )v?[0-9]+\.[0-9]+\.[0-9]+'; then
  pass opencode-version "$version"
else
  fail opencode-version "unexpected output: ${version:-none}"
fi

# Rootful podman publishes ports with DNAT, so the host's `ss` does not show the
# container sockets. `podman port` reports what podman was asked to bind, and a
# connection to loopback proves the path answers. An empty binding string must
# fail, not pass the "absent" assertions vacuously. `podman port` takes one
# container and an optional port; a second name is parsed as a port and errors,
# so collect each container separately.
bindings=""
for name in opencode hermes; do
  bindings="$bindings $(podman port "$name" 2>/dev/null | tr '\n' ' ')"
done
info port-bindings "${bindings:-none}"

# A TCP connect here, not an HTTP request: the container's own health command is
# what proves the API serves answers, and guest-check reads that verdict
# separately in wait_health. This only proves the listener bound. The listener may
# also come up after the container reports healthy, so retry before failing.
wait_port() {
  local name="$1" port="$2"
  for _ in $(seq 1 30); do
    if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
      pass "$name" "127.0.0.1:$port accepts a connection"
      return 0
    fi
    sleep 2
  done
  fail "$name" "no connection accepted on 127.0.0.1:$port"
}

for spec in opencode:4096 hermes:8642 hermes:9119; do
  name="${spec%%:*}"
  port="${spec##*:}"
  check_contains "$name-loopback" "127.0.0.1:$port" "$bindings"
  wait_port "$name-port-$port" "$port"
done
check_absent container-wildcard "0.0.0.0:" "$bindings"
check_absent container-any-ip "[::]:" "$bindings"

# 9. Rehearse the rollback: a tag re-point moves the digest the host runs.
#    Only the harness sets ROLLBACK_REPO, to a loopback registry it controls, so
#    a normal run never touches it.
if [ -n "$ROLLBACK_REPO" ]; then
  # The auto-update timer pulls on its own schedule and would race the steps.
  systemctl stop podman-auto-update.timer >/dev/null 2>&1 || true

  # RepoDigests, not the image ID: the runbook proves a rollback by the digest
  # the tag now names.
  running_digests() {
    local id
    id="$(podman inspect --format '{{.Image}}' "$1" 2>/dev/null || true)"
    [ -n "$id" ] || return 0
    podman image inspect --format '{{join .RepoDigests " "}}' "$id" 2>/dev/null || true
  }

  newer="$ROLLBACK_REPO:newer"
  older="$ROLLBACK_REPO:older"

  before="$(running_digests opencode)"
  if [ -n "$before" ]; then
    systemctl restart opencode.service >/dev/null 2>&1
    wait_health opencode
    check rollback-restart-stable "$before" "$(running_digests opencode)"
  else
    fail rollback-running "no RepoDigests for the running opencode image"
  fi

  if podman pull "$older" >/dev/null 2>&1; then
    pass rollback-pull-older "$older"
  else
    fail rollback-pull-older "$older"
  fi

  # Re-point the tag exactly as the runbook re-points :prod: tag the local image,
  # push the tag, and keep the digest the push wrote.
  if podman tag "$older" "$newer" >/dev/null 2>&1 \
    && podman push --tls-verify=false --digestfile "$report_dir/rollback-digest" \
      "$newer" >/dev/null 2>&1; then
    pass rollback-repoint "$newer"
  else
    fail rollback-repoint "$newer"
  fi
  expected="$(cat "$report_dir/rollback-digest" 2>/dev/null || true)"

  podman pull "$newer" >/dev/null 2>&1 || true
  systemctl restart opencode.service >/dev/null 2>&1
  wait_health opencode
  after="$(running_digests opencode)"
  check_contains rollback-digest "$expected" "$after"
  if [ -z "$before" ] || [ "$after" = "$before" ]; then
    fail rollback-changed "the digest did not move after the re-point: $after"
  else
    pass rollback-changed "$after"
  fi
fi

# 10. The invariant that survives every layer: nothing listens on a wildcard
#     address. Run last so the containers are included. Name the owning process,
#     because a wildcard listener here is either ours or an OS daemon to disable.
wildcards="$(ss -ltnp 2>/dev/null | awk 'NR > 1 && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/) { print $4, $6 }')"
if [ -z "$wildcards" ]; then
  pass no-wildcard-listeners "none"
else
  fail no-wildcard-listeners "$wildcards"
fi

say "SUMMARY failures=$failures"

if [ "$agent_up" = 1 ]; then
  if ! curl -fsS --max-time 60 -X POST --data-binary "@$report" "$AGENT_URL/report" >/dev/null; then
    echo "could not post the report; it stays at $report" >&2
  fi
fi

# Keep a copy on the data disk, which the host can read even when the agent
# never came up. Only when /srv is really the mounted disk: writing to the OS
# disk would hide a failed mount behind a file that looks like the real one.
if mountpoint -q /srv; then
  cat "$report" > /srv/devbox-vm-report.txt 2>/dev/null || true
fi

# Only a passing run writes the marker the check unit's condition looks for. A
# failed run leaves it absent, so the next boot repeats the check instead of
# hiding the failure behind a completed oneshot.
if [ "$failures" -eq 0 ]; then
  touch "$report_dir/checked"
fi
[ "$failures" -eq 0 ]
