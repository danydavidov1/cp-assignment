resource "random_password" "webhook_secret" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "webhook_secret" {
  name = "${var.project_name}-webhook-secret"
}

resource "aws_secretsmanager_secret_version" "webhook_secret" {
  secret_id     = aws_secretsmanager_secret.webhook_secret.id
  secret_string = random_password.webhook_secret.result
}

resource "aws_secretsmanager_secret" "github_token" {
  name = "${var.project_name}-github-access-token"
}

resource "aws_secretsmanager_secret_version" "github_token" {
  secret_id     = aws_secretsmanager_secret.github_token.id
  secret_string = var.github_token
}

resource "aws_iam_role" "lambda_role" {
  name = "role-lambda-${var.project_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", aws_iam_policy.lambda_acm_policy.arn]
}

resource "aws_iam_policy" "lambda_acm_policy" {
  name        = "pol-lambda-${var.project_name}"
  path        = "/"
  description = "Allow lambda to retrive secret value"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Effect = "Allow"
        Resource = [
          aws_secretsmanager_secret.github_token.id,
          aws_secretsmanager_secret.webhook_secret.id
        ]
      },
      {
        Action = [
          "secretsmanager:ListSecrets",
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "7.7.0"

  function_name = "lambda-${var.project_name}"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  publish       = true
  source_path   = "../lambda_code"
  create_role   = false
  lambda_role   = aws_iam_role.lambda_role.arn
  layers        = [aws_lambda_layer_version.pygithub.arn]
  environment_variables = {
    GITHUB_TOKEN_SECRET_ID   = aws_secretsmanager_secret.github_token.id
    WEBHOOK_SECRET_SECRET_ID = aws_secretsmanager_secret.webhook_secret.id
  }
}

resource "aws_lambda_layer_version" "pygithub" {
  filename            = "../lambda_layer/pygithub.zip"
  layer_name          = "pygithub"
  compatible_runtimes = ["python3.11"]
}

resource "aws_lambda_alias" "prod_lambda_alias" {
  name             = "prod"
  description      = "prod version"
  function_name    = module.lambda_function.lambda_function_arn
  function_version = module.lambda_function.lambda_function_version
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_alias.prod_lambda_alias.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api_gw.execution_arn}/*/*"
}

resource "aws_api_gateway_rest_api" "api_gw" {
  name = var.project_name
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api_gw.id
  parent_id   = aws_api_gateway_rest_api.api_gw.root_resource_id
  path_part   = var.url_path
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api_gw.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.api_gw.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_alias.prod_lambda_alias.invoke_arn
}

resource "aws_api_gateway_deployment" "prod" {
  depends_on = [aws_api_gateway_integration.lambda]

  rest_api_id = aws_api_gateway_rest_api.api_gw.id
  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.api_gw.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.prod.id
  rest_api_id   = aws_api_gateway_rest_api.api_gw.id
  stage_name    = "prod"
}

resource "aws_wafv2_web_acl" "waf" {
  name  = "waf-${var.project_name}"
  scope = "REGIONAL"

  default_action {
    block {}
  }

  association_config {
    request_body {
      api_gateway {
        default_size_inspection_limit = "KB_64"
      }
      app_runner_service {
        default_size_inspection_limit = "KB_64"
      }
      cognito_user_pool {
        default_size_inspection_limit = "KB_64"
      }
      verified_access_instance {
        default_size_inspection_limit = "KB_64"
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "${var.project_name}-waf-metric"
    sampled_requests_enabled   = false
  }
  rule {
    name     = "allow-req-only-from-webhook"
    priority = 0
    action {
      allow {}
    }
    statement {
      byte_match_statement {
        search_string         = lookup(element(data.github_repository_webhooks.repo.webhooks, 0), "id")
        positional_constraint = "EXACTLY"
        field_to_match {
          single_header {
            name = "x-github-hook-id"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow-req-only-from-webhook"
      sampled_requests_enabled   = true
    }
  }
}



resource "aws_wafv2_web_acl_association" "waf_to_apigw" {
  resource_arn = aws_api_gateway_stage.prod.arn
  web_acl_arn  = aws_wafv2_web_acl.waf.arn
}