variable "account_id" {
  type        = string
  description = "AWS account ID — used as bucket name suffix for global uniqueness."
}

variable "region" {
  type        = string
  description = "AWS region to create the S3 bucket in."
}
