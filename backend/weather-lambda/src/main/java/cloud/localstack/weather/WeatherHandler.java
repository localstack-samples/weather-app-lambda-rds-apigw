package cloud.localstack.weather;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.HashMap;
import java.util.Map;

public class WeatherHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    private static final String HOST = System.getenv("HOST");
    private static final String DB_URL = "jdbc:postgresql://" + HOST + "/history";
    private static final String DB_USER = System.getenv("DB_USER");
    private static final String DB_PASSWORD = System.getenv("DB_PASSWORD");
    private static final String OPEN_WEATHER_API_KEY = System.getenv("OPEN_WEATHER_API_KEY");
    private static final String BASE_URL  = "https://api.openweathermap.org/data/2.5/weather";


    @Override
    public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {

        String method = (String) input.get("httpMethod");

        if ("OPTIONS".equalsIgnoreCase(method)) {
            return createResponse(200, "CORS preflight passed");
        }

        Map<String, String> pathParameters = (Map<String, String>) input.get("pathParameters");

        System.out.println(pathParameters);

        if (pathParameters == null || !pathParameters.containsKey("location")) {
            return createResponse(400, "Error: 'location' path parameter is missing.");
        }

        String city = pathParameters.get("location");
        return fetchAndSaveWeatherData(city);
    }

    public Map<String, Object> fetchAndSaveWeatherData(String city) {
        try {

            String urlString = BASE_URL + "?q=" + city
                    + "&units=metric" + "&appid=" + OPEN_WEATHER_API_KEY;
            URL url = new URL(urlString);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");

            int responseCode = conn.getResponseCode();
            if (responseCode != 200) {
                return createResponse(responseCode, "Failed to fetch data from OpenWeather API. Response code: " + responseCode);
            }

            BufferedReader in = new BufferedReader(new InputStreamReader(conn.getInputStream()));
            StringBuilder response = new StringBuilder();
            String inputLine;

            while ((inputLine = in.readLine()) != null) {
                response.append(inputLine);
            }
            in.close();

            return validateWeather(response.toString());

        } catch (Exception e) {
            return createResponse(500, "Error while fetching weather from OpenWeather API: " + e.getMessage());
        }
    }

    public Map<String, Object> validateWeather(String jsonInput) {
        try {
            ObjectMapper objectMapper = new ObjectMapper();
            JsonNode root = objectMapper.readTree(jsonInput);

            // Extract values
            var location = root.get("name").asText();
            var clouds = root.get("clouds").get("all").asDouble();

            var tempC = root.get("main").get("temp").asDouble();
            var feelTemp = root.get("main").get("feels_like").asDouble();
            var timezone = root.get("timezone").asInt();

            long currentUtcMillis = System.currentTimeMillis();

            // Convert timezone offset to milliseconds
            long offsetMillis = timezone * 1000L;

            // Compute local time
            long localTimeMillis = currentUtcMillis + offsetMillis;
            Timestamp localTimestamp = new Timestamp(localTimeMillis);


            // Determine if the weather is "nice"
            boolean niceWeather = tempC > 20.0 && clouds < 40.0;

            StringBuilder result = new StringBuilder();
            if (niceWeather) {
                result.append(String.format("The weather is quite nice here. Location: %s. Time of weather check: %s. Temperature: %.2f °C",
                        location, localTimestamp, tempC));
            } else {
                result.append(String.format("The weather is not so nice here. Location: %s. Time of weather check: %s. Temperature: %.2f °C",
                        location, localTimestamp, tempC));
            }

            // Save validation result to database
            saveValidationResult(location, localTimestamp, tempC, clouds, feelTemp, niceWeather, jsonInput);

            System.out.println(result);
            return createResponse(200, String.valueOf(result));

        } catch (Exception e) {
            return createResponse(500, "Error while validating weather data: " + e.getMessage());
        }
    }

    public static void saveValidationResult(String location, Timestamp localTimestamp, Double tempC, Double clouds, Double feelTemp, Boolean niceWeather, String jsonInput) {
        String insertHistorySQL = "INSERT INTO history (location, check_time, temp_c, clouds, feel_temp, nice_weather) VALUES (?, ?, ?, ?, ?, ?) RETURNING id";
        String insertWeatherSQL = "INSERT INTO weather (data_id, weather_data) VALUES (?, ?::jsonb)";

        try (Connection conn = DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD)) {

            conn.setTransactionIsolation(Connection.TRANSACTION_SERIALIZABLE);
            conn.setAutoCommit(false);
            System.out.println("Database connection established.");

            try (
                    PreparedStatement historyStmt = conn.prepareStatement(insertHistorySQL);
                    PreparedStatement weatherStmt = conn.prepareStatement(insertWeatherSQL)
            ) {
                System.out.println("Prepared statements created.");

                // Insert into history
                historyStmt.setString(1, location);
                historyStmt.setTimestamp(2, localTimestamp);
                historyStmt.setDouble(3, tempC);
                historyStmt.setDouble(4, clouds);
                historyStmt.setDouble(5, feelTemp);
                historyStmt.setBoolean(6, niceWeather);


                try (ResultSet rs = historyStmt.executeQuery()) {
                    if (rs.next()) {
                        int id = rs.getInt("id");
                        System.out.println("History record inserted with ID: " + id);

                        // Insert into weather
                        weatherStmt.setInt(1, id);
                        weatherStmt.setString(2, jsonInput);
                        weatherStmt.executeUpdate();
                        System.out.println("Weather data record inserted successfully.");
                    } else {
                        throw new SQLException("Failed to retrieve history location.");
                    }
                }

                conn.commit();
                System.out.println("Transaction committed successfully.");

            } catch (SQLException e) {
                conn.rollback();
                System.err.println("Transaction rolled back due to error: " + e.getMessage());
            }

        } catch (SQLException e) {
            System.err.println("Database connection error: " + e.getMessage());
        }
    }

    private static Map<String, Object> createResponse(int statusCode, String body) {
        Map<String, Object> response = new HashMap<>();
        response.put("isBase64Encoded", false);
        response.put("statusCode", statusCode);
        Map<String, String> headers = new HashMap<>();
        headers.put("Content-Type", "application/json");
        headers.put("Access-Control-Allow-Origin", "*");  // Allow requests from any origin
        headers.put("Access-Control-Allow-Methods", "GET, POST, OPTIONS");  // Allow these methods
        headers.put("Access-Control-Allow-Headers", "Content-Type");  // Allow specific headers
        response.put("headers", headers);
        try {
            ObjectMapper mapper = new ObjectMapper();
            String jsonBody = (body == null) ? "{\"message\":\"No data available\"}" : mapper.writeValueAsString(body);
            response.put("body", jsonBody);  // ✅ Ensure non-empty JSON
        } catch (Exception e) {
            response.put("body", "{\"error\":\"Failed to serialize response\"}");
        }
        return response;
    }
}
