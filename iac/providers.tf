provider "aws" {
  region  = var.region
  profile = "cp"
}

provider "github" {
  token = var.github_token
}