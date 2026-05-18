# ── Locals ────────────────────────────────────────────────────
locals {
  common_tags = { Project = "poorman-aws-k8s" }
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
resource "aws_iam_role" "k3s_worker" {
  name = "poorman-aws-k8s-k3s-worker"

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

resource "aws_iam_role_policy" "k3s_worker" {
  name = "poorman-aws-k8s-k3s-worker"
  role = aws_iam_role.k3s_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/poorman-aws-k8s/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "k3s_worker_ssm" {
  role       = aws_iam_role.k3s_worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s_worker" {
  name = "poorman-aws-k8s-k3s-worker"
  role = aws_iam_role.k3s_worker.name
}

# ── Security group ────────────────────────────────────────────
resource "aws_security_group" "k3s_worker" {
  name_prefix = "poorman-aws-k8s-k3s-worker-"
  description = "K3S worker: all traffic from server SG, all traffic between workers, all outbound"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "poorman-aws-k8s-k3s-worker-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "worker_ingress_from_server" {
  description              = "All traffic from server node"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = var.server_sg_id
  security_group_id        = aws_security_group.k3s_worker.id
}

resource "aws_security_group_rule" "worker_ingress_self" {
  description       = "All traffic between worker nodes"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.k3s_worker.id
}

resource "aws_security_group_rule" "worker_egress_all" {
  description       = "All outbound"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k3s_worker.id
}

# Allow all traffic from worker nodes into the server — bidirectional trust between
# server and worker SGs. CIDR-based port enumeration would add operational friction
# for zero meaningful security gain: if either node is compromised the join token
# gives full cluster access regardless of which ports are open.
resource "aws_security_group_rule" "server_from_worker" {
  description              = "All traffic from worker nodes"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.k3s_worker.id
  security_group_id        = var.server_sg_id
}

# ── Launch template ───────────────────────────────────────────
resource "aws_launch_template" "k3s_worker" {
  name_prefix   = "poorman-aws-k8s-k3s-worker-"
  image_id      = data.aws_ami.k3s.id
  instance_type = var.instance_types[0]

  iam_instance_profile {
    arn = aws_iam_instance_profile.k3s_worker.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.k3s_worker.id]
    subnet_id                   = var.private_subnet_id
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
    ssm_token_path     = var.ssm_token_path
    ssm_server_ip_path = var.ssm_server_ip_path
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "poorman-aws-k8s-k3s-worker" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────
resource "aws_autoscaling_group" "k3s_worker" {
  name                = "poorman-aws-k8s-k3s-worker"
  min_size            = 1
  max_size            = var.max_size
  desired_capacity    = 1
  vpc_zone_identifier = [var.private_subnet_id]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.k3s_worker.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "poorman-aws-k8s-k3s-worker" })
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
