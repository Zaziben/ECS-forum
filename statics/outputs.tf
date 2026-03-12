
output "postgres_endpoint" {
  value = aws_db_instance.dnd_postgres.endpoint
}

output "dnd-forum-s3-jv-id" {
  value = aws_s3_bucket.s3.id
}

output "dnd-forum-s3-jv-arn" {
  value = aws_s3_bucket.s3.arn
}

output "aws_acm_certificate" {
  value = aws_acm_certificate.forum.arn
}
