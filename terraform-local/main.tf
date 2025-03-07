#########################################
#       PRIVATE NETWORKING              #
#########################################

resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "vpc"
  }
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "private-subnet-1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet-2"
  }
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id,
  ]

  tags = {
    Name = "RDS Subnet Group"
  }
}

#########################################
#         PUBLIC NETWORKING             #
#########################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "vpc-igw"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_eip" "nat_eip" {

  tags = {
    Name = "nat-eip"
  }
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  tags = {
    Name = "nat-gateway"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "private-rt"
  }
}

# Associate the Private Route Table with both private subnets
resource "aws_route_table_association" "private_rt_assoc_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_rt_assoc_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_rt.id
}





#########################################
#            SECURITY GROUPS            #
#########################################

resource "aws_security_group" "rds_proxy_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-proxy-sg"
  }
}

resource "aws_security_group" "lambda_sg" {
  vpc_id = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lambda-sg"
  }
}


#########################################
#               SECRETS                 #
#########################################

# Secret #1
resource "aws_secretsmanager_secret" "database_secret" {
  name = "database_secret"

  tags = {
    Name = "database_secret"
  }
}

resource "aws_secretsmanager_secret_version" "super_secret_value" {
  secret_id     = aws_secretsmanager_secret.database_secret.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

#########################################
#         RDS & RDS PROXY SETUP         #
#########################################

resource "aws_iam_role" "rds_monitoring_role" {
  name = "rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring_attachment" {
  role       = aws_iam_role.rds_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_rds_cluster" "historydb_cluster" {
  cluster_identifier                  = "historydb-cluster"
  engine                             = "aurora-postgresql"
  engine_version                     = "15.3"
  database_name                      = var.db_name
  master_username                    = var.db_username
  master_password                    = var.db_password
  skip_final_snapshot                = true
  vpc_security_group_ids            = [aws_security_group.rds_proxy_sg.id]
  db_subnet_group_name              = aws_db_subnet_group.rds_subnet_group.name
  apply_immediately                  = true
  iam_database_authentication_enabled = true

  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"

  tags = {
    Name = "historydb-cluster"
  }
}

resource "aws_rds_cluster_instance" "historydb_instance" {
  identifier         = "historydb-instance"
  cluster_identifier = aws_rds_cluster.historydb_cluster.id
  instance_class     = "db.t3.medium"
  engine             = "aurora-postgresql"

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring_role.arn

  tags = {
    Name = "historydb-instance"
  }
}

# RDS Proxy with username and password authentication enabled

resource "aws_db_proxy" "historydb_proxy" {
  name                   = "historydb-proxy"
  engine_family          = "POSTGRESQL"
  role_arn              = aws_iam_role.rds_proxy_role.arn
  vpc_security_group_ids = [aws_security_group.rds_proxy_sg.id]
  vpc_subnet_ids         = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
  require_tls           = true
  idle_client_timeout   = 1800

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.database_secret.arn
  }

  tags = {
    Name = "historydb-proxy"
  }
}

resource "aws_db_proxy_default_target_group" "historydb_proxy_target_group" {
  db_proxy_name = aws_db_proxy.historydb_proxy.name
}

resource "aws_db_proxy_target" "historydb_proxy_target" {
  db_proxy_name         = aws_db_proxy.historydb_proxy.name
  target_group_name     = aws_db_proxy_default_target_group.historydb_proxy_target_group.name
  db_cluster_identifier = aws_rds_cluster.historydb_cluster.id

  lifecycle {
    create_before_destroy = true
  }
}


#########################################
#         IAM ROLES & POLICIES          #
#########################################


resource "aws_iam_role" "rds_proxy_role" {
  name = "rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "rds_proxy_policy" {
  name = "rds-proxy-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = aws_secretsmanager_secret.database_secret.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_proxy_role_attach" {
  role       = aws_iam_role.rds_proxy_role.name
  policy_arn = aws_iam_policy.rds_proxy_policy.arn
}


resource "aws_iam_role" "lambda_role" {
  name = "lambda-execution-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "lambda-consolidated-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "rds-db:connect",
          "rds:GenerateDbAuthToken",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      },
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

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_iam_policy" "lambda_rds_proxy_policy" {
  name        = "lambda-rds-proxy-policy"
  description = "Allows Lambda to connect to RDS Proxy"
  policy      = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sts:AssumeRole",
        Resource = "arn:aws:iam::*:role/lambda-execution-role"
      },
      {
        Effect   = "Allow",
        Action   = "rds:GenerateDbAuthToken",
        Resource = aws_rds_cluster.historydb_cluster.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_rds_proxy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_rds_proxy_policy.arn
}

# Instead of a custom logging policy, attach AWSLambdaBasicExecutionRole.
resource "aws_iam_role_policy_attachment" "apigw_logging_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/weather-lambda"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "api_log_group" {
  name              = "/aws/api-gw/weather-api"
  retention_in_days = 7
}


#########################################
#           LAMBDA FUNCTIONS            #
#########################################

resource "aws_lambda_function" "weather_lambda" {
  function_name = "weather-lambda"
  runtime       = "java21"
  role          = aws_iam_role.lambda_role.arn
  handler       = "cloud.localstack.weather.WeatherHandler"
  filename      = "../backend/weather-lambda/target/weather-lambda-1.0.0.jar"

  timeout       = 15
  memory_size   = 512

  vpc_config {
    subnet_ids         = [
      aws_subnet.private_subnet_1.id,
      aws_subnet.private_subnet_2.id,
    ]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      OPEN_WEATHER_API_KEY = var.open_weather_api_key
      HOST          = aws_db_proxy.historydb_proxy.endpoint
      DB_NAME = var.db_name
      DB_USER     = var.db_username
      DB_PASSWORD = var.db_password
    }
  }


  tags = {
    Name = "weather-lambda"
  }

}

resource "aws_lambda_function" "history_lambda" {
  function_name = "history-lambda"
  runtime       = "java21"
  role          = aws_iam_role.lambda_role.arn
  handler       = "cloud.localstack.history.HistoryHandler"
  filename      = "../backend/history-lambda/target/history-lambda-1.0.0.jar"
  timeout       = 15
  memory_size   = 512

  vpc_config {
    subnet_ids         = [
      aws_subnet.private_subnet_1.id,
      aws_subnet.private_subnet_2.id,
    ]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      HOST          = aws_db_proxy.historydb_proxy.endpoint
      DB_NAME = var.db_name
      DB_USER     = var.db_username
      DB_PASSWORD = var.db_password
    }
  }

  tags = {
    Name = "history-lambda"
  }
}

resource "aws_lambda_function" "db_setup_lambda" {
  function_name = "db-setup"
  runtime       = "java21"
  role          = aws_iam_role.lambda_role.arn
  handler       = "cloud.localstack.initdb.InitDBHandler"
  filename      = "../backend/db-setup-lambda/target/db-setup-lambda-1.0.0.jar"
  timeout       = 15
  memory_size   = 512

vpc_config {
    subnet_ids         = [
      aws_subnet.private_subnet_1.id,
      aws_subnet.private_subnet_2.id,
    ]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      HOST          = aws_db_proxy.historydb_proxy.endpoint
      DB_NAME = var.db_name
      DB_USER     = var.db_username
      DB_PASSWORD = var.db_password
    }
  }
}

#########################################
#              API GATEWAY              #
#########################################

resource "aws_apigatewayv2_api" "weather_api" {
  name          = "WeatherAPI"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 3600                        # cache the preflight response for 1 hour
  }
}

resource "aws_apigatewayv2_stage" "dev_stage" {
  api_id      = aws_apigatewayv2_api.weather_api.id
  name        = "dev"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_log_group.arn
    format         = jsonencode({
      requestId               = "$context.requestId"
      sourceIp               = "$context.identity.sourceIp"
      requestTime            = "$context.requestTime"
      protocol              = "$context.protocol"
      httpMethod            = "$context.httpMethod"
      resourcePath          = "$context.resourcePath"
      routeKey              = "$context.routeKey"
      status                = "$context.status"
      responseLength        = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_integration" "weather_integration" {
  api_id           = aws_apigatewayv2_api.weather_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.weather_lambda.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "weather_route" {
  api_id    = aws_apigatewayv2_api.weather_api.id
  route_key = "GET /weather/{location}"
  target    = "integrations/${aws_apigatewayv2_integration.weather_integration.id}"
}

resource "aws_apigatewayv2_route" "options_proxy_weather" {
  api_id    = aws_apigatewayv2_api.weather_api.id
  route_key = "OPTIONS /weather/"
  target    = "integrations/${aws_apigatewayv2_integration.weather_integration.id}"
}


resource "aws_apigatewayv2_integration" "history_integration" {
  api_id           = aws_apigatewayv2_api.weather_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.history_lambda.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "history_route" {
  api_id    = aws_apigatewayv2_api.weather_api.id
  route_key = "GET /history/{location}"
  target    = "integrations/${aws_apigatewayv2_integration.history_integration.id}"
}

resource "aws_apigatewayv2_route" "options_proxy_history" {
  api_id    = aws_apigatewayv2_api.weather_api.id
  route_key = "OPTIONS /history/"
  target    = "integrations/${aws_apigatewayv2_integration.history_integration.id}"
}


# Grant API Gateway permission to invoke the Lambda
resource "aws_lambda_permission" "apigw_invoke_weather" {
  statement_id  = "AllowAPIGatewayInvokeWeather"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.weather_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.weather_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_invoke_history" {
  statement_id  = "AllowAPIGatewayInvokeHistory"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.history_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.weather_api.execution_arn}/*/*"
}


#########################################
#            S3 BUCKET SETUP            #
#########################################

resource "aws_cloudfront_origin_access_identity" "s3_oai" {
  comment = "OAI for secure S3 access"
}


resource "aws_s3_bucket" "weather_validator_bucket" {
  bucket = "weather-validator-bucket"
}

resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.weather_validator_bucket.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_policy" "cloudfront_access" {
  bucket = aws_s3_bucket.weather_validator_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.s3_oai.iam_arn
        },
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.weather_validator_bucket.arn}/*"
      }
    ]
  })
}

#########################################
#     CLOUDFRONT DISTRIBUTION           #
#########################################


resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.weather_validator_bucket.bucket_regional_domain_name
    origin_id   = "S3Origin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.s3_oai.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "WeatherValidatorSite"
  }
}


#########################################
#      UPLOAD FRONTEND FILES TO S3      #
#########################################

resource "aws_s3_object" "frontend_files" {
  for_each = fileset("${path.module}/../frontend", "**/*.*")

  bucket = aws_s3_bucket.weather_validator_bucket.id
  key    = each.value
  source = "${path.module}/../frontend/${each.value}"

  content_type = lookup(
    {
      html = "text/html",
      css  = "text/css",
      js   = "application/javascript",
      json = "application/json",
      svg  = "image/svg+xml"
    },
    split(".", each.value)[length(split(".", each.value)) - 1],
    "application/octet-stream"
  )
}

resource "aws_s3_object" "config_json" {
  bucket = aws_s3_bucket.weather_validator_bucket.id
  key    = "config.json"

  content = jsonencode({
    weatherApiUrl    = "${replace(aws_apigatewayv2_api.weather_api.api_endpoint, "http://", "https://")}/dev/weather",
    historyApiUrl = "${replace(aws_apigatewayv2_api.weather_api.api_endpoint, "http://", "https://")}/dev/history"
  })

  content_type = "application/json"
}

resource "local_file" "config_json" {
  filename = "${path.module}/../frontend/config.json"

  content = jsonencode({
    weatherApiUrl    = "${replace(aws_apigatewayv2_api.weather_api.api_endpoint, "http://", "https://")}/dev/weather",
    historyApiUrl = "${replace(aws_apigatewayv2_api.weather_api.api_endpoint, "http://", "https://")}/dev/history"
  })
}

#########################################
#         OUTPUTS FOR EASY ACCESS       #
#########################################

output "cloudfront_url" {
  description = "CloudFront URL"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}

