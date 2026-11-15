#!/usr/bin/env bash
# host/tests/test_kickstart_data.sh
#
# The data partition is on the same disk as the OS, so the reinstall kickstart is
# the only thing between a reinstall and /srv. Parse the documents and assert the
# three properties that keep it: no table reset, every partition addressed
# explicitly, and the data partition attached without formatting.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ks="$here/../kickstart"
first="$ks/devbox-first.ks"
reinstall="$ks/devbox-reinstall.ks"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -s "$first" ] || fail "the first-install kickstart is missing"
[ -s "$reinstall" ] || fail "the reinstall kickstart is missing"

# T1: the reinstall never rewrites the partition table.
grep -qa '^clearpart --none$' "$reinstall" \
  || fail "T1 the reinstall does not pin clearpart --none"
grep -qa 'clearpart --all' "$reinstall" \
  && fail "T1 the reinstall clears all partitions"

# T2: the data partition is used as it is, never created or formatted.
data_line="$(grep -a '^part[[:space:]]\+/srv' "$reinstall" || true)"
[ -n "$data_line" ] || fail "T2 the reinstall does not mount /srv"
case "$data_line" in
  *--onpart=nvme0n1p4*) ;;
  *) fail "T2 the reinstall does not address the data partition by device" ;;
esac
case "$data_line" in
  *--noformat*) ;;
  *) fail "T2 the reinstall would format the data partition" ;;
esac
case "$data_line" in
  *--fstype*) fail "T2 the reinstall names a filesystem for the data partition" ;;
esac

# T3: every partition the reinstall touches is addressed explicitly, so a
# layout change cannot silently move a format onto the data partition. Count
# occurrences, not lines: two --onpart flags on one line must not pass.
parts="$(grep -ac '^part ' "$reinstall")"
onpart="$(grep -ao -- '--onpart=' "$reinstall" | wc -l)"
onpart="${onpart//[[:space:]]/}"
[ "$parts" -eq 4 ] || fail "T3 the reinstall declares $parts partitions, not 4"
[ "$onpart" -eq "$parts" ] || fail "T3 a reinstall partition is not pinned with --onpart"

# T4: the first install creates the labelled data partition.
grep -qa 'label=data' "$first" || fail "T4 the first install does not label /srv"
grep -qa -- '--grow' "$first" || fail "T4 the data partition does not take the rest"

# T5: neither file carries a credential. The root password is typed at the
# console, and no SSH key exists because Tailscale SSH authorises an identity.
# Comments are stripped first, so prose that names the absent directives cannot
# pass or fail this check.
for f in "$first" "$reinstall"; do
  if grep -v '^[[:space:]]*#' "$f" | grep -Eiaq 'rootpw|--password|sshkey|authorized_keys'; then
    fail "T5 $(basename "$f") carries a credential"
  fi
done

# T6: both files pin the one disk, so the installer cannot choose another.
for f in "$first" "$reinstall"; do
  grep -qa '^ignoredisk --only-use=nvme0n1$' "$f" \
    || fail "T6 $(basename "$f") does not pin the install disk"
done

echo "the reinstall kickstart never formats the data partition"
