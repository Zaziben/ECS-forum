provider "aws" {
  region = var.aws_region
}

locals {
  subnet_ids = [
    "subnet-048916d83b3d6dcf1",
  ]
}

# ECS CLUSTER
resource "aws_ecs_cluster" "phpbb" {
  name = var.cluster_name

  tags = {
    Environment = "prod"
    Terraform   = "true"
  }
}

# EFS 
resource "aws_efs_file_system" "phpbb" {
  creation_token = "phpbb-efs"
  encrypted      = true

  tags = {
    Name      = "phpbb-efs"
    Terraform = "true"
  }
}

resource "aws_efs_mount_target" "phpbb" {
  file_system_id  = aws_efs_file_system.phpbb.id
  subnet_id       = local.subnet_ids[0]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "phpbb" {
  file_system_id = aws_efs_file_system.phpbb.id

  posix_user {
    uid = 33 # www-data
    gid = 33
  }

  root_directory {
    path = "/phpbb"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "755"
    }
  }
}



resource "aws_security_group" "ecs_task" {
  name        = "phpbb-ecs-task-sg"
  description = "Allow inbound HTTP from CloudFront only"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    # CloudFront managed prefix list - only allows CloudFront IPs
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs" {
  name        = "phpbb-efs-sg"
  description = "Allow NFS from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


data "terraform_remote_state" "statics" { # importing outputs from other folder
  backend = "local"
  config = {
    path = "../statics/terraform.tfstate"
  }
}

resource "aws_iam_role" "ecs_execution" {
  name = "phpbb-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM - ECS TASK ROLE
resource "aws_iam_role" "ecs_task" {
  name = "phpbb-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_s3_bucket" "s3" {
  bucket = "dnd-forum-s3-jv"
}

data "aws_iam_policy_document" "phpbb_s3_access" {
  statement {
    sid     = "ListBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::dnd-forum-s3-jv"]
  }

  statement {
    sid    = "ObjectAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:DeleteObject"
    ]
    resources = ["arn:aws:s3:::dnd-forum-s3-jv/*"]
  }
}

resource "aws_iam_policy" "phpbb_s3_policy" {
  name   = "phpbb-s3-policy"
  policy = data.aws_iam_policy_document.phpbb_s3_access.json
}

resource "aws_iam_role_policy_attachment" "phpbb_s3_attach" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.phpbb_s3_policy.arn
}


# CLOUDWATCH LOG GROUP
resource "aws_cloudwatch_log_group" "phpbb" {
  name              = "/ecs/phpbb"
  retention_in_days = 7
}

# SECRET FOR DATABASE CONNECT

data "aws_secretsmanager_secret" "phpbb_config" {
  name = "phpbb/config"
}

data "aws_iam_policy_document" "secrets_access" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [
      data.aws_secretsmanager_secret.phpbb_config.arn,
      data.aws_secretsmanager_secret_version.dt_paas_token.arn
    ]
  }
}

resource "aws_iam_policy" "secrets_policy" {
  name   = "phpbb-secrets-policy"
  policy = data.aws_iam_policy_document.secrets_access.json
}

resource "aws_iam_role_policy_attachment" "secrets_attach" {
  role       = aws_iam_role.ecs_execution.name  # execution role, not task role
  policy_arn = aws_iam_policy.secrets_policy.arn
}

# SECRET FOR CLOUDFRONT

data "aws_secretsmanager_secret_version" "cloudfront_secret" {
    secret_id = "phpbb/cloudfront-secret"
  }

# DYNATRACE SECRET

data "aws_secretsmanager_secret_version" "dt_paas_token" {
  secret_id = "phpbb/dt-paas-token"
}

# ECS TASK DEFINITION
resource "aws_iam_role_policy_attachment" "ecs_task_ssm" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_ecs_task_definition" "phpbb" {
  family                   = "phpbb"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  # EFS volume for phpBB media
  volume {
    name = "phpbb-efs"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.phpbb.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.phpbb.id
        iam             = "ENABLED"
      }
    }
  }

  # Shared bind mount for Dynatrace OneAgent
  volume {
    name = "oneagent"
  }

  container_definitions = jsonencode([
    # Init container - downloads and unzips OneAgent into shared volume
    {
      name      = "install-oneagent"
      image     = "alpine:3"
      essential = false

      memory    = 128

      entryPoint = ["/bin/sh", "-c"]
      command = ["apk add --no-cache wget unzip && ARCHIVE=$(mktemp) && wget -O $ARCHIVE \"$DT_API_URL/v1/deployment/installer/agent/unix/paas/latest?arch=$ARCH&Api-Token=$DT_PAAS_TOKEN&$DT_ONEAGENT_OPTIONS\" && unzip -o -d /opt/dynatrace/oneagent $ARCHIVE && rm -f $ARCHIVE"]
      environment = [
        { name = "DT_API_URL",          value = "https://vdz04711.live.dynatrace.com/api" },
        { name = "DT_ONEAGENT_OPTIONS", value = "flavor=default&include=all" },
        { name = "ARCH",                value = "x86" }
      ]

      secrets = [
        {
          name      = "DT_PAAS_TOKEN"
          valueFrom = data.aws_secretsmanager_secret_version.dt_paas_token.arn
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "oneagent"
          containerPath = "/opt/dynatrace/oneagent"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.phpbb.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "install-oneagent"
        }
      }
    },

    # phpBB application container
    {
      name      = "phpbb"
      image     = var.app_image
      essential = true

      portMappings = [
        { containerPort = 80, protocol = "tcp" }
      ]

      mountPoints = [
        {
          sourceVolume  = "phpbb-efs"
          containerPath = "/mnt/phpbb-s3"
          readOnly      = false
        },
        {
          sourceVolume  = "oneagent"
          containerPath = "/opt/dynatrace/oneagent"
          readOnly      = true
        }
      ]

      # Dynatrace runtime injection
      environment = [
        { name = "LD_PRELOAD", value = "/opt/dynatrace/oneagent/agent/lib64/liboneagentproc.so" }
      ]

      # Wait for OneAgent to be installed before starting
      dependsOn = [
        {
          containerName = "install-oneagent"
          condition     = "COMPLETE"
        }
      ]

      secrets = [
        {
          name      = "PHPBB_CONFIG"
          valueFrom = data.aws_secretsmanager_secret.phpbb_config.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.phpbb.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "phpbb"
        }
      }
    }
  ])
}

# ECS SERVICE

resource "aws_ecs_service" "phpbb" {
  name            = "phpbb"
  cluster         = aws_ecs_cluster.phpbb.id
  task_definition = aws_ecs_task_definition.phpbb.arn
  desired_count   = 1
  enable_execute_command = true
  launch_type     = "FARGATE"
  depends_on = [
    aws_lambda_permission.eventbridge,
    aws_cloudwatch_event_target.lambda
  ]

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = true
  }
}


# ROUTE53 

data "aws_route53_zone" "main" {
  zone_id = var.route53_zone_id
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# CLOUDFRONT DISTRIBUTION

resource "aws_cloudfront_distribution" "phpbb" {
  enabled             = true
  comment             = "phpBB forum distribution"
  default_root_object = "index.php"

  # Origin points at ECS task - Lambda keeps this updated
  origin {
    domain_name = "placeholder.example.com" # Lambda will update this
    origin_id   = "phpbb-ecs-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # HTTP internally is fine
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Custom header so your container can verify traffic came from CloudFront
    custom_header {
      name  = "X-CloudFront-Secret"
      value = data.aws_secretsmanager_secret_version.cloudfront_secret.secret_string
    }
  }
  # Cache for oneagent injection
  ordered_cache_behavior {
    path_pattern           = "/ruxitagentjs_*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "phpbb-ecs-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "phpbb-ecs-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # phpBB is dynamic - don't cache by default
    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
      headers = ["Host", "Authorization"]
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Cache static assets (CSS, JS, images)
  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "phpbb-ecs-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 86400
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.terraform_remote_state.statics.outputs.aws_acm_certificate
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  aliases = [var.subdomain] # e.g. forum.thegradyproject.com

  tags = {
    Environment = "prod"
    Terraform   = "true"
  }
}

# IAM - LAMBDA EXECUTION ROLE

resource "aws_iam_role" "lambda_origin_updater" {
  name = "phpbb-lambda-origin-updater"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "lambda_origin_updater" {
  # CloudWatch logs
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Describe ECS tasks to get the IP
  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeTasks",
      "ec2:DescribeNetworkInterfaces"
    ]
    resources = ["*"]
  }

  # Update CloudFront distribution origin
  statement {
    effect = "Allow"
    actions = [
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution"
    ]
    resources = [aws_cloudfront_distribution.phpbb.arn]
  }
}

resource "aws_iam_policy" "lambda_origin_updater" {
  name   = "phpbb-lambda-origin-updater-policy"
  policy = data.aws_iam_policy_document.lambda_origin_updater.json
}

resource "aws_iam_role_policy_attachment" "lambda_origin_updater" {
  role       = aws_iam_role.lambda_origin_updater.name
  policy_arn = aws_iam_policy.lambda_origin_updater.arn
}

# LAMBDA FUNCTION

resource "aws_lambda_function" "origin_updater" {
  filename         = "${path.module}/lambda/origin_updater.zip"
  function_name    = "phpbb-origin-updater"
  role             = aws_iam_role.lambda_origin_updater.arn
  handler          = "origin_updater.handler"
  runtime          = "python3.12"
  timeout          = 30
  source_code_hash = filebase64sha256("${path.module}/lambda/origin_updater.zip")
  environment {
    variables = {
      DISTRIBUTION_ID = aws_cloudfront_distribution.phpbb.id
      CLUSTER_NAME    = var.cluster_name
    }
  }
}


# EVENTBRIDGE RULE
# Fires when ECS task transitions to RUNNING

resource "aws_cloudwatch_event_rule" "ecs_task_running" {
  name        = "phpbb-ecs-task-running"
  description = "Fires when phpBB ECS task reaches RUNNING state"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn    = [aws_ecs_cluster.phpbb.arn]
      lastStatus    = ["RUNNING"]
      desiredStatus = ["RUNNING"]
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.ecs_task_running.name
  target_id = "phpbb-origin-updater"
  arn       = aws_lambda_function.origin_updater.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.origin_updater.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_task_running.arn
}

# ROUTE53 - point at cloudfront

resource "aws_route53_record" "phpbb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.subdomain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.phpbb.domain_name
    zone_id                = aws_cloudfront_distribution.phpbb.hosted_zone_id
    evaluate_target_health = false
  }

  allow_overwrite = true
}
