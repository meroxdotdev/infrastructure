#!/bin/bash
# Updates /srv/dashboard/data/weather.json — zero AI tokens
# Giroc, Timiș — lat 45.7089, lon 21.2264
# Runs every 30 minutes via crontab
# Primary: open-meteo.com | Fallback: api.met.no

set -euo pipefail

OUTPUT="/srv/dashboard/data/weather.json"

python3 - <<'PYEOF'
import json, sys, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta

LAT, LON = 45.7089, 21.2264

OPEN_METEO_URL = (
    f"https://api.open-meteo.com/v1/forecast"
    f"?latitude={LAT}&longitude={LON}"
    "&current=temperature_2m,relative_humidity_2m,apparent_temperature,"
    "precipitation,weather_code,wind_speed_10m,wind_direction_10m"
    "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code"
    "&timezone=Europe%2FBucharest&forecast_days=3"
)

MET_NO_URL = (
    f"https://api.met.no/weatherapi/locationforecast/2.0/compact"
    f"?lat={LAT}&lon={LON}"
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

# met.no symbol_code prefix → WMO code approximation
MET_SYMBOL_MAP = {
    "clearsky": 0, "fair": 1, "partlycloudy": 2, "cloudy": 3,
    "fog": 45, "lightrain": 61, "rain": 63, "heavyrain": 65,
    "lightsleet": 61, "sleet": 63, "heavysleet": 65,
    "lightsnow": 71, "snow": 73, "heavysnow": 75,
    "lightrainshowers": 80, "rainshowers": 81, "heavyrainshowers": 82,
    "lightsnowshowers": 85, "snowshowers": 85,
    "lightrainandthunder": 95, "rainandthunder": 95, "heavyrainandthunder": 95,
    "snowandthunder": 95, "lightrainshowersandthunder": 95,
    "rainshowersandthunder": 95, "heavyrainshowersandthunder": 95,
}

def wmo(code):
    return WMO_ICONS.get(code, ("Necunoscut", "❓"))

def met_symbol_to_wmo(symbol_code):
    # strip _day/_night/_polartwilight suffix
    base = symbol_code.split("_")[0] if symbol_code else ""
    return MET_SYMBOL_MAP.get(base, 3)

def fetch_open_meteo():
    with urllib.request.urlopen(OPEN_METEO_URL, timeout=10) as r:
        data = json.load(r)
    c = data["current"]
    d = data["daily"]
    now = datetime.now(timezone.utc)
    desc, icon = wmo(c["weather_code"])
    return {
        "updatedAt": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        "location": "Giroc, Timiș",
        "source": "open-meteo",
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

def fetch_met_no():
    req = urllib.request.Request(MET_NO_URL, headers={"User-Agent": "merox-dashboard/1.0 github.com/meroxdotdev"})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.load(r)

    now = datetime.now(timezone.utc)
    timeseries = data["properties"]["timeseries"]

    # Find the closest timeslot to now
    def ts_dt(ts):
        return datetime.fromisoformat(ts["time"].replace("Z", "+00:00"))

    current_ts = min(timeseries, key=lambda ts: abs((ts_dt(ts) - now).total_seconds()))
    ci = current_ts["data"]["instant"]["details"]
    n1 = current_ts["data"].get("next_1_hours", {})
    symbol = n1.get("summary", {}).get("symbol_code", "cloudy")
    precip = n1.get("details", {}).get("precipitation_amount", 0.0)
    wmo_code = met_symbol_to_wmo(symbol)
    desc, icon = wmo(wmo_code)

    # Build daily: for each of next 3 days, find max/min temp from timeseries
    today = now.date()
    daily = []
    for offset in range(3):
        day_date = today + timedelta(days=offset)
        day_slots = [ts for ts in timeseries if ts_dt(ts).date() == day_date]
        if not day_slots:
            continue
        temps = [ts["data"]["instant"]["details"]["air_temperature"] for ts in day_slots]
        # use midday slot for symbol if available
        midday = min(day_slots, key=lambda ts: abs(ts_dt(ts).hour - 12))
        d_sym = midday["data"].get("next_6_hours", midday["data"].get("next_1_hours", {})).get("summary", {}).get("symbol_code", "cloudy")
        d_precip = midday["data"].get("next_6_hours", {}).get("details", {}).get("precipitation_amount", 0.0)
        d_wmo = met_symbol_to_wmo(d_sym)
        daily.append({
            "date": day_date.strftime('%Y-%m-%d'),
            "max": round(max(temps), 1),
            "min": round(min(temps), 1),
            "precip": d_precip,
            "code": d_wmo,
            "icon": wmo(d_wmo)[0],
            "emoji": wmo(d_wmo)[1],
        })

    wind_ms = ci.get("wind_speed", 0)
    return {
        "updatedAt": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        "location": "Giroc, Timiș",
        "source": "met.no",
        "current": {
            "temp": ci["air_temperature"],
            "feels_like": ci["air_temperature"],  # met.no compact doesn't expose feels_like
            "humidity": ci.get("relative_humidity", 0),
            "wind_kmh": round(wind_ms * 3.6, 1),
            "wind_dir": ci.get("wind_from_direction", 0),
            "precipitation": precip,
            "code": wmo_code,
            "description": desc,
            "icon": icon,
        },
        "daily": daily[:3],
    }

result = None

try:
    result = fetch_open_meteo()
    print(f"[update-weather] open-meteo ✓ {result['current']['icon']} {result['current']['temp']}°C, {result['current']['description']}")
except Exception as e:
    print(f"[update-weather] open-meteo FAIL: {e} — trying met.no fallback", file=sys.stderr)
    try:
        result = fetch_met_no()
        print(f"[update-weather] met.no ✓ {result['current']['icon']} {result['current']['temp']}°C, {result['current']['description']}")
    except Exception as e2:
        print(f"[update-weather] met.no FAIL: {e2}", file=sys.stderr)
        sys.exit(1)

with open("/srv/dashboard/data/weather.json", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
PYEOF
