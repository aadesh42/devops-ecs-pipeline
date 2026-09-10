resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  tags = { Name = "${local.name}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_suffix = aws_lb.main.arn_suffix
  tg_suffix  = aws_lb_target_group.app.arn_suffix
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "No healthy targets behind the load balancer"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = local.tg_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-unhealthy-hosts" }
}

resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${local.name}-http-5xx"
  alarm_description   = "Elevated 5xx responses from the target group"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = local.tg_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-http-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${local.name}-high-latency"
  alarm_description   = "p95 response time above 1 second"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = local.tg_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-high-latency" }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name}-cpu-high"
  alarm_description   = "Service CPU utilization sustained above 80 percent"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-cpu-high" }
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${local.name}-memory-high"
  alarm_description   = "Service memory utilization sustained above 80 percent"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-memory-high" }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Request count and errors"
          region = var.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_suffix],
            [".", "HTTPCode_Target_2XX_Count", ".", ".", "TargetGroup", local.tg_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Response time"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_suffix, "TargetGroup", local.tg_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Healthy targets"
          region = var.region
          period = 60
          stat   = "Minimum"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_suffix, "TargetGroup", local.tg_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Task CPU and memory"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name],
            [".", "MemoryUtilization", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "Recent application logs"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}