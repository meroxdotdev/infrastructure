#!/bin/bash
# Updates /srv/dashboard/data/weather.json — zero AI tokens
# Giroc, Timiș — lat 45.7089, lon 21.2264
# Runs every 30 minutes via crontab

set -euo pipefail

OUTPUT="/srv/dashboard/data/weather.json"

python3 - <<'PYEOF'
import json, sys, urllib.request, urllib.error
from datetime import datetime, timezone

URL = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude=45.7089&longitude=21.2264"
    "&current=temperature_2m,relative_humidity_2m,apparent_temperature,"
    "precipitation,weather_code,wind_speed_10m,wind_direction_10m"
    "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code"
    "&timezone=Europe%2FBucharest&forecast_days=3"
)

WMO_ICONS = {
    0: ("Senin", "☀️"), 1: ("Predominant senin", "🌤️"), 2: ("Parțial noros", "⛅"),
    3: ("Noros", "☁️"), 45: ("Ceață", "🌫️"), 48: ("Ceață cu chiciură", "🌫️"),
    51: ("Burniță ușoară", "🌦️"), 53: ("Burniță", "🌦️"), 55: ("Burniță densă", "🌧️"),
    61: ("Ploaie ușoară", "🌧️"), 63: ("Ploaie moderată", "🌧️"), 65: ("Ploaie abundentă", "🌧️"),
    71: ("Ninsoare ușoară", "🌨️"), 73: ("Ninsoare", "🌨️"), 75: ("Ninsoare abundentă", "❄️"),
    77: ("Granule de zăpadă", "🌨️"), 80: ("Averse ușoare", "🌦️"), 81: ("Averse", "🌧️"),
    82: ("Averse violente", "⛈️"), 85: ("Averse de ninsoare", "🌨️"),
    95: ("Furtună", "⛈️"), 96: ("Furtună cu grindină", "⛈️"), 99: ("Furtună cu grindină mare", "⛈️"),
}

def wmo(code):
    return WMO_ICONS.get(code, ("Necunoscut", "❓"))

try:
    with urllib.request.urlopen(URL, timeout=10) as r:
        data = json.load(r)
except Exception as e:
    print(f"[update-weather] ERROR: {e}", file=sys.stderr)
    sys.exit(1)

c = data["current"]
d = data["daily"]
now = datetime.now(timezone.utc)

desc, icon = wmo(c["weather_code"])

result = {
    "updatedAt": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    "location": "Giroc, Timiș",
    "current": {
        "temp": c["temperature_2m"],
        "feels_like": c["apparent_temperature"],
        "humidity": c["relative_humidity_2m"],
        "wind_kmh": c["wind_speed_10m"],
        "wind_dir": c["wind_direction_10m"],
        "precipitation": c["precipitation"],
        "code": c["weather_code"],
        "description": desc,
        "icon": icon,
    },
    "daily": [
        {
            "date": d["time"][i],
            "max": d["temperature_2m_max"][i],
            "min": d["temperature_2m_min"][i],
            "precip": d["precipitation_sum"][i],
            "code": d["weather_code"][i],
            "icon": wmo(d["weather_code"][i])[0],
            "emoji": wmo(d["weather_code"][i])[1],
        }
        for i in range(min(3, len(d["time"])))
    ]
}

with open("/srv/dashboard/data/weather.json", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"[update-weather] {result['current']['icon']} {result['current']['temp']}°C, {result['current']['description']}")
PYEOF
