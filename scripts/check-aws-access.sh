#!/usr/bin/env bash
#
# Read-only check that the current AWS credentials can reach every service this tutorial uses.
# Creates nothing and costs nothing.
#
# Usage: scripts/check-aws-access.sh <region>
#   Uses the usual AWS CLI credentials: AWS_PROFILE, aws sso login, or environment variables.

set -uo pipefail

REGION="${1:?Usage: check-aws-access.sh <region>}"
FAILURES=0

check() {
	local name="$1"
	shift

	if OUTPUT=$("$@" --region "${REGION}" 2>&1); then
		printf 'OK    %-28s %s\n' "${name}" "$(echo "${OUTPUT}" | head -1 | cut -c1-80)"
	else
		printf 'FAIL  %-28s %s\n' "${name}" "$(echo "${OUTPUT}" | tail -1 | cut -c1-120)"
		FAILURES=$((FAILURES + 1))
	fi
}

echo "Identity:"
aws sts get-caller-identity --region "${REGION}" --output json || { echo "No valid AWS credentials"; exit 1; }
echo

check "Region ${REGION}"            aws ec2 describe-availability-zones --query 'length(AvailabilityZones)' --output text
check "EC2"                         aws ec2 describe-instances --max-items 1 --query 'length(Reservations)' --output text
check "VPC quota (VPCs in use)"     aws ec2 describe-vpcs --query 'length(Vpcs)' --output text
check "Elastic IPs in use"          aws ec2 describe-addresses --query 'length(Addresses)' --output text
check "Load balancers (ELBv2)"      aws elbv2 describe-load-balancers --page-size 1 --query 'length(LoadBalancers)' --output text
check "RDS"                         aws rds describe-db-instances --max-items 1 --query 'length(DBInstances)' --output text
check "EFS"                         aws efs describe-file-systems --max-items 1 --query 'length(FileSystems)' --output text
check "S3"                          aws s3api list-buckets --max-items 1 --query 'length(Buckets)' --output text
check "ECR"                         aws ecr describe-repositories --max-items 1 --query 'length(repositories)' --output text
check "SSM"                         aws ssm describe-instance-information --max-items 1 --query 'length(InstanceInformationList)' --output text
check "IAM (roles)"                 aws iam list-roles --query 'length(Roles)' --output text
check "IAM (OIDC providers)"        aws iam list-open-id-connect-providers --query 'length(OpenIDConnectProviderList)' --output text
check "ACM"                         aws acm list-certificates --max-items 1 --query 'length(CertificateSummaryList)' --output text
check "AL2023 AMI parameter"        aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text

echo
echo "GitHub OIDC provider already in this account (set create_github_oidc_provider = false if listed):"
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2> /dev/null | tr '\t' '\n' | grep token.actions.githubusercontent.com || echo "  none"

echo
if [ "${FAILURES}" -eq 0 ]; then
	echo "All services reachable"
else
	echo "${FAILURES} service(s) failed: check the user's permissions (section 4)"
	exit 1
fi
