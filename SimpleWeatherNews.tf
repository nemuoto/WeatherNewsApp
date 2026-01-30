terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1" # 必要に応じて変更してください
}

# ------------------------------------------------------------
# Variables (Parameters)
# ------------------------------------------------------------
variable "s3_bucket_name" {
  description = "The name of the EXISTING S3 bucket where lambda_function.zip is stored."
  type        = string
  default     = "aws-serverless-simple-weather-news-admin-v1"
}

variable "lambda_zip_key" {
  description = "The key name of the Lambda zip file."
  type        = string
  default     = "lambda_function.zip"
}

# 現在のリージョンとアカウントIDを取得するためのデータソース
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ------------------------------------------------------------
# 1. DynamoDB Table
# ------------------------------------------------------------
resource "aws_dynamodb_table" "simple_weather_news" {
  name           = "SimpleWeatherNewsTable"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "Cityid"

  attribute {
    name = "Cityid"
    type = "N"
  }
}

# ------------------------------------------------------------
# 2. Cognito User Pool & Client
# ------------------------------------------------------------
resource "aws_cognito_user_pool" "main" {
  name = "Simple Weather News Admin"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name = "simple-weather-news-client"

  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# ------------------------------------------------------------
# 3. IAM Role for Lambda
# ------------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "simple-weather-news-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for DynamoDB Access
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "DynamoDBAccess"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.simple_weather_news.arn
      }
    ]
  })
}

# IAM Policy for CloudWatch Logs
resource "aws_iam_role_policy" "logs_access" {
  name = "CloudWatchLogsAccess"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ------------------------------------------------------------
# 4. Lambda Function
# ------------------------------------------------------------
resource "aws_lambda_function" "main" {
  function_name = "simple-weather-news-function"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 10
  memory_size   = 128

  # S3からコードを取得
  s3_bucket = var.s3_bucket_name
  s3_key    = "lambda-code.zip"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.simple_weather_news.name
    }
  }
}

# ------------------------------------------------------------
# 5. API Gateway (HTTP API)
# ------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = "simple-weather-news-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "PUT", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

# Cognito Authorizer
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "CognitoAuthorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

# Lambda Integration
resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.main.invoke_arn
  payload_format_version = "2.0"
}

# Routes
resource "aws_apigatewayv2_route" "get_all" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET/all"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "get_city" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /{cityId}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "put_city" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "PUT /{cityId}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Stage ($default)
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

# Permission to invoke Lambda from API Gateway
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ------------------------------------------------------------
# Outputs
# ------------------------------------------------------------
output "ApiEndpoint" {
  description = "API Gateway Endpoint URL"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "UserPoolId" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "UserPoolClientId" {
  description = "Cognito User Pool Client ID"
  value       = aws_cognito_user_pool_client.main.id
}