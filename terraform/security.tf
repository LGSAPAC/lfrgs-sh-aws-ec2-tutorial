#
# Security groups. Nothing accepts SSH: administrators use SSM Session Manager.
#

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Liferay load balancer"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.https ? toset(var.allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_liferay" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Liferay HTTP"
  referenced_security_group_id = aws_security_group.liferay.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_security_group" "liferay" {
  name        = "${var.name}-liferay"
  description = "Liferay instances"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-liferay" }
}

resource "aws_vpc_security_group_ingress_rule" "liferay_from_alb" {
  security_group_id            = aws_security_group.liferay.id
  description                  = "HTTP from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

# Cluster Link (JGroups control 7800 and transport 7801) between Liferay nodes only.
resource "aws_vpc_security_group_ingress_rule" "liferay_cluster" {
  count = local.ha ? 1 : 0

  security_group_id            = aws_security_group.liferay.id
  description                  = "Liferay Cluster Link (JGroups TCP)"
  referenced_security_group_id = aws_security_group.liferay.id
  ip_protocol                  = "tcp"
  from_port                    = 7800
  to_port                      = 7801
}

resource "aws_vpc_security_group_egress_rule" "liferay_all" {
  security_group_id = aws_security_group.liferay.id
  description       = "Outbound (images, bundle, AWS APIs, RDS, EFS, search)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "search" {
  count = local.ha ? 1 : 0

  name        = "${var.name}-search"
  description = "Elasticsearch instance"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-search" }
}

resource "aws_vpc_security_group_ingress_rule" "search_from_liferay" {
  count = local.ha ? 1 : 0

  security_group_id            = aws_security_group.search[0].id
  description                  = "Elasticsearch HTTP from Liferay"
  referenced_security_group_id = aws_security_group.liferay.id
  ip_protocol                  = "tcp"
  from_port                    = 9200
  to_port                      = 9200
}

resource "aws_vpc_security_group_egress_rule" "search_all" {
  count = local.ha ? 1 : 0

  security_group_id = aws_security_group.search[0].id
  description       = "Outbound (images, AWS APIs)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  count = local.ha ? 1 : 0

  name        = "${var.name}-db"
  description = "RDS PostgreSQL"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_liferay" {
  count = local.ha ? 1 : 0

  security_group_id            = aws_security_group.db[0].id
  description                  = "PostgreSQL from Liferay"
  referenced_security_group_id = aws_security_group.liferay.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "efs" {
  count = local.ha ? 1 : 0

  name        = "${var.name}-efs"
  description = "EFS for Documents and Media"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-efs" }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_liferay" {
  count = local.ha ? 1 : 0

  security_group_id            = aws_security_group.efs[0].id
  description                  = "NFS from Liferay"
  referenced_security_group_id = aws_security_group.liferay.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}
