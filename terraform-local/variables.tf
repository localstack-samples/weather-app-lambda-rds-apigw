variable "aws_region" {
  default = "us-east-1"
}

variable "db_name" {
  default = "history"
}

variable "db_username" {
  default = "lambda_user"
}

variable "db_password" {
  default = "supersecurepassword"
}

variable "aws_account_id" {
  default = "000000000000"
}

variable "open_weather_api_key" {
  default = "your_open_weather_api_key"
}

variable "open_weather_base_url" {
  description = "OpenWeather current weather endpoint. Point it at a stub to run without an API key."
  default     = "https://api.openweathermap.org/data/2.5/weather"
}
