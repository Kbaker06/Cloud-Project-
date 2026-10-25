locals {
  https_enabled = var.certificate_arn != null
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public ingress to ${var.name} ALB"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirects to HTTPS when a certificate is configured)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = local.https_enabled ? toset(var.ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Egress is restricted to the VPC: the ALB only ever talks to targets.
data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "to_vpc" {
  security_group_id = aws_security_group.alb.id
  description       = "To targets inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_lb" "this" {
  name               = substr(var.name, 0, 32)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60

  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [1]
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.name
      enabled = true
    }
  }

  tags = var.tags
}

# HTTP listener: redirect to HTTPS if we have a cert, else 404 by default (services add rules).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.https_enabled ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = local.https_enabled ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "not found"
        status_code  = "404"
      }
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }

  tags = var.tags
}
