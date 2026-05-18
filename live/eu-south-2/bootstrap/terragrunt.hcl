# Bootstrap unit: uses local backend intentionally.
# Run `terragrunt apply` here once, then all other units use the S3 backend.

terraform {
  source = "../../../modules//bootstrap"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  account_id = local.env_vars.locals.account_id
  region     = local.env_vars.locals.region
}
