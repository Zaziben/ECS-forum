output "efs_file_system_id" {
  value = aws_efs_file_system.phpbb.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.phpbb.id
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.phpbb.domain_name
}
