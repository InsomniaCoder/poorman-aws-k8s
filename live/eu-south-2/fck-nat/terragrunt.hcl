include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules//fck-nat"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id                 = "vpc-00000000"
    public_subnet_id       = "subnet-00000000"
    private_subnet_cidr    = "10.0.2.0/24"
    private_route_table_id = "rtb-00000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id                 = dependency.vpc.outputs.vpc_id
  public_subnet_id       = dependency.vpc.outputs.public_subnet_id
  private_subnet_cidr    = dependency.vpc.outputs.private_subnet_cidr
  private_route_table_id = dependency.vpc.outputs.private_route_table_id
}
