#
# EC2 instances. Single mode: one Liferay instance in a public subnet (no NAT gateway needed;
# only the load balancer can reach it). HA mode: Liferay nodes in private subnets across two
# Availability Zones, plus one Elasticsearch instance.
#

resource "aws_instance" "liferay" {
  count = local.node_count

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.liferay_instance_type
  subnet_id              = local.ha ? aws_subnet.private[count.index % 2].id : aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.liferay.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    bucket = aws_s3_bucket.artifacts.bucket
    region = var.region
    host_env = merge(local.host_env_common, {
      ROLE         = "liferay"
      CLUSTER_SIZE = tostring(local.node_count)
      DB_HOST      = local.ha ? aws_db_instance.main[0].address : "127.0.0.1"
      ES_URL       = local.ha ? "http://${aws_instance.search[0].private_ip}:9200" : "http://127.0.0.1:9200"
      EFS_ID       = local.ha ? aws_efs_file_system.doclib[0].id : ""
      DOCLIB_DIR   = local.ha ? "/mnt/efs/document_library" : "/var/lib/liferay-ec2/document_library"
    })
  })

  tags = {
    Name        = "${var.name}-liferay-${count.index + 1}"
    LiferayRole = "liferay"
  }

  # Later AMI releases and user data edits must not replace a running node. To pick them up,
  # replace instances deliberately: terraform apply -replace='aws_instance.liferay[0]'
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_s3_object.host_files,
    aws_s3_object.license,
    aws_nat_gateway.main,
    aws_route_table_association.private,
    aws_efs_mount_target.doclib,
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.admin_password,
  ]
}

resource "aws_instance" "search" {
  count = local.ha ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.search_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.search[0].id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    bucket = aws_s3_bucket.artifacts.bucket
    region = var.region
    host_env = merge(local.host_env_common, {
      ROLE         = "search"
      CLUSTER_SIZE = "0"
      DB_HOST      = ""
      ES_URL       = "http://127.0.0.1:9200"
      EFS_ID       = ""
      DOCLIB_DIR   = ""
    })
  })

  tags = {
    Name        = "${var.name}-search"
    LiferayRole = "search"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_s3_object.host_files,
    aws_nat_gateway.main,
    aws_route_table_association.private,
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.admin_password,
  ]
}
