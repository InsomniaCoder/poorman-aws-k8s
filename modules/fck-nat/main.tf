locals {
  common_tags = { Project = "poorman-aws-k8s" }
}

resource "aws_eip" "fck_nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "poorman-aws-k8s-fck-nat-eip" })
}

resource "aws_security_group" "fck_nat" {
  name        = "poorman-aws-k8s-fck-nat"
  description = "Allow private subnet traffic through fck-NAT"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.private_subnet_cidr]
    description = "Private subnet egress traffic"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "poorman-aws-k8s-fck-nat-sg" })
}

module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.3.0"

  name                          = "poorman-aws-k8s-fcknat"
  vpc_id                        = var.vpc_id
  subnet_id                     = var.public_subnet_id
  ha_mode                       = true
  use_spot_instances            = true
  instance_type                 = "t4g.nano"
  eip_allocation_ids            = [aws_eip.fck_nat.allocation_id]
  additional_security_group_ids = [aws_security_group.fck_nat.id]

  update_route_tables = false
}

resource "aws_route" "private_default" {
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.fck_nat.eni_id
}
