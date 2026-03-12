resource "aws_ecr_repository" "dnd_forum" {
  name = "dnd-forum"
}

resource "aws_db_subnet_group" "dnd_postgres" {
  name       = "dnd-postgres-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "dnd-postgres-subnet-group"
  }
}

resource "aws_security_group" "dnd_postgres_sg" {
  name        = "dnd-postgres-sg"
  description = "Allow access to PostgreSQL from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Allow PostgreSQL from within VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "dnd-postgres-sg"
  }
}

resource "aws_db_instance" "dnd_postgres" {
  identifier              = "dnd-forum-postgres"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  max_allocated_storage   = 50
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.dnd_postgres.name
  vpc_security_group_ids  = [aws_security_group.dnd_postgres_sg.id]
  skip_final_snapshot     = true
  publicly_accessible     = false
  backup_retention_period = 7
  multi_az                = false
  storage_encrypted       = true
  apply_immediately       = true


  tags = {
    Name = "dnd-forum-postgres"
  }
}

resource "aws_s3_bucket" "s3" {
  bucket = "dnd-forum-s3-jv"
  
  tags = {
    Name = "phpBB ersatz file system"
    Environment = "dev"
  }
}

resource "aws_s3_bucket_ownership_controls" "ownershipdnd" {
  bucket = aws_s3_bucket.s3.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "pbdnd" {
  bucket = aws_s3_bucket.s3.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_acl" "acldnd" {
    depends_on = [aws_s3_bucket_ownership_controls.ownershipdnd]
      bucket     = aws_s3_bucket.s3.id
        acl        = "private"
}

# Step 1: Request the ACM certificate (DNS validation)
resource "aws_acm_certificate" "forum" {
  domain_name               = "forum.thegradyproject.com"
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "forum-thegradyproject-com"
  }
}

# Step 2: Get the Route 53 hosted zone
data "aws_route53_zone" "thegradyproject" {
  name         = "thegradyproject.com."
  private_zone = false
}

resource "aws_route53_record" "forum_validation" {
  for_each = {
    for dvo in aws_acm_certificate.forum.domain_validation_options : dvo.domain_name => dvo
  }

  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  zone_id = data.aws_route53_zone.thegradyproject.zone_id
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "forum" {
  certificate_arn = aws_acm_certificate.forum.arn

  validation_record_fqdns = [
    for r in aws_route53_record.forum_validation : r.fqdn
  ]
}


