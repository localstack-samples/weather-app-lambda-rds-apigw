output "api_gateway_url" {
  value = aws_apigatewayv2_api.weather_api.api_endpoint
}

output "website_url" {
  value = aws_s3_bucket.weather_validator_bucket.website_endpoint
}
