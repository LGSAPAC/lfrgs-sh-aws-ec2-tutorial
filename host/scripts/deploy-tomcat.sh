#!/usr/bin/env bash
#
# Deploys a build from the sample workspace to this instance's Tomcat bundle.
#
# Usage: sudo deploy-tomcat.sh s3://<bucket>/builds/liferay-artifacts-<tag>.tar.gz
#
# The archive (built by the workspace's GitHub Actions workflow) holds:
#   deploy/    module jars and client extension zips  -> /opt/liferay/deploy (hot deploy)
#   configs/   configs/common merged with configs/ec2 -> /opt/liferay (restart needed if changed)
#
# Module and client extension changes deploy without a restart. If the configs changed,
# Liferay is restarted. GitHub Actions runs this on every Liferay instance through SSM,
# one instance at a time.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

ARCHIVE="${1:?Usage: deploy-tomcat.sh s3://<bucket>/builds/liferay-artifacts-<tag>.tar.gz}"

is_liferay_node || fail "This is not a Liferay instance (ROLE=${ROLE})"
[ "${RUNTIME}" = "tomcat" ] || fail "This instance uses the ${RUNTIME} runtime; use deploy-docker.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

aws s3 cp "${ARCHIVE}" "${WORK}/artifacts.tar.gz" --only-show-errors
tar -xzf "${WORK}/artifacts.tar.gz" -C "${WORK}"

log "Deploying build $(cat "${WORK}/BUILD_TAG" 2> /dev/null || echo unknown)"

RESTART=false

if [ -d "${WORK}/configs" ]; then
	while IFS= read -r -d '' FILE; do
		RELATIVE="${FILE#"${WORK}/configs/"}"

		if ! cmp -s "${FILE}" "${LIFERAY_HOME}/${RELATIVE}"; then
			log "Config changed: ${RELATIVE}"
			install -D -o liferay -g liferay -m 644 "${FILE}" "${LIFERAY_HOME}/${RELATIVE}"
			RESTART=true
		fi
	done < <(find "${WORK}/configs" -type f -print0)
fi

install -o liferay -g liferay -m 644 "${WORK}"/deploy/* "${LIFERAY_HOME}/deploy/"

if [ "${RESTART}" = "true" ]; then
	log "Restarting Liferay to apply the config changes"
	systemctl restart liferay
else
	# Liferay moves each file out of deploy/ once it has picked it up.
	log "Waiting for the hot deploy to pick up the files"
	for _ in $(seq 1 60); do
		[ -z "$(find "${LIFERAY_HOME}/deploy" -mindepth 1 -maxdepth 1 ! -name license.xml -print -quit)" ] && break
		sleep 5
	done
fi

"${LIFERAY_EC2_DIR}/scripts/wait-for-liferay.sh" "${DEPLOY_TIMEOUT:-1200}"

for JAR in "${WORK}"/deploy/*.jar; do
	[ -e "${JAR}" ] || continue
	BSN=$(unzip -p "${JAR}" META-INF/MANIFEST.MF | sed -n 's/^Bundle-SymbolicName: *\([^;[:space:]]*\).*/\1/p')

	if grep -q "STARTED ${BSN}_" "${LIFERAY_HOME}"/logs/liferay.*.log 2> /dev/null; then
		log "Module ${BSN} started"
	else
		log "WARNING: no 'STARTED ${BSN}' line in the Liferay log yet"
	fi
done

log "Deployment finished"
