#
# High availability only: RDS PostgreSQL Multi-AZ and EFS for Documents and Media.
#

resource "aws_db_subnet_group" "main" {
  count = local.ha ? 1 : 0

  name       = var.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "main" {
  count = local.ha ? 1 : 0

  name   = "${var.name}-postgres${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  # Liferay connects without TLS by default; require it once the JDBC URL uses sslmode=require.
  parameter {
    name  = "rds.force_ssl"
    value = "0"
  }
}

resource "aws_db_instance" "main" {
  count = local.ha ? 1 : 0

  identifier     = var.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = "lportal"
  username = "liferay"
  password = random_password.db.result

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  parameter_group_name   = aws_db_parameter_group.main[0].name
  publicly_accessible    = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = !var.force_destroy
  skip_final_snapshot        = var.force_destroy
  final_snapshot_identifier  = var.force_destroy ? null : "${var.name}-final"
  apply_immediately          = true
}

resource "aws_efs_file_system" "doclib" {
  count = local.ha ? 1 : 0

  creation_token   = "${var.name}-doclib"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  tags = { Name = "${var.name}-doclib" }
}

resource "aws_efs_mount_target" "doclib" {
  count = local.ha ? 2 : 0

  file_system_id  = aws_efs_file_system.doclib[0].id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_efs_backup_policy" "doclib" {
  count = local.ha ? 1 : 0

  file_system_id = aws_efs_file_system.doclib[0].id

  backup_policy {
    status = "ENABLED"
  }
}
