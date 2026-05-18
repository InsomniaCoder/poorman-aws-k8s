packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  default     = "eu-south-2"
  description = "AWS region to build the AMI in."
}

variable "k3s_version" {
  default     = "v1.32.4+k3s1"
  description = "K3s release to bake in. Check https://github.com/k3s-io/k3s/releases for latest."
}

variable "subnet_id" {
  description = "Public subnet ID to launch the build instance in (needs internet access)."
}

source "amazon-ebs" "k3s" {
  region        = var.region
  instance_type = "t4g.small"

  source_ami_filter {
    filters = {
      name         = "al2023-ami-*-arm64"
      architecture = "arm64"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username                = "ec2-user"
  ami_name                    = "poorman-k8s-k3s-${replace(var.k3s_version, "+", "-")}-{{timestamp}}"
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  tags = {
    Project    = "poorman-k8s"
    K3sVersion = var.k3s_version
  }
}

build {
  sources = ["source.amazon-ebs.k3s"]

  provisioner "shell" {
    inline = [
      "sudo dnf update -y --quiet",

      # K3s binary (ARM64)
      "sudo curl -sfL https://github.com/k3s-io/k3s/releases/download/${var.k3s_version}/k3s-arm64 -o /usr/local/bin/k3s",
      "sudo chmod +x /usr/local/bin/k3s",

      # K3s install script — used at boot with INSTALL_K3S_SKIP_DOWNLOAD=true
      "sudo curl -sfL https://get.k3s.io -o /usr/local/share/k3s-install.sh",
      "sudo chmod +x /usr/local/share/k3s-install.sh",
    ]
  }
}
