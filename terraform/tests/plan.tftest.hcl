# Plans and "applies" the stack against mocked providers: no AWS account, credentials or cost.
# Covers single (Docker, Tomcat) and HA with HTTPS, the security settings the guide relies on,
# and the variable validations. Run: terraform -chdir=terraform init && terraform -chdir=terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"] } }
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-0123456789abcdef0", insecure_value = "ami-0123456789abcdef0" } }
  mock_resource "aws_s3_bucket" { defaults = { bucket = "liferay-poc-artifacts-mock", arn = "arn:aws:s3:::liferay-poc-artifacts-mock" } }
  mock_resource "aws_iam_openid_connect_provider" { defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/liferay-poc-mock" } }
  mock_resource "aws_ecr_repository" { defaults = { arn = "arn:aws:ecr:ap-northeast-1:123456789012:repository/liferay-poc/dxp-custom", repository_url = "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/liferay-poc/dxp-custom" } }
  mock_resource "aws_db_instance" { defaults = { address = "db.mock.local", arn = "arn:aws:rds:ap-northeast-1:123456789012:db:mock" } }
  mock_resource "aws_efs_file_system" { defaults = { arn = "arn:aws:elasticfilesystem:ap-northeast-1:123456789012:file-system/fs-mock", dns_name = "fs-mock.efs.local" } }
  mock_resource "aws_instance" { defaults = { private_ip = "10.20.11.10", arn = "arn:aws:ec2:ap-northeast-1:123456789012:instance/i-mock" } }
  mock_resource "aws_lb" { defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/mock/1", dns_name = "mock.elb.amazonaws.com" } }
  mock_resource "aws_lb_target_group" { defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/mock/1" } }
  mock_resource "aws_ssm_parameter" { defaults = { arn = "arn:aws:ssm:ap-northeast-1:123456789012:parameter/liferay-poc/mock" } }
}
mock_provider "random" {}

variables {
  region            = "ap-northeast-1"
  name              = "liferay-poc"
  allowed_cidrs     = ["203.0.113.10/32"]
  license_file      = "./tests/fake-license.xml"
  github_repository = "LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace"
}

run "single_docker" {
  command = apply
  variables {
    deployment_mode = "single"
    liferay_runtime = "docker"
  }
  assert {
    condition     = length(aws_instance.liferay) == 1 && length(aws_instance.search) == 0 && length(aws_db_instance.main) == 0
    error_message = "single mode must create exactly one Liferay instance and no search/RDS"
  }
  assert {
    condition     = alltrue([for i in aws_instance.liferay : i.metadata_options[0].http_tokens == "required"])
    error_message = "IMDSv2 must be required"
  }
  assert {
    condition     = alltrue([for i in aws_instance.liferay : i.root_block_device[0].encrypted])
    error_message = "root volumes must be encrypted"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.liferay_from_alb.referenced_security_group_id == aws_security_group.alb.id && aws_vpc_security_group_ingress_rule.liferay_from_alb.cidr_ipv4 == null
    error_message = "Liferay must accept traffic only from the ALB security group"
  }
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.alb_http : r.cidr_ipv4]) == toset(["203.0.113.10/32"])
    error_message = "ALB port 80 must be open only to allowed_cidrs"
  }
  assert {
    condition     = aws_lb.main.drop_invalid_header_fields
    error_message = "the ALB must drop invalid HTTP header fields"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_https) == 0 && length(aws_lb_listener.https) == 0
    error_message = "no HTTPS listener without a certificate"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.block_public_acls && aws_s3_bucket_public_access_block.artifacts.block_public_policy && aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets && aws_s3_bucket_public_access_block.artifacts.ignore_public_acls
    error_message = "S3 bucket must block all public access"
  }
  assert {
    condition     = length(aws_s3_object.license) == 1
    error_message = "license must be uploaded when the file exists"
  }
  assert {
    condition     = length(aws_iam_role.github_actions) == 1
    error_message = "GitHub Actions role expected when github_repository is set"
  }
  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "repo:LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace:")
    error_message = "OIDC trust must be scoped to the workspace repo"
  }
}

run "single_tomcat" {
  command = apply
  variables {
    deployment_mode = "single"
    liferay_runtime = "tomcat"
  }
  assert {
    condition     = length(aws_instance.liferay) == 1
    error_message = "tomcat single mode must plan one instance"
  }
}

run "ha_docker_https" {
  command = apply
  variables {
    deployment_mode            = "ha"
    liferay_runtime            = "docker"
    liferay_node_count         = 3
    acm_certificate_arn        = "arn:aws:acm:ap-northeast-1:123456789012:certificate/mock"
    github_oidc_subject_prefix = "repo:LGSAPAC@1/lfrgs-sh-aws-ec2-sample-workspace@2"
  }
  assert {
    condition     = length(aws_instance.liferay) == 3 && length(aws_instance.search) == 1
    error_message = "HA must create node_count Liferay nodes and one search node"
  }
  assert {
    condition     = aws_db_instance.main[0].storage_encrypted && aws_db_instance.main[0].multi_az && !aws_db_instance.main[0].publicly_accessible
    error_message = "RDS must be encrypted, Multi-AZ, private"
  }
  assert {
    condition     = aws_efs_file_system.doclib[0].encrypted
    error_message = "EFS must be encrypted"
  }
  assert {
    condition     = length(aws_lb_listener.https) == 1 && aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "HTTPS listener with TLS 1.2+ policy expected"
  }
  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "repo:LGSAPAC@1/lfrgs-sh-aws-ec2-sample-workspace@2:")
    error_message = "immutable OIDC subject prefix must be used"
  }
}

run "no_github_no_license" {
  command = apply
  variables {
    github_repository = ""
    license_file      = "./tests/does-not-exist.xml"
  }
  assert {
    condition     = length(aws_iam_role.github_actions) == 0 && length(aws_s3_object.license) == 0
    error_message = "no CI role without repo; no license object without file"
  }
}

run "reject_bad_name" {
  command = plan
  variables { name = "Bad_Name" }
  expect_failures = [var.name]
}
run "reject_bad_mode" {
  command = plan
  variables { deployment_mode = "cluster" }
  expect_failures = [var.deployment_mode]
}
run "reject_bad_runtime" {
  command = plan
  variables { liferay_runtime = "jboss" }
  expect_failures = [var.liferay_runtime]
}
run "reject_one_ha_node" {
  command = plan
  variables { liferay_node_count = 1 }
  expect_failures = [var.liferay_node_count]
}
run "reject_bad_oidc_prefix" {
  command = plan
  variables { github_oidc_subject_prefix = "LGSAPAC/x" }
  expect_failures = [var.github_oidc_subject_prefix]
}
