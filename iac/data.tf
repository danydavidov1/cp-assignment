data "aws_caller_identity" "current" {}

data "github_repository_webhooks" "repo" {
  depends_on = [github_repository_webhook.pr_webhook]
  repository = github_repository.repo.name
}