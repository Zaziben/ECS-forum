provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------
# VARIABLES (add these to your variables.tf)
# -------------------------------------------------------
# var.aws_region
# var.vpc_id
# var.route53_zone_id
# var.cluster_name
# var.app_image          - your ECR image URI
# var.db_host            - RDS endpoint (from statics)
# var.db_name
# var.db_user
# var.db_password        - use SSM or Secrets Manager in prod

locals {
  subnet_ids = [
    "subnet-048916d83b3d6dcf1",
    "subnet-07e4939eae8fcd6bb",
    "subnet-04181d7c9e2cc0f09",
  ]
}

# -------------------------------------------------------
# ECS CLUSTER
# -------------------------------------------------------
resource "aws_ecs_cluster" "phpbb" {
  name = var.cluster_name

  tags = {
    Environment = "prod"
    Terraform   = "true"
  }
}

# -------------------------------------------------------
# EFS - replaces Mountpoint S3 FUSE mount
# Fargate mounts this at /mnt/phpbb-s3, entrypoint.sh
# symlinks are unchanged.
# -------------------------------------------------------
resource "aws_efs_file_system" "phpbb" {
  creation_token = "phpbb-efs"
  encrypted      = true

  tags = {
    Name      = "phpbb-efs"
    Terraform = "true"
  }
}

resource "aws_efs_mount_target" "phpbb" {
  for_each = toset(local.subnet_ids)

  file_system_id  = aws_efs_file_system.phpbb.id
  subnet_id       = each.value
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

# -------------------------------------------------------
# SECURITY GROUPS
# -------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "phpbb-alb-sg"
  description = "Allow HTTP/HTTPS inbound to ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_task" {
  name        = "phpbb-ecs-task-sg"
  description = "Allow inbound from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
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

# -------------------------------------------------------
# ALB
# -------------------------------------------------------
resource "aws_lb" "phpbb" {
  name               = "phpbb-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

resource "aws_lb_target_group" "phpbb" {
  name        = "phpbb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for Fargate

  health_check {
    path                = "/index.php"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.phpbb.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect HTTP to HTTPS
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.phpbb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn # pass in from statics output

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.phpbb.arn
  }
}

# -------------------------------------------------------
# IAM - ECS TASK EXECUTION ROLE
# (pulls image from ECR, writes logs to CloudWatch)
# -------------------------------------------------------
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

# -------------------------------------------------------
# IAM - ECS TASK ROLE
# (what the running container is allowed to do)
# Replaces IRSA phpbb_irsa - same S3 permissions, no OIDC needed
# -------------------------------------------------------
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

# -------------------------------------------------------
# IAM - EXTERNAL DNS ROLE
# Replaces IRSA externaldns - same Route53 permissions
# -------------------------------------------------------
resource "aws_iam_role" "externaldns" {
  name = "external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "externaldns" {
  statement {
    effect  = "Allow"
    actions = ["route53:ChangeResourceRecordSets", "route53:GetHostedZone"]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
  }

  statement {
    effect  = "Allow"
    actions = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "externaldns" {
  name   = "ExternalDNSPolicy"
  policy = data.aws_iam_policy_document.externaldns.json
}

resource "aws_iam_role_policy_attachment" "externaldns" {
  role       = aws_iam_role.externaldns.name
  policy_arn = aws_iam_policy.externaldns.arn
}

# -------------------------------------------------------
# CLOUDWATCH LOG GROUP
# -------------------------------------------------------
resource "aws_cloudwatch_log_group" "phpbb" {
  name              = "/ecs/phpbb"
  retention_in_days = 7
}

# -------------------------------------------------------
# SECRET DATABASE HOOKUP
# -------------------------------------------------------

data "aws_secretsmanager_secret" "phpbb_config" {
  name = "phpbb/config"
}

data "aws_iam_policy_document" "secrets_access" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.phpbb_config.arn]
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



# -------------------------------------------------------
# ECS TASK DEFINITION
# t3.medium was 2 vCPU / 4GB - 512 CPU / 1024 MB is
# plenty for 7 concurrent users on phpBB. Adjust up if
# needed - Fargate billing is per vCPU/memory second.
# -------------------------------------------------------
resource "aws_ecs_task_definition" "phpbb" {
  family                   = "phpbb"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

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

  container_definitions = jsonencode([
    {
      name      = "phpbb"
      image     = var.app_image
      essential = true

      portMappings = [
        { containerPort = 80, protocol = "tcp" }
      ]

      # EFS mounted at /mnt/phpbb-s3 - entrypoint.sh symlinks are unchanged
      mountPoints = [
        {
          sourceVolume  = "phpbb-efs"
          containerPath = "/mnt/phpbb-s3"
          readOnly      = false
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

# -------------------------------------------------------
# ECS SERVICE
# -------------------------------------------------------
resource "aws_ecs_service" "phpbb" {
  name            = "phpbb"
  cluster         = aws_ecs_cluster.phpbb.id
  task_definition = aws_ecs_task_definition.phpbb.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.phpbb.arn
    container_name   = "phpbb"
    container_port   = 80
  }

  # Route53 record is updated by external-dns reading ALB DNS name
  # No Helm controller needed - wire external-dns as a separate ECS
  # service or Lambda if you need automatic DNS updates, or manage
  # the Route53 record directly in Terraform (recommended at this scale).

  depends_on = [aws_lb_listener.https]
}

# -------------------------------------------------------
# ROUTE53 - manage directly in Terraform instead of
# external-dns, since you only have one ALB and one record.
# This is simpler and removes the external-dns dependency.
# -------------------------------------------------------
data "aws_route53_zone" "main" {
  zone_id = var.route53_zone_id
}

resource "aws_route53_record" "phpbb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = forum.thegradyproject.com
  type    = "A"

  alias {
    name                   = aws_lb.phpbb.dns_name
    zone_id                = aws_lb.phpbb.zone_id
    evaluate_target_health = true
  }
}
