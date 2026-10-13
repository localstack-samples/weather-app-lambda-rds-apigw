#!/bin/bash
# Check a weather lookup through API Gateway, Lambda and the RDS proxy, then
# read it back from the history endpoint.
#
# If the weather Lambda points at the OpenWeather stub (OPEN_WEATHER_BASE_URL
# set to an S3 object, as in CI), the stub is filled with the fixtures in
# tests/fixtures and both verdicts are checked with exact values. Otherwise the
# real OpenWeather API is called for $CITY and only the response shape is checked.
set -euo pipefail

cd "$(dirname "$0")"
TF_DIR=${TF_DIR:-terraform-local}
STUB_BUCKET=${STUB_BUCKET:-weather-stub}
CITY=${CITY:-London}

API=$(cd "$TF_DIR" && lstk tf output -raw api_gateway_url)
API=${API%/}
echo "API: $API"

host=$(lstk aws lambda get-function-configuration --function-name weather-lambda \
  --query Environment.Variables.HOST --output text)
if [[ "$host" != *?:* || "$host" == :* ]]; then
  echo "Test failed: weather-lambda HOST is '$host', expected <proxy endpoint>:<port>. Run the deploy again."
  exit 1
fi

# Print the body, or fail with the status and body on a non-200 response
get() {
  local response status
  response=$(curl -sk -m 120 -w '\n%{http_code}' "$1")
  status=${response##*$'\n'}
  response=${response%$'\n'*}
  if [ "$status" != "200" ]; then
    echo "Test failed: GET $1 returned HTTP $status: $response" >&2
    return 1
  fi
  echo "$response"
}

echo "Creating the database tables"
lstk aws lambda invoke --function-name db-setup --cli-read-timeout 120 /tmp/db-setup.json > /dev/null
if ! jq -e '.statusCode == 200' /tmp/db-setup.json > /dev/null; then
  echo "Test failed: db-setup returned $(cat /tmp/db-setup.json)"
  exit 1
fi
echo "PASS: db-setup created the tables"

# check_weather <city> <expected verdict> <expected temperature or empty>
check_weather() {
  local city=$1 verdict=$2 temp=$3 body
  body=$(get "$API/dev/weather/$city" | jq -r .)
  echo "$body"
  if [[ "$body" != *"$verdict"*"Location: $city."* ]]; then
    echo "Test failed: expected '$verdict' for $city"
    exit 1
  fi
  if [ -n "$temp" ] && [[ "$body" != *"Temperature: $temp °C"* ]]; then
    echo "Test failed: expected a temperature of $temp °C for $city"
    exit 1
  fi
  echo "PASS: weather check for $city"
}

# check_history <city> <jq filter on the newest entry>
check_history() {
  local city=$1 filter=$2 history
  history=$(get "$API/dev/history/$city")
  if ! echo "$history" | jq -e --arg c "$city" \
      "type == \"array\" and length > 0 and (.[0] | .location == \$c and ($filter))" > /dev/null; then
    echo "Test failed: history for $city is $history"
    exit 1
  fi
  echo "PASS: history for $city has the stored check"
}

base_url=$(lstk aws lambda get-function-configuration --function-name weather-lambda \
  --query Environment.Variables.OPEN_WEATHER_BASE_URL --output text)

if [[ "$base_url" == *"/$STUB_BUCKET/"* ]]; then
  stub_key=${base_url##*/$STUB_BUCKET/}
  echo "Using the OpenWeather stub s3://$STUB_BUCKET/$stub_key"
  lstk aws s3 mb "s3://$STUB_BUCKET" > /dev/null 2>&1 || true
  lstk aws s3api put-bucket-policy --bucket "$STUB_BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$STUB_BUCKET/*\"}]}"

  lstk aws s3 cp tests/fixtures/lisbon.json "s3://$STUB_BUCKET/$stub_key" --content-type application/json > /dev/null
  check_weather Lisbon "The weather is quite nice here." "24.50"
  check_history Lisbon '.niceWeather == true and .tempC == 24.5 and .clouds == 0 and (.weatherData | fromjson | .sys.country == "PT")'

  lstk aws s3 cp tests/fixtures/oslo.json "s3://$STUB_BUCKET/$stub_key" --content-type application/json > /dev/null
  check_weather Oslo "The weather is not so nice here." "8.20"
  check_history Oslo '.niceWeather == false and .tempC == 8.2 and .clouds == 100'
else
  echo "Using the OpenWeather API for $CITY"
  check_weather "$CITY" "" ""
  check_history "$CITY" '.weatherData | fromjson | .name != null'
fi

body=$(get "$API/dev/history/Atlantis" | jq -r .)
if [ "$body" != "No weather history found for location: Atlantis" ]; then
  echo "Test failed: history for an unchecked city returned '$body'"
  exit 1
fi
echo "PASS: unchecked city has no history"

echo "Test passed: weather checks are stored in RDS and served by the history API"
