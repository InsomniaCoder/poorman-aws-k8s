include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules//vpc"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  az = local.env_vars.locals.az
}
