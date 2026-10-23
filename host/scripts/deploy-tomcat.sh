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
# Liferay log timestamps are UTC ("2026-10-23 00:12:34.601"); only lines after this count.
DEPLOY_START=$(date -u '+%F %T')

if [ -d "${WORK}/configs" ]; then
	while IFS= read -r -d '' FILE; do
		RELATIVE="${FILE#"${WORK}/configs/"}"

		# Files render-config.sh writes (portal-ext.properties, OSGi configs, the license) belong to
		# the host: the workspace build ships an empty portal-ext.properties that would replace the
		# database and search settings.
		if [ -e "${FILES_DIR}/${RELATIVE}" ]; then
			log "Skipping ${RELATIVE}: rendered on this host"
			continue
		fi

		if ! cmp -s "${FILE}" "${LIFERAY_HOME}/${RELATIVE}"; then
			log "Config changed: ${RELATIVE}"
			install -D -o liferay -g liferay -m 644 "${FILE}" "${LIFERAY_HOME}/${RELATIVE}"
			RESTART=true
		fi
	done < <(find "${WORK}/configs" -type f -print0)
fi

install -o liferay -g liferay -m 644 "${WORK}"/deploy/* "${LIFERAY_HOME}/deploy/"

if [ "${RESTART}" = "true" ]; then
	lb_drain
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

if [ "${RESTART}" = "true" ]; then
	lb_register || fail "Liferay restarted, but the load balancer doesn't see this node as healthy"
fi

# Every jar and zip of the build must reach osgi/modules. Liferay moves them there from deploy/,
# during startup after a restart, or within seconds on a hot deploy.
MISSING=()

for ARTIFACT in "${WORK}"/deploy/*; do
	NAME=$(basename "${ARTIFACT}")

	for _ in $(seq 1 36); do
		[ -e "${LIFERAY_HOME}/osgi/modules/${NAME}" ] && break
		sleep 5
	done

	if [ -e "${LIFERAY_HOME}/osgi/modules/${NAME}" ]; then
		log "Deployed ${NAME}"
	else
		MISSING+=("${NAME}")
	fi
done

[ "${#MISSING[@]}" -eq 0 ] || fail "Not in ${LIFERAY_HOME}/osgi/modules after 3 minutes: ${MISSING[*]}"

# A hot deploy restarts each bundle in place and logs STARTED a few seconds after the file is
# picked up. Bundles installed during a restart don't log it.
# Module jars start as their symbolic name (com.liferay.ec2.sample.portlet_1.0.0), client
# extension zips as their name without hyphens (ec2samplereactapp_7.4.13).
BUNDLES=()

for ARTIFACT in "${WORK}"/deploy/*; do
	case "${ARTIFACT}" in
		*.jar) BUNDLES+=("$(unzip -p "${ARTIFACT}" META-INF/MANIFEST.MF | tr -d '\r' | sed -n 's/^Bundle-SymbolicName: *\([^;[:space:]]*\).*/\1/p')") ;;
		*.zip) BUNDLES+=("$(basename "${ARTIFACT}" .zip | tr -d '-')") ;;
	esac
done

started_since_deploy() {
	awk -v since="${DEPLOY_START}" '($1 " " substr($2, 1, 8)) >= since' "${LIFERAY_HOME}"/logs/liferay.*.log 2> /dev/null | grep -oE "STARTED $1_[^ ]+" | tail -1 || true
}

if [ "${RESTART}" = "false" ]; then
	for BUNDLE in "${BUNDLES[@]}"; do
		LINE=""

		for _ in $(seq 1 12); do
			LINE=$(started_since_deploy "${BUNDLE}")
			[ -n "${LINE}" ] && break
			sleep 5
		done

		if [ -n "${LINE}" ]; then
			log "${LINE}"
		else
			log "WARNING: no 'STARTED ${BUNDLE}' since ${DEPLOY_START} UTC; check the Liferay log"
		fi
	done
fi

log "Deployment finished"
