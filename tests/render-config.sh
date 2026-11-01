#!/usr/bin/env bash
#
# Tests host/scripts/render-config.sh without AWS: fake `aws` (SSM, S3) and instance metadata
# replies, then checks every file it writes, in seven scenarios (single/HA, Docker/Tomcat,
# search node, HTTPS with a virtual host, MCP on/off, license present/missing).
#
# It writes to /etc/liferay-ec2 and /opt/liferay-ec2, so run it in a throwaway container,
# with the repository mounted read-only at /src:
#
#   docker run --rm -v "$PWD:/src:ro" amazonlinux:2023 bash /src/tests/render-config.sh

set -uo pipefail

SRC=${SRC:-/src}
EC2_DIR=/opt/liferay-ec2
FILES=${EC2_DIR}/runtime/files
PORTAL_EXT=${FILES}/portal-ext.properties
COMPOSE_ENV=${EC2_DIR}/docker/.env
CONFIGS=${FILES}/osgi/configs
MCP_CONFIG=${CONFIGS}/com.liferay.mcp.server.rest.internal.configuration.MCPServerConfiguration.config
ES_CONFIG=${CONFIGS}/com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config

# Letters and digits, like the password Terraform generates (random_password.db, special = false).
DB_PASSWORD=Xk9mQ2vR7tLp4Wn8Zc3Hb6Jd1Fs5Gy0A
PRIVATE_IP=10.20.11.10
ALB=liferay-poc-123.ap-northeast-1.elb.amazonaws.com

PASSED=0
FAILED=0

check() {
	local name="$1"
	shift

	if "$@" > /dev/null 2>&1; then
		echo "  PASS  ${name}"
		PASSED=$((PASSED + 1))
	else
		echo "  FAIL  ${name}"
		FAILED=$((FAILED + 1))
	fi
}

absent() {
	! "$@"
}

same_file() {
	[ "$(md5sum < "$1")" = "$(md5sum < "$2")" ]
}

# Fake aws and curl (instance metadata), first on the PATH.
STUBS=$(mktemp -d)

cat > "${STUBS}/aws" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
	"ssm get-parameter")
		case "\$*" in
			*db/password*) echo '${DB_PASSWORD}' ;;
			*liferay/admin-password*) echo 'Adm1n-Secret_9' ;;
			*) exit 254 ;;
		esac
		;;
	"s3 cp")
		[ "\${HAS_LICENSE:-1}" = 1 ] || exit 1
		echo '<license/>' > "\$4"
		;;
	*)
		echo "unexpected: aws \$*" >&2
		exit 9
		;;
esac
STUB

cat > "${STUBS}/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
	*api/token*) echo token ;;
	*meta-data/local-ipv4*) echo ${PRIVATE_IP} ;;
	*meta-data/instance-id*) echo i-0123456789abcdef0 ;;
	*) exit 7 ;;
esac
STUB

chmod +x "${STUBS}/aws" "${STUBS}/curl"
export PATH="${STUBS}:${PATH}"

# Usage: scenario <name> <mode> <role> <runtime> <https> <virtual-host> <mcp> <has-license>
scenario() {
	local name=$1 mode=$2 role=$3 runtime=$4 https=$5 vhost=$6 mcp=$7 license=$8
	local db_host=127.0.0.1 es_url=http://127.0.0.1:9200 uid=1000 profiles

	echo "== ${name}"

	if [ "${mode}" = ha ]; then
		db_host=liferay-poc.abc123.ap-northeast-1.rds.amazonaws.com
		es_url=http://10.20.12.5:9200
	fi

	if [ "${role}" = search ]; then
		db_host=""
		es_url=http://127.0.0.1:9200
	fi

	[ "${runtime}" = tomcat ] && uid=1001

	case "${mode}/${role}/${runtime}" in
		single/liferay/docker) profiles=liferay,db,search ;;
		single/liferay/tomcat) profiles=db,search ;;
		ha/liferay/docker) profiles=liferay ;;
		ha/liferay/tomcat) profiles="" ;;
		ha/search/*) profiles=search ;;
	esac

	rm -rf "${EC2_DIR}" /etc/liferay-ec2
	mkdir -p /etc/liferay-ec2 "${EC2_DIR}/docker"
	cp -r "${SRC}/host/scripts" "${SRC}/host/config" "${EC2_DIR}/"

	# Same keys as host_env in terraform/main.tf and terraform/compute.tf.
	cat > /etc/liferay-ec2/host.env <<HOSTENV
ALB_DNS_NAME=${ALB}
BUCKET=liferay-poc-artifacts
DB_NAME=lportal
DB_USER=liferay
ES_HEAP=2g
ES_VERSION=8.19.20
HTTPS=${https}
LIFERAY_HEAP=6g
LIFERAY_IMAGE=liferay/dxp:2026.q3.8
LIFERAY_VERSION=2026.q3.8
MCP_ENABLED=${mcp}
MODE=${mode}
PARAM_PREFIX=/liferay-poc
REGION=ap-northeast-1
RUNTIME=${runtime}
STACK=liferay-poc
VIRTUAL_HOST=${vhost}
ROLE=${role}
CLUSTER_SIZE=2
NODE_INDEX=1
FIRST_NODE_NAME=liferay-poc-liferay-1
DB_HOST=${db_host}
ES_URL=${es_url}
EFS_ID=
DOCLIB_DIR=/var/lib/liferay-ec2/document_library
HOSTENV

	if ! HAS_LICENSE=${license} bash "${EC2_DIR}/scripts/render-config.sh" > /tmp/render.log 2>&1; then
		check "render-config.sh exits 0" false
		cat /tmp/render.log
		return
	fi

	check "render-config.sh exits 0" true
	check ".env is mode 600" test "$(stat -c %a "${COMPOSE_ENV}")" = 600
	check "COMPOSE_PROFILES=${profiles}" grep -qx "COMPOSE_PROFILES=${profiles}" "${COMPOSE_ENV}"

	if [ "${role}" = search ]; then
		check "Elasticsearch listens on 0.0.0.0" grep -qx ES_NETWORK_HOST=0.0.0.0 "${COMPOSE_ENV}"
	else
		check "Elasticsearch listens on 127.0.0.1" grep -qx ES_NETWORK_HOST=127.0.0.1 "${COMPOSE_ENV}"
		check "portal-ext is mode 600, owned by ${uid}" test "$(stat -c '%a %u' "${PORTAL_EXT}")" = "600 ${uid}"
		check "DB password" grep -qxF "jdbc.default.password=${DB_PASSWORD}" "${PORTAL_EXT}"
		check "JDBC URL" grep -qxF "jdbc.default.url=jdbc:postgresql://${db_host}:5432/lportal" "${PORTAL_EXT}"
		check "Valid hosts: private IP and ALB" grep -q "^virtual.hosts.valid.hosts=.*,${PRIVATE_IP},${ALB}" "${PORTAL_EXT}"
		check "Elasticsearch URL" grep -qF "networkHostAddresses=[\"${es_url}\"]" "${ES_CONFIG}"

		if [ "${https}" = true ]; then
			check "web.server.protocol=https" grep -qx web.server.protocol=https "${PORTAL_EXT}"
		else
			check "No web.server.protocol" absent grep -q web.server.protocol "${PORTAL_EXT}"
		fi

		if [ -n "${vhost}" ]; then
			check "Virtual host" grep -qx "company.default.virtual.host.name=${vhost}" "${PORTAL_EXT}"
			check "Virtual host is a valid host" grep -q "^virtual.hosts.valid.hosts=.*,${vhost}$" "${PORTAL_EXT}"
		fi

		if [ "${mcp}" = true ]; then
			check "MCP feature flag" grep -qx feature.flag.LPD-63311=true "${PORTAL_EXT}"
			check "MCP configuration" test -f "${MCP_CONFIG}"
		else
			check "No MCP feature flag" absent grep -q LPD-63311 "${PORTAL_EXT}"
			check "No MCP configuration" absent test -f "${MCP_CONFIG}"
		fi

		if [ "${license}" = 1 ]; then
			check "License copied" test -f "${FILES}/deploy/license.xml"
		else
			check "No license file" absent test -f "${FILES}/deploy/license.xml"
			check "Missing license warning" grep -q 'WARNING: no license' /tmp/render.log
		fi

		if [ "${mode}" = ha ]; then
			check "Cluster Link enabled" grep -qx cluster.link.enabled=true "${PORTAL_EXT}"

			for channel in control transport; do
				check "jgroups/${channel}.xml is well-formed" xmllint --noout "${FILES}/jgroups/${channel}.xml"
				check "jgroups/${channel}.xml is filled in" absent grep -q '="@[A-Z_]*@"' "${FILES}/jgroups/${channel}.xml"
			done

			check "JGroups bind address" grep -qF "bind_addr=\"${PRIVATE_IP}\"" "${FILES}/jgroups/control.xml"
			check "JGroups DB password" grep -qF "connection_password=\"${DB_PASSWORD}\"" "${FILES}/jgroups/control.xml"
		else
			check "No Cluster Link" absent grep -q cluster.link "${PORTAL_EXT}"
		fi

		if [ "${runtime}" = tomcat ]; then
			check "tomcat.env heap" grep -qx 'LIFERAY_EC2_JVM_OPTS=-Xms6g -Xmx6g' "${EC2_DIR}/runtime/tomcat.env"
		fi
	fi

	cp "${COMPOSE_ENV}" /tmp/env.first
	HAS_LICENSE=${license} bash "${EC2_DIR}/scripts/render-config.sh" > /dev/null 2>&1
	check "Running again gives the same .env" same_file /tmp/env.first "${COMPOSE_ENV}"
}

#        name               mode   role    runtime https vhost               mcp   license
scenario single-docker      single liferay docker  false ""                  true  1
scenario single-tomcat      single liferay tomcat  false ""                  true  1
scenario single-no-license  single liferay docker  false ""                  false 0
scenario https-virtual-host single liferay docker  true  liferay.example.com true  1
scenario ha-node-docker     ha     liferay docker  false ""                  true  1
scenario ha-node-tomcat     ha     liferay tomcat  false ""                  false 1
scenario ha-search-node     ha     search  docker  false ""                  true  1

echo
echo "${PASSED} passed, ${FAILED} failed"

[ "${FAILED}" -eq 0 ]
