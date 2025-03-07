package cloud.localstack.initdb;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;

public class InitDBHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    private static final String HOST = System.getenv("HOST");
    private static final String DB_NAME = System.getenv("DB_NAME");
    private static final String DB_USER = System.getenv("DB_USER");
    private static final String DB_PASSWORD = System.getenv("DB_PASSWORD");


    @Override
    public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {
        try (Connection conn = getDbConnection();
             Statement stmt = conn.createStatement()) {

            String createHistoryTableQuery = "CREATE TABLE history (" +
                    "    id SERIAL PRIMARY KEY," +
                    "    location VARCHAR(50) NOT NULL," +
                    "    check_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP," +
                    "    temp_c DOUBLE PRECISION NOT NULL," +
                    "    clouds DOUBLE PRECISION NOT NULL," +
                    "    nice_weather BOOLEAN NOT NULL," +
                    "    feel_temp DOUBLE PRECISION NOT NULL);";
            stmt.executeUpdate(createHistoryTableQuery);

            String createWeatherTableQuery = "CREATE TABLE weather (" +
                    "    data_id INTEGER PRIMARY KEY," +
                    "    weather_data JSONB NOT NULL," +
                    "    CONSTRAINT fk_history" +
                    "        FOREIGN KEY (data_id)" +
                    "        REFERENCES history (id)" +
                    "        ON DELETE CASCADE" +
                    ");";
            // Create the roles
            stmt.executeUpdate(createWeatherTableQuery);

            return Map.of(
                    "statusCode", 200,
                    "body", "Table created successfully!"
            );

        } catch (SQLException e) {
            e.printStackTrace();
            return Map.of(
                    "statusCode", 500,
                    "body", "Error: " + e.getMessage()
            );
        }
    }


    private static Connection getDbConnection() {
        String jdbcUrl = String.format("jdbc:postgresql://%s/%s",
                HOST, DB_NAME);

        try {
            return DriverManager.getConnection(jdbcUrl, DB_USER, DB_PASSWORD);
        } catch (SQLException e) {
            e.printStackTrace();
            throw new RuntimeException("Database connection failed", e);
        }
    }

}
