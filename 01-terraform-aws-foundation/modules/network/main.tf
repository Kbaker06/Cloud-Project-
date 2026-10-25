data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones / Wavelength zones don't support every service; stay on regular AZs.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve the VPC into /20s (4096 IPs each): public 0-3, private 4-7, database 8-11.
  # Private gets the big blocks because that's where ECS tasks / pods consume IPs.
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i)]
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i + 4)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i + 8)]

  nat_count = {
    single = 1
    per_az = var.az_count
    none   = 0
  }[var.nat_gateway_mode]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Lock down the default SG so nothing accidentally lands in an allow-all group.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  # Instances in public subnets still must opt in to a public IP. ALBs don't need it.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "database" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.database_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-db-${local.azs[count.index]}"
    Tier = "database"
  })
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
}

# One private route table per AZ so per_az NAT can route each AZ to its own gateway.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = local.nat_count > 0 ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # single mode: every AZ uses NAT 0. per_az: each AZ uses its own.
  nat_gateway_id = aws_nat_gateway.this[min(count.index, local.nat_count - 1)].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Database subnets get a route table with NO default route: they can never reach the internet.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-database" })
}

resource "aws_route_table_association" "database" {
  count          = var.az_count
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# ---------------------------------------------------------------------------
# VPC endpoints
# ---------------------------------------------------------------------------
# S3 gateway endpoint is free and keeps ECR layer pulls + S3 traffic off the NAT bill.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_security_group" "endpoints" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.cidr_block
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix        = "${var.name}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  tags            = var.tags
}
