#!/usr/bin/env bash
# Assert a Terraform plan JSON describes no public ingress.
#
# Usage: no_public_ip.sh <plan.json>
#
# Reads `terraform show -json` output. Two independent checks:
#   1. no public IP is associated with anything (a NIC would carry
#      public_ip_address_id)
#   2. no NSG rule allows inbound traffic from the internet
#
# A malformed plan must fail loudly rather than read as clean. Swallowing jq's
# stderr here would make the whole check fail open, which is the failure mode
# this test exists to prevent.
set -euo pipefail

plan="${1:?usage: no_public_ip.sh <plan.json>}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$plan" ] || fail "no such plan file: $plan"
jq -e . "$plan" >/dev/null 2>&1 || fail "not valid JSON: $plan"

# 1. Any non-null public_ip_address_id anywhere in the plan.
if jq -e '[paths(scalars) as $p
           | select($p[-1] == "public_ip_address_id")
           | getpath($p) | select(. != null)] | length > 0' "$plan" >/dev/null; then
  fail "a public IP is attached"
fi

# 2. Any inbound Allow rule whose source is the internet or a wildcard.
if jq -e '[.. | objects | select(has("security_rule")) | .security_rule[]?
           | select(.direction == "Inbound" and .access == "Allow"
                    and (.source_address_prefix == "Internet"
                         or .source_address_prefix == "*"))] | length > 0' "$plan" >/dev/null; then
  fail "an inbound allow rule reaches the internet"
fi

echo "no public ingress"
