variable "region" {
  type = string
}

variable "project_name" {
  type = string
}

variable "url_path" {
  type = string
}

variable "github_token" {
  type        = string
  description = "GitHub token for github provider"
  sensitive   = true
}