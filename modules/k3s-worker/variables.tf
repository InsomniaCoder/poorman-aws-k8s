variable "az" {
  type        = string
  description = "Availability zone — must match the server node AZ."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "private_subnet_id" {
  type        = string
  description = "Private subnet ID where worker nodes launch."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for security group creation."
}

variable "server_sg_id" {
  type        = string
  description = "Security group ID of the K3S server node — worker SG accepts all traffic from it, and a rule is added to the server SG allowing all traffic back from workers."
}

variable "ssm_token_path" {
  type        = string
  description = "SSM parameter path for the K3S node token written by the server."
}

variable "ssm_server_ip_path" {
  type        = string
  description = "SSM parameter path for the K3S server private IP written by the server."
}

variable "instance_types" {
  type        = list(string)
  default     = ["t4g.small", "t4g.medium", "t4g.large"]
  description = "Graviton instance type fallback chain for the worker SPOT ASG. All must be ARM64."
}

variable "max_size" {
  type        = number
  default     = 3
  description = "Maximum number of worker nodes the ASG can scale up to."
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
  description = "AMI name glob. Switch to \"poorman-aws-k8s-k3s-*\" after running Packer."
}
