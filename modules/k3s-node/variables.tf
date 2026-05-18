variable "az" {
  type        = string
  description = "Availability zone — must match the EBS volume AZ."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID where the K3S node launches."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for security group creation."
}

variable "admin_cidr" {
  type        = string
  description = "Your IP in CIDR notation (e.g. 1.2.3.4/32) — allowed SSH and kubectl access."
}

variable "instance_types" {
  type        = list(string)
  default     = ["m7g.large", "m6g.large", "t4g.large", "t4g.medium"]
  description = "Graviton instance type fallback chain for the SPOT ASG. All must be ARM64."
}

variable "data_volume_size_gb" {
  type        = number
  default     = 20
  description = "Size in GB of the EBS data volume for /var/lib/rancher/k3s/."
}

variable "root_volume_size_gb" {
  type        = number
  default     = 30
  description = "Size in GB of the root EBS volume. Must be >= the source AMI snapshot size (30 GB for AL2023)."
}

variable "ami_owner" {
  type        = list(string)
  default     = ["amazon"]
  description = "AMI owner filter. Use [\"amazon\"] for stock AL2023, [\"self\"] for custom Packer AMI."
}

variable "ami_name_filter" {
  type        = string
  default     = "al2023-ami-*-arm64"
  description = "AMI name glob. Switch to \"poorman-k8s-k3s-*\" after running Packer."
}
