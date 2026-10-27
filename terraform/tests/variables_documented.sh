#!/usr/bin/env bash
# Every variable with no default must appear in terraform.tfvars.example, or an
# operator cannot know it is required until plan fails.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

example="$here/terraform.tfvars.example"
[ -s "$example" ] || fail "terraform.tfvars.example missing"

# A variable block with no `default` line is required.
required="$(awk '
  /^variable "/ { name=$2; gsub(/"/, "", name); has_default=0; inblock=1; next }
  inblock && /^[[:space:]]*default[[:space:]]*=/ { has_default=1 }
  inblock && /^}/ { if (!has_default) print name; inblock=0 }
' "$here/variables.tf")"

[ -n "$required" ] || fail "no required variables found; the awk scan is broken"

for v in $required; do
  grep -qE "^[[:space:]]*${v}[[:space:]]*=" "$example" \
    || fail "required variable not in tfvars.example: $v"
done

echo "all required variables documented"
