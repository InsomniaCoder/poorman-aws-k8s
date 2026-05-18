# ── Locals ────────────────────────────────────────────────────
locals {
  common_tags = { Project = "poorman-k8s" }
}

# ── Data sources ──────────────────────────────────────────────
data "aws_ami" "k3s" {
  most_recent = true
  owners      = var.ami_owner

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# ── IAM ───────────────────────────────────────────────────────
resource "aws_iam_role" "k3s" {
  name = "poorman-k8s-k3s-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "k3s" {
  name = "poorman-k8s-k3s-node"
  role = aws_iam_role.k3s.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssociateAddress",
          "ec2:AttachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/poorman-k8s/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s" {
  name = "poorman-k8s-k3s-node"
  role = aws_iam_role.k3s.name
}

# ── EIP ───────────────────────────────────────────────────────
resource "aws_eip" "k3s" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "poorman-k8s-k3s-eip" })
}

# ── EBS data volume (persists K3S state across SPOT interruptions) ──
resource "aws_ebs_volume" "k3s_data" {
  availability_zone = var.az
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.common_tags, { Name = "poorman-k8s-k3s-data" })

  lifecycle {
    prevent_destroy = true
  }
}

# ── Security group ────────────────────────────────────────────
# Rules are managed as standalone aws_security_group_rule resources (not inline
# ingress/egress blocks) so that k3s-worker can add its own rule to this SG
# without causing perpetual drift on plan.
resource "aws_security_group" "k3s" {
  name_prefix = "poorman-k8s-k3s-node-"
  description = "K3S node: HTTP/S ingress, admin SSH/kubectl, all traffic from worker SG"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "poorman-k8s-k3s-node-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "k3s_ingress_http" {
  description       = "HTTP"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k3s.id
}

resource "aws_security_group_rule" "k3s_ingress_https" {
  description       = "HTTPS"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k3s.id
}

resource "aws_security_group_rule" "k3s_ingress_api" {
  description       = "kubectl / K3S API (admin)"
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [var.admin_cidr]
  security_group_id = aws_security_group.k3s.id
}

resource "aws_security_group_rule" "k3s_egress_all" {
  description       = "All outbound"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k3s.id
}

# ── Launch template ───────────────────────────────────────────
resource "aws_launch_template" "k3s" {
  name_prefix   = "poorman-k8s-k3s-"
  image_id      = data.aws_ami.k3s.id
  instance_type = var.instance_types[0]

  iam_instance_profile {
    arn = aws_iam_instance_profile.k3s.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.k3s.id]
    subnet_id                   = var.public_subnet_id
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    region             = var.region
    eip_allocation_id  = aws_eip.k3s.allocation_id
    eip_public_ip      = aws_eip.k3s.public_ip
    data_volume_id     = aws_ebs_volume.k3s_data.id
    ssm_token_path     = "/poorman-k8s/k3s-token"
    ssm_server_ip_path = "/poorman-k8s/k3s-server-ip"
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "poorman-k8s-k3s" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────
resource "aws_autoscaling_group" "k3s" {
  name                = "poorman-k8s-k3s"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_id]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.k3s.id
        version            = "$Latest"
      }

      # Graviton-only fallback chain — all ARM64, same AMI
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "poorman-k8s-k3s" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
