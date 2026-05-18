output "k3s_eip" {
  value       = aws_eip.k3s.public_ip
  description = "Public IP of the K3S node — use this as your DNS A record."
}

output "k3s_eip_allocation_id" {
  value       = aws_eip.k3s.allocation_id
  description = "EIP allocation ID — used in user-data to reassociate on boot."
}

output "data_volume_id" {
  value       = aws_ebs_volume.k3s_data.id
  description = "EBS data volume ID — stores /var/lib/rancher/k3s/."
}

output "asg_name" {
  value       = aws_autoscaling_group.k3s.name
  description = "Auto Scaling Group name."
}

output "security_group_id" {
  value       = aws_security_group.k3s.id
  description = "Security group ID for the K3S server node."
}

output "ssm_token_path" {
  value       = "/poorman-k8s/k3s-token"
  description = "SSM parameter path for the K3S node token."
}

output "ssm_server_ip_path" {
  value       = "/poorman-k8s/k3s-server-ip"
  description = "SSM parameter path for the K3S server private IP."
}
