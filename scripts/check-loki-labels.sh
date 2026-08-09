#!/usr/bin/env bash
# Query Grafana Cloud Loki for active log_source label values over the last 24h
# and verify all expected values are present.  Exits non-zero listing any
# missing values — for use as a runbook check or alert trigger.
#
# Requires: curl, jq
# Env: GRAFANA_URL, GRAFANA_SA_TOKEN (from direnv .envrc)

set -euo pipefail

: "${GRAFANA_URL:?GRAFANA_URL must be set (e.g. https://lentago.grafana.net)}"
: "${GRAFANA_SA_TOKEN:?GRAFANA_SA_TOKEN must be set}"

# Expected log_source label values — the Alloy pipeline contract (see CLAUDE.md § Loki labels)
EXPECTED=(zeek_dns zeek_conn zeek_ssl zeek_http zeek_files zeek_notice zeek_weird firewalla_acl)

# Loki datasource UID as provisioned by Grafana Cloud for the lentago stack
LOKI_UID="grafanacloud-logs"

info() { echo "[INFO]  $*"; }
fail() { echo "[FAIL]  $*" >&2; exit 1; }

# 24h window as Unix nanoseconds (Loki label-values API format)
now_s=$(date +%s)
start_ns=$(( (now_s - 86400) * 1000000000 ))
end_ns=$(( now_s * 1000000000 ))

response=$(curl -sSf \
  -H "Authorization: Bearer $GRAFANA_SA_TOKEN" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${LOKI_UID}/loki/api/v1/label/log_source/values?start=${start_ns}&end=${end_ns}")

loki_status=$(echo "$response" | jq -r '.status // "error"')
[[ "$loki_status" == "success" ]] \
  || fail "Loki returned non-success status. Response: ${response:0:200}"

active=$(echo "$response" | jq -r '.data[]' | sort)

missing=()
for label in "${EXPECTED[@]}"; do
  if ! grep -qxF "$label" <<< "$active"; then
    missing+=("$label")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  info "All expected log_source values present: ${EXPECTED[*]}"
  exit 0
fi

echo "[WARN]  Missing log_source values in the last 24h: ${missing[*]}" >&2
exit 1
