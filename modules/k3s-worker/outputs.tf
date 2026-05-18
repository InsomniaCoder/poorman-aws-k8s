output "asg_name" {
  value       = aws_autoscaling_group.k3s_worker.name
  description = "Auto Scaling Group name for the K3S worker."
}

output "security_group_id" {
  value       = aws_security_group.k3s_worker.id
  description = "Security group ID for K3S worker nodes."
}
