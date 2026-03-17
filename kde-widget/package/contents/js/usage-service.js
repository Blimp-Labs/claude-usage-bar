.pragma library

var USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage";
var TOKEN_ENDPOINT = "https://console.anthropic.com/v1/oauth/token";
var CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
var REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
var AUTHORIZE_URL = "https://claude.ai/oauth/authorize";

// Generate a random base64url string for PKCE
function generateRandomString(length) {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var result = "";
    for (var i = 0; i < length; i++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

// Build the OAuth authorize URL (without PKCE challenge - simplified for widget)
function buildAuthorizeUrl(state) {
    var url = AUTHORIZE_URL
        + "?code=true"
        + "&client_id=" + encodeURIComponent(CLIENT_ID)
        + "&response_type=code"
        + "&redirect_uri=" + encodeURIComponent(REDIRECT_URI)
        + "&scope=" + encodeURIComponent("user:profile user:inference")
        + "&state=" + encodeURIComponent(state);
    return url;
}

// Exchange authorization code for token
function exchangeToken(code, state, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open("POST", TOKEN_ENDPOINT);
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.DONE) {
            if (xhr.status === 200) {
                try {
                    var response = JSON.parse(xhr.responseText);
                    callback(null, response.access_token);
                } catch (e) {
                    callback("Failed to parse token response", null);
                }
            } else {
                callback("Token exchange failed: HTTP " + xhr.status, null);
            }
        }
    };
    var body = JSON.stringify({
        grant_type: "authorization_code",
        code: code,
        state: state,
        client_id: CLIENT_ID,
        redirect_uri: REDIRECT_URI
    });
    xhr.send(body);
}

// Fetch usage data from Anthropic API
function fetchUsage(token, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open("GET", USAGE_ENDPOINT);
    xhr.setRequestHeader("Authorization", "Bearer " + token);
    xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20");
    xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.DONE) {
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    callback(null, data);
                } catch (e) {
                    callback("Failed to parse usage response", null);
                }
            } else if (xhr.status === 401) {
                callback("session_expired", null);
            } else if (xhr.status === 429) {
                callback("rate_limited", null);
            } else {
                callback("HTTP " + xhr.status, null);
            }
        }
    };
    xhr.send();
}

// Parse usage response into a simpler object
function parseUsage(data) {
    var result = {
        pct5h: 0,
        pct7d: 0,
        reset5h: "",
        reset7d: "",
        pct7dOpus: -1,
        pct7dSonnet: -1,
        reset7dOpus: "",
        reset7dSonnet: "",
        extraEnabled: false,
        extraUtilization: 0,
        extraUsed: 0,
        extraLimit: 0
    };

    if (data.five_hour) {
        result.pct5h = data.five_hour.utilization || 0;
        result.reset5h = data.five_hour.resets_at || "";
    }
    if (data.seven_day) {
        result.pct7d = data.seven_day.utilization || 0;
        result.reset7d = data.seven_day.resets_at || "";
    }
    if (data.seven_day_opus && data.seven_day_opus.utilization !== undefined && data.seven_day_opus.utilization !== null) {
        result.pct7dOpus = data.seven_day_opus.utilization;
        result.reset7dOpus = data.seven_day_opus.resets_at || "";
    }
    if (data.seven_day_sonnet && data.seven_day_sonnet.utilization !== undefined && data.seven_day_sonnet.utilization !== null) {
        result.pct7dSonnet = data.seven_day_sonnet.utilization;
        result.reset7dSonnet = data.seven_day_sonnet.resets_at || "";
    }
    if (data.extra_usage) {
        result.extraEnabled = data.extra_usage.is_enabled || false;
        result.extraUtilization = data.extra_usage.utilization || 0;
        result.extraUsed = (data.extra_usage.used_credits || 0) / 100.0;
        result.extraLimit = (data.extra_usage.monthly_limit || 0) / 100.0;
    }

    return result;
}

// Format reset time as relative string
function formatResetTime(isoString) {
    if (!isoString) return "";
    var resetDate = new Date(isoString);
    var now = new Date();
    var diffMs = resetDate.getTime() - now.getTime();
    if (diffMs <= 0) return "jetzt";

    var diffMin = Math.floor(diffMs / 60000);
    var diffHours = Math.floor(diffMin / 60);
    var remainMin = diffMin % 60;

    if (diffHours > 24) {
        var days = Math.floor(diffHours / 24);
        var remHours = diffHours % 24;
        return "in " + days + "T " + remHours + "h";
    }
    if (diffHours > 0) {
        return "in " + diffHours + "h " + remainMin + "m";
    }
    return "in " + diffMin + "m";
}

function colorForPct(pct) {
    var ratio = pct / 100.0;
    if (ratio < 0.60) return "#27ae60";
    if (ratio < 0.80) return "#f1c40f";
    return "#e74c3c";
}

function formatUSD(amount) {
    return "$" + amount.toFixed(2);
}
