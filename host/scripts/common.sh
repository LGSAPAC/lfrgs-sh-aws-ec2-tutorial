#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables below are used by the scripts that source this file
#
# Shared helpers for the scripts in /opt/liferay-ec2/scripts. Sourced, not run.
#
# /etc/liferay-ec2/host.env is written by the EC2 user data (terraform/templates/user-data.sh.tftpl)
# and holds this instance's non-secret settings. Secrets come from SSM Parameter Store at run time.

set -euo pipefail

LIFERAY_EC2_DIR=/opt/liferay-ec2
RUNTIME_DIR="${LIFERAY_EC2_DIR}/runtime"
FILES_DIR="${RUNTIME_DIR}/files"
COMPOSE_DIR="${LIFERAY_EC2_DIR}/docker"
LIFERAY_HOME=/opt/liferay
LIFERAY_UID=1000

# shellcheck source=/dev/null
source /etc/liferay-ec2/host.env

export AWS_DEFAULT_REGION="${REGION}"

log() {
	echo "[liferay-ec2 $(date -u +%H:%M:%S)] $*"
}

fail() {
	echo "[liferay-ec2 $(date -u +%H:%M:%S)] ERROR: $*" >&2
	exit 1
}

imds() {
	local token

	token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')

	curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/meta-data/$1"
}

get_secret() {
	aws ssm get-parameter --name "${PARAM_PREFIX}/$1" --with-decryption --query Parameter.Value --output text
}

# The Liferay image currently deployed: the last one deploy-docker.sh rolled out, or the stock image.
current_liferay_image() {
	if [ -s "${RUNTIME_DIR}/liferay-image" ]; then
		cat "${RUNTIME_DIR}/liferay-image"
	else
		echo "${LIFERAY_IMAGE}"
	fi
}

compose() {
	docker compose --project-directory "${COMPOSE_DIR}" "$@"
}

is_liferay_node() {
	[ "${ROLE}" = "liferay" ]
}

# Planned restarts in high availability: take this node out of the load balancer first, so
# users are moved to the other nodes instead of getting HTTP 502, and put it back once it is
# ready. Single mode has no other node to move users to, so these do nothing there.

lb_target_group_arn() {
	aws elbv2 describe-target-groups --names "${STACK}-liferay" --query 'TargetGroups[0].TargetGroupArn' --output text
}

lb_target_state() {
	aws elbv2 describe-target-health --target-group-arn "$1" --targets "Id=$2,Port=8080" \
		--query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
}

lb_drain() {
	[ "${MODE}" = "ha" ] || return 0

	local tg id state=""

	tg=$(lb_target_group_arn)
	id=$(imds instance-id)

	log "Taking this node out of the load balancer (in-flight requests finish first)"
	aws elbv2 deregister-targets --target-group-arn "${tg}" --targets "Id=${id},Port=8080"

	for _ in $(seq 1 30); do
		state=$(lb_target_state "${tg}" "${id}")
		[ "${state}" = "unused" ] && break
		sleep 5
	done

	log "Load balancer state of this node: ${state}"
}

lb_register() {
	[ "${MODE}" = "ha" ] || return 0

	local tg id state=""

	tg=$(lb_target_group_arn)
	id=$(imds instance-id)

	log "Putting this node back into the load balancer"
	aws elbv2 register-targets --target-group-arn "${tg}" --targets "Id=${id},Port=8080"

	for _ in $(seq 1 36); do
		state=$(lb_target_state "${tg}" "${id}")
		[ "${state}" = "healthy" ] && break
		sleep 5
	done

	log "Load balancer state of this node: ${state}"

	[ "${state}" = "healthy" ]
}
