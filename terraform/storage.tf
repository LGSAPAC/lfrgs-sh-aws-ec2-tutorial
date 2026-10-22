#
# Artifact bucket: host files (scripts, Compose file, templates), the license, and Tomcat builds.
#

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${local.account_id}-${var.region}"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-builds"
    status = "Enabled"

    filter {
      prefix = "builds/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Everything under ../host is copied to /opt/liferay-ec2 on each instance at boot.
resource "aws_s3_object" "host_files" {
  for_each = fileset("${path.module}/../host", "**")

  bucket = aws_s3_bucket.artifacts.id
  key    = "host/${each.value}"
  source = "${path.module}/../host/${each.value}"
  etag   = filemd5("${path.module}/../host/${each.value}")
}

# Uploaded only if the file exists; bootstrap warns when it is missing.
resource "aws_s3_object" "license" {
  count = fileexists(var.license_file) ? 1 : 0

  bucket = aws_s3_bucket.artifacts.id
  key    = "license/license.xml"
  source = var.license_file
  etag   = filemd5(var.license_file)
}

#
# Container registry for the custom DXP image built by the sample workspace.
#

resource "aws_ecr_repository" "dxp" {
  name                 = "${var.name}/dxp-custom"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.force_destroy

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "dxp" {
  repository = aws_ecr_repository.dxp.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

#
# Secrets in SSM Parameter Store, read by the instances at boot. They are also in the Terraform
# state: keep the state private (section 6).
#

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length           = 20
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "-_!"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.name}/db/password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "/${var.name}/liferay/admin-password"
  type  = "SecureString"
  value = random_password.admin.result
}
