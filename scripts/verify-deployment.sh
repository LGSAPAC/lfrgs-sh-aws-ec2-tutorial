#!/usr/bin/env bash
#
# End-to-end check of a deployed stack, from your workstation. Read-only.
#
#   1. Load balancer targets are healthy.
#   2. Liferay answers through the load balancer.
#   3. Every instance of the stack passes its own checks (verify-node.sh, run through SSM).
#
# Usage: scripts/verify-deployment.sh   (run from the repository root, after terraform apply)
#   Reads the stack from terraform output; set AWS_PROFILE / AWS_REGION as for Terraform.

set -uo pipefail

TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

tf_output() {
	terraform -chdir="${TF_DIR}" output -raw "$1"
}

STACK=$(tf_output stack_name)
URL=$(tf_output liferay_url)
ALB=$(tf_output alb_dns_name)
REGION=$(terraform -chdir="${TF_DIR}" console <<< 'var.region' | tr -d '"')
export AWS_DEFAULT_REGION="${REGION}"
FAILURES=0

echo "Stack ${STACK} in ${REGION}: ${URL}"
echo

echo "== 1. Load balancer targets"
TG_ARN=$(aws elbv2 describe-target-groups --names "${STACK}-liferay" --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
	--query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State, TargetHealth.Reason]' --output text
# shellcheck disable=SC2016 # backticks are JMESPath literals, not shell
UNHEALTHY=$(aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
	--query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text)
if [ "${UNHEALTHY}" = "0" ]; then
	echo "PASS  all targets healthy"
else
	echo "FAIL  ${UNHEALTHY} target(s) not healthy"
	FAILURES=$((FAILURES + 1))
fi
echo

echo "== 2. Liferay through the load balancer"
for PATH_TO_CHECK in /c/portal/robots /; do
	CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -L "http://${ALB}${PATH_TO_CHECK}")
	if [ "${CODE}" = "200" ]; then
		echo "PASS  http://${ALB}${PATH_TO_CHECK} -> ${CODE}"
	else
		echo "FAIL  http://${ALB}${PATH_TO_CHECK} -> ${CODE}"
		FAILURES=$((FAILURES + 1))
	fi
done
echo

echo "== 3. Instance checks (verify-node.sh through SSM)"
INSTANCES=$(aws ec2 describe-instances \
	--filters "Name=tag:LiferayStack,Values=${STACK}" "Name=instance-state-name,Values=running" \
	--query 'Reservations[].Instances[].InstanceId' --output text)

# shellcheck disable=SC2086 # INSTANCES is a space-separated list of IDs
COMMAND_ID=$(aws ssm send-command --document-name AWS-RunShellScript \
	--instance-ids ${INSTANCES} \
	--parameters 'commands=["/opt/liferay-ec2/scripts/verify-node.sh"]' \
	--query 'Command.CommandId' --output text)

for INSTANCE in ${INSTANCES}; do
	aws ssm wait command-executed --command-id "${COMMAND_ID}" --instance-id "${INSTANCE}" 2> /dev/null
	NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE}" "Name=key,Values=Name" --query 'Tags[0].Value' --output text)
	echo "--- ${NAME} (${INSTANCE})"
	aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE}" \
		--query 'StandardOutputContent' --output text
	STATUS=$(aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE}" --query Status --output text)
	[ "${STATUS}" = "Success" ] || FAILURES=$((FAILURES + 1))
done

echo
if [ "${FAILURES}" -eq 0 ]; then
	echo "Deployment verified"
else
	echo "${FAILURES} problem(s) found: see section 16 (Troubleshooting)"
	exit 1
fi
