output "eni_id" {
  value       = module.fck_nat.eni_id
  description = "ENI ID of the fck-NAT instance — used as the private route table default gateway."
}

output "eip_public_ip" {
  value       = aws_eip.fck_nat.public_ip
  description = "Stable public IP of the fck-NAT instance."
}
