## PROVIDES ##
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30.0"
    }
  }
}
provider "aws" {
  region = local.region
}

## TERRAFORM BACKEND 
terraform {
  backend "s3" { # --> gitlab-ci.yml 
    # bucket = "backends-terraform-states"
    # key    = "brandlovrs-test/terraform.tfstate"
    # region = "us-east-2"
  }
}

variable "environment_region" {
  type = map(string)
  default = {
    develop = "us-east-2"
    main    = "us-east-1"
  }
}

## VARIABLES ###
variable "project_name" {}
variable "project_group" {}
variable "lambda_timeout" { default = "60" }        # --> values.auto.tfvars
variable "lambda_memory_size" { default = "128" }   # --> values.auto.tfvars
variable "lambda_policy_s3" { default = false }     # --> values.auto.tfvars | attach the policy: catalyst-s3-${terraform.workspace}
variable "lambda_policy_invoke" { default = false } # --> values.auto.tfvars | attach the policy: LambdaInvokeFunction-${terraform.workspace}
variable "sqs_queue" { default = [] }               # --> values.auto.tfvars
variable "bucket_name" { default = [] }             # --> values.auto.tfvars
variable "s3_triggers" { default = {} }             # --> values.auto.tfvars
variable "cod_version" { default = "latest" }
variable "subsc_msk_topic" { default = [] }         # --> values.auto.tfvars
variable "publish_msk" { default = false }          # --> values.auto.tfvars | attach the policy: AWSLambdaMSKExecutionPolicy

variable "lambda_variables" {
  type = map(string)
  default = {
    "key1" = "value1"
  }
}
variable "subnet_private_id" {
  type = map(list(string))
  default = {
    develop = ["subnet-038cac1dd5e665ac2", "subnet-0cc6a6bf495f09961"],
    main    = ["subnet-06b22f6ba0059bd1b", "subnet-00adc4773686d8c1b"]
  }
}
variable "security_group_id" {
  type        = map(list(string))
  description = "Mapa que define em qual ambiente o código está sendo executado"
  default = {
    develop = ["sg-0164920bc25a6ea56"],
    main    = ["sg-08c626d94c1bcd33a"]
  }
}
variable "environment" {
  type = map(string)
  default = {
    develop = "dev",
    homolog = "hmlg",
    main    = "prod"
  }
}

### DATA ###
data "aws_caller_identity" "current" {}
data "aws_ecr_repository" "repo" {
  name = "${var.project_group}/${var.project_name}"
}

### LOCALS ###
locals {
  region             = lookup(var.environment_region, terraform.workspace)
  environment        = lookup(var.environment, terraform.workspace)
  environment_bucket = lookup(var.environment, terraform.workspace)
  aws_account        = data.aws_caller_identity.current.id
  subnet_private_id  = lookup(var.subnet_private_id, terraform.workspace)
  security_group_id  = lookup(var.security_group_id, terraform.workspace)
  latest_version     = "latest"
  registry           = "${data.aws_caller_identity.current.id}.dkr.ecr.${local.region}.amazonaws.com"
  has_triggers       = length(keys(var.s3_triggers)) > 0 ? true : false
  tags = {
    Project     = title(var.project_group)
    Service     = "microservices"
    Tier        = "back-end"
    Environment = local.environment
    Managed-by  = "terraform"
  }
}

## RESOURCES ###
resource "aws_ecr_lifecycle_policy" "repo" {
  repository = "${var.project_group}/${var.project_name}"
  policy     = <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 5 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 5
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
EOF
  depends_on = [data.aws_ecr_repository.repo]
}

## LAMBDA
resource "aws_iam_policy" "policy_log" {
  name        = "function-${var.project_name}-${local.environment}"
  path        = "/"
  description = "IAM policy for logging from a lambda"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "secretsmanager:GetSecretValue",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:SendMessage",
          "ses:SendRawEmail",
          "ses:SendEmail",
          "sns:Publish"
        ],
        "Effect" : "Allow",
        "Resource" : [
          "arn:aws:sqs:${local.region}:${local.aws_account}:*",
          "arn:aws:ses:${local.region}:${local.aws_account}:identity/catalystcore.io",
          "arn:aws:secretsmanager:${local.region}:${local.aws_account}:secret:*",
          "arn:aws:sns:${local.region}:${local.aws_account}:*"
        ]
      },
    ]
  })
}

resource "aws_iam_role" "iam_role" {
  name = "role-${var.project_name}-${local.environment}"
  tags = local.tags
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

# append to a function a bucket access policy
resource "aws_iam_policy" "s3_policy" {
  count       = var.bucket_name != [] ? 1 : 0
  name        = "${var.project_name}-S3-${local.environment}"
  path        = "/"
  description = "policy S3 bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccessBucket"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = [
          for item in var.bucket_name : "arn:aws:s3:::${item}-${local.environment}/*"
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "policy_attach" {
  role       = aws_iam_role.iam_role.name
  policy_arn = aws_iam_policy.policy_log.arn
  depends_on = [aws_iam_role.iam_role, aws_iam_policy.policy_log]
}
resource "aws_iam_role_policy_attachment" "policy_attach-VPCAccess" {
  role       = aws_iam_role.iam_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
resource "aws_iam_role_policy_attachment" "policy_rds_proxy" {
  role       = aws_iam_role.iam_role.name
  policy_arn = "arn:aws:iam::029819018629:policy/catalyst-rds-proxy-${terraform.workspace}"
}
resource "aws_iam_role_policy_attachment" "policy_attach_s3" {
  count      = var.lambda_policy_s3 == true ? 1 : 0
  role       = aws_iam_role.iam_role.name
  policy_arn = "arn:aws:iam::029819018629:policy/catalyst-s3-${terraform.workspace}"
}
resource "aws_iam_role_policy_attachment" "policy_Invoke" {
  count      = var.lambda_policy_invoke == true ? 1 : 0
  role       = aws_iam_role.iam_role.name
  policy_arn = "arn:aws:iam::029819018629:policy/LambdaInvokeFunction-${terraform.workspace}"
}
resource "aws_iam_role_policy_attachment" "policy_kafka" {
  count      = var.publish_msk == true ? 1 : 0
  role       = aws_iam_role.iam_role.name
  policy_arn = "arn:aws:iam::029819018629:policy/AWSLambdaMSKExecutionPolicy"
}
resource "aws_iam_role_policy_attachment" "policy_s3" {
  count      = var.bucket_name != [] ? 1 : 0
  role       = aws_iam_role.iam_role.name
  policy_arn = aws_iam_policy.s3_policy[count.index].arn
  depends_on = [aws_iam_role.iam_role, aws_iam_policy.s3_policy]
}

# Lambda trigger: This allows Lambda functions to get events from SQS queue
resource "aws_lambda_event_source_mapping" "sqs_triggers" {
  for_each         = toset(var.sqs_queue)
  event_source_arn = "arn:aws:sqs:${local.region}:${local.aws_account}:${each.value}-${local.environment}"
  function_name    = aws_lambda_function.lambda_function.arn
  enabled          = true
}

resource "aws_lambda_event_source_mapping" "kafka" {
  count             = var.subsc_msk_topic != [] ? 1 : 0
  event_source_arn  = "arn:aws:kafka:${local.region}:${local.aws_account}:cluster/dev-msk-brandlovrs/571bdecb-626d-4c00-af05-a143d28aa9f2-s3"
  function_name     = aws_lambda_function.lambda_function.arn
  topics            = var.subsc_msk_topic
  starting_position = "LATEST"
  batch_size        = 1
}

# policy with log permission in cloudwatchs
resource "aws_cloudwatch_log_group" "log_group" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = "14"
}

resource "aws_lambda_function" "lambda_function" {
  function_name = var.project_name
  image_uri     = "${local.registry}/${var.project_group}/${var.project_name}:${var.cod_version}"
  role          = aws_iam_role.iam_role.arn
  publish       = true
  package_type  = "Image"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  vpc_config {
    subnet_ids         = local.subnet_private_id
    security_group_ids = local.security_group_id
  }
  environment {
    variables = var.lambda_variables
  }
  depends_on = [
    aws_iam_role_policy_attachment.policy_attach
  ]
  tags = local.tags
}
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIInvoke-${local.environment}"
  action        = "lambda:InvokeFunction"
  qualifier     = aws_lambda_alias.lambda_alias.name
  principal     = "apigateway.amazonaws.com"
  function_name = aws_lambda_function.lambda_function.function_name
}

resource "aws_lambda_permission" "s3" {
  for_each      = local.has_triggers ? var.s3_triggers : {}
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${each.key}-${local.environment}"
  #statement_id  = ""
  #qualifier     = aws_lambda_alias.lambda_alias.name
}
resource "aws_s3_bucket_notification" "notification" {
  for_each      = local.has_triggers ? var.s3_triggers : {}
  bucket   = "${each.key}-${local.environment}"
  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda_function.arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = each.value["triggers_folder"]
    filter_suffix       = ""
  }
  depends_on = [aws_lambda_permission.s3]
}

# resource "aws_ssm_parameter" "lambda_ssm_arn" {  
#   name        = "/${var.project_group}/lambda/${local.environment}/${var.project_name}/arn"
#   description = "ARN Alias"
#   type        = "String"
#   value       = aws_lambda_alias.lambda_alias.arn
#   tags = local.tags
# }

# resource "aws_ssm_parameter" "lambda_ssm_version" {  
#   name        = "/${var.project_group}/lambda/${local.environment}/${var.project_name}/version"
#   description = "Lambda Version"
#   type        = "String"
#   value       = local.environment == "dev" ? "\\$LATEST" : aws_lambda_function.lambda_function.version
#   tags = local.tags
# 	depends_on = [ aws_lambda_function.lambda_function ]
# }

resource "aws_lambda_alias" "lambda_alias" {
  name             = local.environment
  description      = "${title(local.environment)} Environment"
  function_name    = aws_lambda_function.lambda_function.arn
  function_version = aws_lambda_function.lambda_function.version
  depends_on       = [aws_lambda_function.lambda_function]
}

### OUTPUT ###
output "lambda_function_name" {
  value = aws_lambda_function.lambda_function.function_name
}
output "lambda_version" {
  value = aws_lambda_function.lambda_function.version
}
output "lambda_alias" {
  value = aws_lambda_alias.lambda_alias.arn
}
# output "lambda_ssm_function_path" {
#   value = aws_ssm_parameter.lambda_ssm_arn.name
# }
