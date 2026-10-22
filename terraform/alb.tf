#
# Application Load Balancer in front of the Liferay instance(s), in both modes. Sticky sessions
# keep each user on one node: Liferay does not replicate HTTP sessions between nodes.
#

resource "aws_lb" "main" {
  name               = var.name
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 300
}

resource "aws_lb_target_group" "liferay" {
  name                 = "${var.name}-liferay"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  # A node that stops answering is taken out after 2 failed checks 10 s apart (about 20 s).
  # With 5 checks 30 s apart, users stuck to a crashed node got HTTP 502 for about 2.5 minutes.
  # Planned restarts don't rely on this: the deploy scripts take the node out first.
  health_check {
    path                = "/c/portal/robots"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }
}

resource "aws_lb_target_group_attachment" "liferay" {
  count = local.node_count

  target_group_arn = aws_lb_target_group.liferay.arn
  target_id        = aws_instance.liferay[count.index].id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.liferay.arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.liferay.arn
  }
}
