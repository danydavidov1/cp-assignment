resource "github_repository" "repo" {
  name        = "repo-${var.project_name}"
  description = "Repo for ${var.project_name} project"
  visibility  = "private"
}

resource "github_repository_webhook" "pr_webhook" {
  repository = github_repository.repo.name

  configuration {
    url          = "${aws_api_gateway_stage.prod.invoke_url}${aws_api_gateway_resource.proxy.path}"
    content_type = "json"
    secret       = random_password.webhook_secret.result
    insecure_ssl = false
  }

  active = true

  events = ["pull_request"]
}