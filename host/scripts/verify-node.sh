#!/usr/bin/env bash
#
# Checks this instance's part of the Liferay stack and prints one line per check.
# Exits non-zero if any check fails. Read-only: it changes nothing.
#
# Usage: sudo /opt/liferay-ec2/scripts/verify-node.sh
#
# The tutorial runs it at the end of each step, on each instance, through SSM.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

set +e

FAILURES=0

check() {
	local name="$1"
	shift

	if OUTPUT=$("$@" 2>&1); then
		printf 'PASS  %-34s %s\n' "${name}" "$(echo "${OUTPUT}" | head -1)"
	else
		printf 'FAIL  %-34s %s\n' "${name}" "$(echo "${OUTPUT}" | tail -1)"
		FAILURES=$((FAILURES + 1))
	fi
}

container_healthy() {
	local state

	state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1") || return 1
	echo "${state}"
	[[ "${state}" == running* ]] && [[ "${state}" != *unhealthy* ]] && [[ "${state}" != *starting* ]]
}

http_200() {
	local code

	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1")
	echo "HTTP ${code} from $1"
	[ "${code}" = "200" ]
}

tcp_open() {
	timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" && echo "$1:$2 reachable"
}

es_health() {
	local health

	health=$(curl -fsS --max-time 10 "$1/_cluster/health") || return 1
	echo "${health}" | jq -r '"status \(.status), \(.number_of_nodes) node(s)"'
	echo "${health}" | jq -e '.status != "red"' > /dev/null
}

es_plugins() {
	local plugins

	plugins=$(curl -fsS --max-time 10 "$1/_cat/plugins?h=component" | sort -u | tr '\n' ' ') || return 1
	echo "${plugins}"
	for plugin in analysis-icu analysis-kuromoji analysis-smartcn analysis-stempel; do
		[[ " ${plugins} " == *" ${plugin} "* ]] || { echo "missing ${plugin}"; return 1; }
	done
}

liferay_log() {
	"${LIFERAY_EC2_DIR}/scripts/liferay-log.sh" 2> /dev/null
}

log_contains() {
	local match

	match=$(liferay_log | grep -E "$1" | tail -1)
	[ -n "${match}" ] && echo "${match:0:120}"
}

no_license_errors() {
	if liferay_log | grep -iE 'license.*(invalid|expired|not found)' | tail -1 | grep .; then
		return 1
	fi

	echo "none found"
}

# The latest JGroups view, for example "Accepted view [ip-10-20-128-10-12345|1] (2) [...]".
cluster_members() {
	local view

	view=$(liferay_log | grep -oE 'view \[[^]]*\] \([0-9]+\)' | tail -1)
	[ -n "${view}" ] || { echo "no JGroups view in the log yet"; return 1; }
	echo "${view}"
	[[ "${view}" == *"(${CLUSTER_SIZE})" ]]
}

doclib_writable() {
	local probe

	probe="${DOCLIB_DIR}/.verify-$(hostname)"

	sudo -u "#${LIFERAY_UID}" touch "${probe}" && rm -f "${probe}" && df -h "${DOCLIB_DIR}" | awk 'NR==2 {print $1" "$5" used"}'
}

echo "Stack ${STACK} | mode ${MODE} | role ${ROLE} | runtime ${RUNTIME} | $(imds instance-id) $(imds local-ipv4)"
echo

check "Bootstrap finished" test -f "${RUNTIME_DIR}/bootstrap.done"
check "Docker running" systemctl is-active docker

if [ "${MODE}" = "single" ]; then
	check "PostgreSQL container" container_healthy postgres
	check "PostgreSQL accepts connections" docker exec postgres pg_isready -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}"
fi

if [ "${MODE}" = "single" ] || [ "${ROLE}" = "search" ]; then
	check "Elasticsearch container" container_healthy elasticsearch
	check "Elasticsearch cluster health" es_health http://127.0.0.1:9200
	check "Elasticsearch analysis plugins" es_plugins http://127.0.0.1:9200
	# shellcheck disable=SC2016 # expanded by the inner bash
	check "vm.max_map_count >= 262144" bash -c '[ "$(sysctl -n vm.max_map_count)" -ge 262144 ] && sysctl -n vm.max_map_count'
fi

if is_liferay_node; then
	if [ "${RUNTIME}" = "docker" ]; then
		check "Liferay container" container_healthy liferay
		check "Liferay image" docker inspect --format '{{.Config.Image}}' liferay
	else
		check "Liferay service" systemctl is-active liferay
		check "Liferay bundle version" cat "${LIFERAY_HOME}/.liferay-ec2-version"
	fi

	check "Database reachable" tcp_open "${DB_HOST}" 5432
	check "Elasticsearch reachable" es_health "${ES_URL}"
	check "Liferay HTTP on 8080" http_200 http://127.0.0.1:8080/c/portal/robots
	check "Server started" log_contains 'Server startup in'
	check "License registered" log_contains '[Ll]icense (registered|validation passed)|[Ll]icense.*valid'
	check "No license errors" no_license_errors
	check "Documents and Media writable" doclib_writable

	if [ "${MODE}" = "ha" ]; then
		check "EFS mounted" bash -c 'mountpoint /mnt/efs && findmnt -n -o SOURCE /mnt/efs'
		check "Cluster members = ${CLUSTER_SIZE}" cluster_members
	fi
fi

echo
if [ "${FAILURES}" -eq 0 ]; then
	echo "All checks passed"
else
	echo "${FAILURES} check(s) failed"
	exit 1
fi
