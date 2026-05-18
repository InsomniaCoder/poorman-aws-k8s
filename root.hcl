locals {
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region       = local.env_vars.locals.region
  account_id   = local.env_vars.locals.account_id
  project_name = local.env_vars.locals.project_name
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = "${local.project_name}-tfstate-${local.account_id}"
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.region
    encrypt      = true
    use_lockfile = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"
    }
  EOF
}
