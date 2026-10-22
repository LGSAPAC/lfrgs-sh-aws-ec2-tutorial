#!/usr/bin/env bash
#
# Waits until Liferay on this instance answers on port 8080, the same check the load balancer uses.
#
# Usage: wait-for-liferay.sh [timeout-seconds]   (default 1200)

set -euo pipefail

TIMEOUT="${1:-1200}"
URL=http://127.0.0.1:8080/c/portal/robots
DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "Waiting up to ${TIMEOUT}s for ${URL} ..."

until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${URL}")" = "200" ]; do
	if [ "$(date +%s)" -gt "${DEADLINE}" ]; then
		echo "Liferay did not become ready within ${TIMEOUT}s" >&2
		exit 1
	fi

	sleep 15
done

echo "Liferay is ready"
