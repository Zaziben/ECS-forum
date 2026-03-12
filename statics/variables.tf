variable "vpc_id" {
  default = "vpc-0abae96f5ad67cf3d"
}
variable "private_subnet_ids" {
  type = list(string)
  default = ["subnet-0803c64790ed730d9", "subnet-09d75a39c650da09c", "subnet-07c91559f4c8535ae"]
}
variable "vpc_cidr_block" {
  description = "CIDR block for the VPC, e.g. 10.0.0.0/16"
  default = "10.180.0.0/16"
}
variable "db_name" {
  default = "dnd_forum"
}
variable "db_username" {
  default = "dnd_user"
}
variable "db_password" {
  sensitive = true
}

