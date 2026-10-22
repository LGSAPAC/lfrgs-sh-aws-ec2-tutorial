#!/usr/bin/env bash
#
# Rolls this instance's Liferay container to a new image and waits until it is ready.
# If the new image does not become ready, rolls back to the previous image and fails.
#
# Usage: sudo deploy-docker.sh <image>
#   for example 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/liferay-poc/dxp-custom:main-1a2b3c4
#
# GitHub Actions runs it on every Liferay instance through SSM, one instance at a time.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

NEW_IMAGE="${1:?Usage: deploy-docker.sh <image>}"

is_liferay_node || fail "This is not a Liferay instance (ROLE=${ROLE})"
[ "${RUNTIME}" = "docker" ] || fail "This instance uses the ${RUNTIME} runtime; use deploy-tomcat.sh"

OLD_IMAGE=$(current_liferay_image)

log "Deploying ${NEW_IMAGE} (was ${OLD_IMAGE})"

if [[ "${NEW_IMAGE}" == *.dkr.ecr.* ]]; then
	aws ecr get-login-password | docker login --username AWS --password-stdin "${NEW_IMAGE%%/*}"
fi

docker pull --quiet "${NEW_IMAGE}"

switch_to() {
	echo "$1" > "${RUNTIME_DIR}/liferay-image"
	"${LIFERAY_EC2_DIR}/scripts/render-config.sh"
	compose up -d --force-recreate liferay
}

switch_to "${NEW_IMAGE}"

if "${LIFERAY_EC2_DIR}/scripts/wait-for-liferay.sh" "${DEPLOY_TIMEOUT:-1200}"; then
	log "Deployed ${NEW_IMAGE}"
	docker image prune -f --filter "until=168h" > /dev/null
else
	log "New image did not become ready; rolling back to ${OLD_IMAGE}"
	docker logs --tail 200 liferay || true
	switch_to "${OLD_IMAGE}"
	"${LIFERAY_EC2_DIR}/scripts/wait-for-liferay.sh" "${DEPLOY_TIMEOUT:-1200}" || true
	fail "Deployment of ${NEW_IMAGE} failed; rolled back to ${OLD_IMAGE}"
fi
