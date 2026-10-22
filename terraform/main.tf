data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 (x86_64). Instances ignore later AMI updates (see compute.tf).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ha         = var.deployment_mode == "ha"
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
  account_id = data.aws_caller_identity.current.account_id
  https      = var.acm_certificate_arn != ""
  node_count = local.ha ? var.liferay_node_count : 1

  # Values every instance gets in /etc/liferay-ec2/host.env (no secrets).
  host_env_common = {
    STACK           = var.name
    REGION          = var.region
    MODE            = var.deployment_mode
    RUNTIME         = var.liferay_runtime
    BUCKET          = aws_s3_bucket.artifacts.bucket
    PARAM_PREFIX    = "/${var.name}"
    LIFERAY_VERSION = var.liferay_version
    LIFERAY_IMAGE   = "liferay/dxp:${var.liferay_version}"
    LIFERAY_HEAP    = var.liferay_heap
    ES_VERSION      = var.elasticsearch_version
    ES_HEAP         = var.elasticsearch_heap
    DB_NAME         = "lportal"
    DB_USER         = "liferay"
    HTTPS           = tostring(local.https)
    VIRTUAL_HOST    = var.virtual_host
  }
}

#
# Network: two public subnets (load balancer, single-mode instance, NAT gateway) and two private
# subnets (high-availability instances, RDS, EFS), in two Availability Zones.
#

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.name }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One NAT gateway keeps the PoC cheaper. Production: one per Availability Zone.
resource "aws_eip" "nat" {
  count = local.ha ? 1 : 0

  domain = "vpc"

  tags = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  count = local.ha ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = var.name }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = local.ha ? [1] : []

    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Free gateway endpoint: S3 traffic (host files, license, builds, ECR layers) skips the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}
