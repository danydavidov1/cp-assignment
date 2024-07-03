terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.4.1"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}


