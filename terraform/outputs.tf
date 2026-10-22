output "liferay_url" {
  description = "Open Liferay here (point your DNS name at the load balancer for HTTPS)."
  value       = local.https && var.virtual_host != "" ? "https://${var.virtual_host}" : "http://${aws_lb.main.dns_name}"
}

output "alb_dns_name" {
  description = "Load balancer DNS name (target of your DNS CNAME or Route 53 alias)."
  value       = aws_lb.main.dns_name
}

output "stack_name" {
  description = "Stack name: the LiferayStack tag and the SSM parameter prefix. GitHub variable LIFERAY_STACK."
  value       = var.name
}

output "deployment" {
  description = "Deployment mode and Liferay runtime."
  value       = "${var.deployment_mode} / ${var.liferay_runtime}"
}

output "liferay_instance_ids" {
  description = "Liferay instance IDs (connect with: aws ssm start-session --target <id>)."
  value       = aws_instance.liferay[*].id
}

output "search_instance_id" {
  description = "Elasticsearch instance ID (ha mode)."
  value       = local.ha ? aws_instance.search[0].id : null
}

output "db_endpoint" {
  description = "RDS endpoint (ha mode). In single mode PostgreSQL runs on the Liferay instance."
  value       = local.ha ? aws_db_instance.main[0].address : "127.0.0.1 (container on the Liferay instance)"
}

output "efs_id" {
  description = "EFS file system for Documents and Media (ha mode)."
  value       = local.ha ? aws_efs_file_system.doclib[0].id : null
}

output "artifact_bucket" {
  description = "S3 bucket for host files, the license and Tomcat builds. GitHub variable ARTIFACT_BUCKET."
  value       = aws_s3_bucket.artifacts.bucket
}

output "license_uploaded" {
  description = "Whether license_file was found and uploaded."
  value       = length(aws_s3_object.license) > 0
}

output "ecr_repository_url" {
  description = "ECR repository for the custom DXP image. GitHub variable ECR_REPOSITORY."
  value       = aws_ecr_repository.dxp.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role GitHub Actions assumes. GitHub variable AWS_ROLE_ARN."
  value       = local.github_enabled ? aws_iam_role.github_actions[0].arn : null
}

output "admin_password_command" {
  description = "Prints the generated password of test@liferay.com."
  value       = "aws ssm get-parameter --name ${aws_ssm_parameter.admin_password.name} --with-decryption --query Parameter.Value --output text --region ${var.region}"
}

output "github_variables_commands" {
  description = "Sets the sample workspace's GitHub Actions variables (section 12)."
  value = local.github_enabled ? join("\n", [
    "gh variable set AWS_REGION --repo ${var.github_repository} --body ${var.region}",
    "gh variable set AWS_ROLE_ARN --repo ${var.github_repository} --body ${aws_iam_role.github_actions[0].arn}",
    "gh variable set ECR_REPOSITORY --repo ${var.github_repository} --body ${aws_ecr_repository.dxp.repository_url}",
    "gh variable set ARTIFACT_BUCKET --repo ${var.github_repository} --body ${aws_s3_bucket.artifacts.bucket}",
    "gh variable set LIFERAY_STACK --repo ${var.github_repository} --body ${var.name}",
    "gh variable set LIFERAY_RUNTIME --repo ${var.github_repository} --body ${var.liferay_runtime}",
  ]) : null
}
