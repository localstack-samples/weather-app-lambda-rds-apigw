package cloud.localstack.history;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class HistoryHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    private static final String HOST = System.getenv("HOST");
    private static final String DB_URL = "jdbc:postgresql://" + HOST + "/history";
    private static final String DB_USER = System.getenv("DB_USER");
    private static final String DB_PASSWORD = System.getenv("DB_PASSWORD");

    @Override
    public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {

        String method = (String) input.get("httpMethod");

        if ("OPTIONS".equalsIgnoreCase(method)) {
            return createResponse(200, "CORS preflight passed");
        }

        String locationParam = (String) ((Map<String, Object>) input.get("pathParameters")).get("location");

        String location = java.net.URLDecoder.decode(locationParam, StandardCharsets.UTF_8);


        List<Map<String, Object>> history = retrieveValidationHistory(location);

        if (history.isEmpty()) {
            return createResponse(200, "No weather history found for location: " + location);
        }

        return createResponse(200, history);
    }

    public static List<Map<String, Object>> retrieveValidationHistory(String location) {
        System.out.println("Location: " + location);
        List<Map<String, Object>> historyList = new ArrayList<>();
        String querySQL = "SELECT h.id, h.location, h.check_time, h.temp_c, h.clouds, h.feel_temp, h.nice_weather, c.weather_data " +
                "FROM history h JOIN weather c ON h.id = c.data_id WHERE h.location ILIKE ? ORDER BY h.check_time DESC";

        try (Connection conn = DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD);
             PreparedStatement stmt = conn.prepareStatement(querySQL)) {

            stmt.setString(1, location);
            ResultSet rs = stmt.executeQuery();

            while (rs.next()) {
                Map<String, Object> historyItem = new HashMap<>();
                historyItem.put("id", rs.getInt("id"));
                historyItem.put("location", rs.getString("location"));
                historyItem.put("checkTime", rs.getTimestamp("check_time").toString());
                historyItem.put("tempC", rs.getDouble("temp_c"));
                historyItem.put("clouds", rs.getDouble("clouds"));
                historyItem.put("feelTemp", rs.getDouble("feel_temp"));
                historyItem.put("niceWeather", rs.getBoolean("nice_weather"));

                historyItem.put("weatherData", rs.getString("weather_data"));
                historyList.add(historyItem);
            }

        } catch (SQLException e) {
            System.err.println("Error while retrieving weather history: " + e.getMessage());
        }

        return historyList;
    }

    private Map<String, Object> createResponse(int statusCode, Object body) {
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
            response.put("body", jsonBody);
        } catch (Exception e) {
            response.put("body", "{\"error\":\"Failed to serialize response\"}");
        }

        return response;
    }
}
