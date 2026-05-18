output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_cidr" {
  value = aws_subnet.private.cidr_block
}

output "public_subnet_cidr" {
  value = aws_subnet.public.cidr_block
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}
