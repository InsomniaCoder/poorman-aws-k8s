include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules//k3s-node"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    public_subnet_id = "subnet-00000000000000000"
    vpc_id           = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  az               = local.env_vars.locals.az
  region           = local.env_vars.locals.region
  public_subnet_id = dependency.vpc.outputs.public_subnet_id
  vpc_id           = dependency.vpc.outputs.vpc_id
  # Export TF_VAR_ADMIN_CIDR=x.x.x.x/32 before applying
  admin_cidr      = get_env("TF_VAR_ADMIN_CIDR")
  ami_owner       = ["self"]
  ami_name_filter = "${local.env_vars.locals.project_name}-k3s-*"
}
