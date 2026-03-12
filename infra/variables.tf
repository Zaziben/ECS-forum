variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID of the existing VPC"
  type        = string
  default = "vpc-0abae96f5ad67cf3d"
}

variable "route53_zone_id" {
  description = "ID of the existing zone ID"
  type = string
  default = "Z0281442JLAR1WYASRZ3"
}

variable "cluster_name" {
  description = "name of ECS cluster"
  type = string
  default = "phpbb_ecs_cluster"
}

variable "app_image" {
  description = "url of image location"
  type = string
  default = "731945947682.dkr.ecr.us-east-1.amazonaws.com/dnd-forum:latest"
}

variable "subdomain" {
  description = "url of the full subdomain"
  type = string
  default = "forum.thegradyproject.com"
}
