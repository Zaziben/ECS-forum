
output "alb_dns_name" {
  value = aws_lb.phpbb.dns_name
}

output "efs_file_system_id" {
  value = aws_efs_file_system.phpbb.id
}
