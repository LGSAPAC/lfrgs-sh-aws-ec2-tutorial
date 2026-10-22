variable "region" {
  description = "AWS region for every resource, for example ap-northeast-1."
  type        = string
}

variable "name" {
  description = "Stack name. Prefixes resource names, tags the instances (LiferayStack) and names the SSM parameters (/<name>/...)."
  type        = string
  default     = "liferay-poc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name))
    error_message = "Use 3 to 24 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "deployment_mode" {
  description = "single: one EC2 instance runs Liferay, PostgreSQL and Elasticsearch. ha: an ALB in front of several Liferay instances, RDS Multi-AZ, EFS and a search instance."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "ha"], var.deployment_mode)
    error_message = "deployment_mode must be single or ha."
  }
}

variable "liferay_runtime" {
  description = "docker: Liferay runs as a container from the official (or your custom) image. tomcat: Liferay runs from the Tomcat bundle as a systemd service."
  type        = string
  default     = "docker"

  validation {
    condition     = contains(["docker", "tomcat"], var.liferay_runtime)
    error_message = "liferay_runtime must be docker or tomcat."
  }
}

variable "liferay_version" {
  description = "Liferay DXP release, as in releases.liferay.com. Sets the stock Docker image tag and the Tomcat bundle."
  type        = string
  default     = "2026.q1.13-lts"
}

variable "elasticsearch_version" {
  description = "Elasticsearch version for the search service. 8.19.20 is the sidecar version DXP 2026.Q1.13 ships."
  type        = string
  default     = "8.19.20"
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer on ports 80 and 443. Restrict this to your own IP for a PoC."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block of the new VPC. Two public and two private /20 subnets are carved from it."
  type        = string
  default     = "10.20.0.0/16"
}

variable "liferay_node_count" {
  description = "Number of Liferay instances in ha mode (spread across two Availability Zones). Ignored in single mode."
  type        = number
  default     = 2

  validation {
    condition     = var.liferay_node_count >= 2 && var.liferay_node_count <= 6
    error_message = "Use 2 to 6 Liferay nodes."
  }
}

variable "liferay_instance_type" {
  description = "Instance type for Liferay. In single mode it also runs PostgreSQL and Elasticsearch."
  type        = string
  default     = "m6i.xlarge"
}

variable "liferay_heap" {
  description = "Liferay JVM heap (-Xms and -Xmx). About half of the instance memory when it shares the instance (single), more when it does not."
  type        = string
  default     = "6g"
}

variable "search_instance_type" {
  description = "Instance type for the Elasticsearch instance (ha mode)."
  type        = string
  default     = "m6i.large"
}

variable "elasticsearch_heap" {
  description = "Elasticsearch JVM heap. Up to half the memory of the instance it runs on."
  type        = string
  default     = "2g"
}

variable "db_instance_class" {
  description = "RDS instance class (ha mode)."
  type        = string
  default     = "db.m6g.large"
}

variable "db_engine_version" {
  description = "RDS PostgreSQL major version (ha mode). Check it is in the DXP 2026.Q1 compatibility matrix."
  type        = string
  default     = "16"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB for each instance. In single mode it also holds the database, the search index and Documents and Media."
  type        = number
  default     = 100
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on the load balancer. Leave empty for HTTP only (testing)."
  type        = string
  default     = ""
}

variable "virtual_host" {
  description = "Host name users browse to, for example liferay.example.com. Sets company.default.virtual.host.name. Leave empty to use the load balancer's DNS name."
  type        = string
  default     = ""
}

variable "license_file" {
  description = "Path to your Liferay DXP activation key (XML), uploaded to the artifact bucket. Never commit the file."
  type        = string
  default     = "../license/license.xml"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose Actions may push images and deploy, for example LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace. Empty skips the CI/CD role."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set to false if the account already has one for token.actions.githubusercontent.com."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Let terraform destroy delete the non-empty S3 bucket and ECR repository, and skip the final RDS snapshot. Keep true for a PoC only."
  type        = bool
  default     = true
}
