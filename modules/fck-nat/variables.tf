variable "vpc_id" {
  type        = string
  description = "VPC ID to create the fck-NAT security group in."
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID where fck-NAT runs."
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR of the private subnet — only this CIDR is allowed inbound to fck-NAT."
}

variable "private_route_table_id" {
  type        = string
  description = "ID of the private route table — fck-NAT adds the default route here."
}
