#!/usr/bin/env bash
#
# Runs one shell command on the instances of a stack through SSM and prints each output.
# Handy for the verification steps, and to re-run the bootstrap after changing the host files.
#
# Usage: scripts/run-on-stack.sh <stack-name> <role: liferay|search|all> '<command>'
#   scripts/run-on-stack.sh liferay-poc all 'sudo /opt/liferay-ec2/scripts/verify-node.sh'
#   scripts/run-on-stack.sh liferay-poc liferay 'docker logs --tail 50 liferay'

set -uo pipefail

STACK="${1:?Usage: run-on-stack.sh <stack> <role> '<command>'}"
ROLE="${2:?Usage: run-on-stack.sh <stack> <role> '<command>'}"
COMMAND="${3:?Usage: run-on-stack.sh <stack> <role> '<command>'}"

FILTERS=("Name=tag:LiferayStack,Values=${STACK}" "Name=instance-state-name,Values=running")
[ "${ROLE}" = "all" ] || FILTERS+=("Name=tag:LiferayRole,Values=${ROLE}")

INSTANCES=$(aws ec2 describe-instances --filters "${FILTERS[@]}" --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "${INSTANCES}" ] || { echo "No running instances for ${STACK} (${ROLE})"; exit 1; }

# shellcheck disable=SC2086 # INSTANCES is a space-separated list of IDs
COMMAND_ID=$(aws ssm send-command --document-name AWS-RunShellScript --instance-ids ${INSTANCES} \
	--parameters "$(jq -n --arg c "${COMMAND}" '{commands: [$c], executionTimeout: ["3600"]}')" \
	--query 'Command.CommandId' --output text)

RESULT=0

for INSTANCE in ${INSTANCES}; do
	until STATUS=$(aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE}" --query Status --output text 2> /dev/null) \
		&& [[ "${STATUS}" != "Pending" && "${STATUS}" != "InProgress" && "${STATUS}" != "Delayed" ]]; do
		sleep 5
	done

	NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE}" "Name=key,Values=Name" --query 'Tags[0].Value' --output text)
	echo "--- ${NAME} (${INSTANCE}): ${STATUS}"
	aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE}" \
		--query '[StandardOutputContent, StandardErrorContent]' --output text
	[ "${STATUS}" = "Success" ] || RESULT=1
done

exit "${RESULT}"
