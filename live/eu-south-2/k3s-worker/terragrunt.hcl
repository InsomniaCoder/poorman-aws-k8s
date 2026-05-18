include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules//k3s-worker"

  after_hook "bootstrap_argocd" {
    commands = ["apply"]
    execute  = ["bash", "${get_repo_root()}/scripts/bootstrap-argocd.sh"]
  }
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    private_subnet_id = "subnet-00000000000000000"
    vpc_id            = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "k3s_node" {
  config_path = "../k3s-node"
  mock_outputs = {
    ssm_token_path     = "/poorman-aws-k8s/k3s-token"
    ssm_server_ip_path = "/poorman-aws-k8s/k3s-server-ip"
    security_group_id  = "sg-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  az                 = local.env_vars.locals.az
  region             = local.env_vars.locals.region
  private_subnet_id  = dependency.vpc.outputs.private_subnet_id
  vpc_id             = dependency.vpc.outputs.vpc_id
  server_sg_id       = dependency.k3s_node.outputs.security_group_id
  ssm_token_path     = dependency.k3s_node.outputs.ssm_token_path
  ssm_server_ip_path = dependency.k3s_node.outputs.ssm_server_ip_path
  ami_owner          = ["self"]
  ami_name_filter    = "${local.env_vars.locals.project_name}-k3s-*"
}
