document.addEventListener('DOMContentLoaded', () => {
    showTab('weather');
});

function showTab(tabName) {
    document.querySelectorAll('.tab-content').forEach(tab => {
        tab.style.display = 'none';
    });
    document.querySelectorAll('.tab-button').forEach(button => {
        button.classList.remove('active');
    });
    document.getElementById(tabName).style.display = 'block';
    document.querySelector(`.tab-button[onclick="showTab('${tabName}')"]`).classList.add('active');
}

async function fetchWeather() {
    const location = document.getElementById('location').value;
    const config = await fetch('config.json').then(response => response.json());
    const url = `${config.weatherApiUrl}/${location}`;

    const weatherResponseElement = document.getElementById('weatherResponse');
    weatherResponseElement.innerText = '';
    weatherResponseElement.style.display = 'none';

    try {
        const response = await fetch(url, {
            method: 'GET',
            mode: 'cors',
            headers: { 'Content-Type': 'application/json' },
        });

        const text = await response.text();
        const data = text ? JSON.parse(text) : {};

        if (Object.keys(data).length > 0) {
            weatherResponseElement.innerText = JSON.stringify(data, null, 2);
            weatherResponseElement.style.display = 'block';
        } else {
            weatherResponseElement.innerText = 'No data received.';
            weatherResponseElement.style.display = 'block';
        }
    } catch (error) {
        weatherResponseElement.innerText = 'Error: ' + error.message;
        weatherResponseElement.style.display = 'block';
    }
}

async function showHistory() {
    const location = document.getElementById('locationHistory').value;
    const config = await fetch('config.json').then(response => response.json());
    const url = `${config.historyApiUrl}/${location}`;

    const historyResponseElement = document.getElementById('historyResponse');
    historyResponseElement.innerHTML = '';
    historyResponseElement.style.display = 'none';

    try {
        const response = await fetch(url, {
            method: 'GET',
            headers: { 'Content-Type': 'application/json' },
        });
        const data = await response.json();

        if (data.length > 0) {
            let table = '<table class="styled-table"><tr><th>Location</th><th>Time</th><th>Temperature (C)</th><th>Clouds</th><th>Feels Like</th><th>Nice Weather</th><th>Weather Data</th></tr>';
            data.forEach(item => {
                table += `
                    <tr>
                        <td>${item.location}</td>
                        <td>${item.checkTime}</td>
                        <td>${item.tempC}</td>
                        <td>${item.clouds}</td>
                        <td>${item.feelTemp}</td>
                        <td>${item.niceWeather}</td>
                        <td class="weather-cell">
                            <div class="weather-preview">${item.weatherData}</div>
                            <button class="copy-btn" onclick="copyToClipboard(this)">Copy</button>  
                        </td>
                    </tr>`;
            });
            table += '</table>';
            historyResponseElement.innerHTML = table;
            historyResponseElement.style.display = 'block';
        } else {
            historyResponseElement.innerText = 'No weather found with this location.';
            historyResponseElement.style.display = 'block';
        }
    } catch (error) {
        historyResponseElement.innerText = 'Error: ' + error.message;
        historyResponseElement.style.display = 'block';
    }
}


function copyToClipboard(element) {
    const text = element.previousElementSibling.textContent;
    navigator.clipboard.writeText(text).then(() => {
        element.classList.add('copied');
        setTimeout(() => element.classList.remove('copied'), 2000);
    }).catch(err => {
        console.error('Failed to copy: ', err);
    });
}

