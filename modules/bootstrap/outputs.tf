output "bucket_name" {
  value       = aws_s3_bucket.state.bucket
  description = "Name of the Terraform state S3 bucket."
}
