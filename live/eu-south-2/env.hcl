locals {
  region       = "eu-south-2"
  az           = "eu-south-2a"
  account_id   = get_aws_account_id()
  project_name = "poorman-k8s"
  # Set these in your .env file (never commit personal values)
  domain_name  = get_env("DOMAIN_NAME", "example.com")
  repo_url     = get_env("REPO_URL", "https://github.com/your-org/your-fork")
}
