#!/usr/bin/env python3
"""
Mock Anthropic usage API server for testing ClaudeUsageBar.

Usage:
    python3 scripts/mock-server.py [--port 8080] [--scenario normal]

Scenarios:
    normal          - Moderate usage (5h: 25%, 7d: 45%)
    high            - Near rate limit (5h: 85%, 7d: 92%)
    maxed           - Fully rate limited (5h: 100%, 7d: 100%)
    low             - Barely used (5h: 2%, 7d: 5%)
    extra           - Extra usage enabled with credits
    extra_high      - Extra usage near limit
    per_model       - Per-model breakdown via legacy seven_day_* fields (Opus + Sonnet)
    model_scoped    - Per-model breakdown via limits[] (Fable 5 + Opus + Sonnet)
    model_scoped_no_reset
                    - limits[] entry with a null resets_at (exercises reconciliation)
    fable_mixed     - Fable 5 via limits[], Opus/Sonnet via legacy seven_day_* fields
    all_features    - Everything enabled: per-model, extra usage
    unauthenticated - Returns 401 for all requests
    rate_limited    - Returns 429 with Retry-After header
    error           - Returns 500 server error

To point the app at this server, set the endpoint override before launching it:
    CLAUDE_USAGE_BAR_USAGE_ENDPOINT=http://127.0.0.1:8080/api/oauth/usage \
        macos/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar

Only loopback hosts are honoured. This only mocks the usage endpoint for refresh/testing.
The server also exposes a fake /v1/oauth/token endpoint for manual experiments,
but the app does not use it unless you explicitly repoint its auth flow too.
"""

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler


def iso_future(hours=0, days=0):
    dt = datetime.now(timezone.utc) + timedelta(hours=hours, days=days)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")


def weekly_scoped(display_name, percent, days=5, resets=True):
    """A model-scoped weekly window, matching a payload captured from the real
    endpoint on 2026-08-19 (note group is "weekly", not "subscription")."""
    return {
        "kind": "weekly_scoped",
        "group": "weekly",
        "percent": percent,
        "severity": "normal",
        "resets_at": iso_future(days=days) if resets else None,
        "scope": {"model": {"id": None, "display_name": display_name}, "surface": None},
        "is_active": True,
    }


def unscoped_limits(five_hour_pct, seven_day_pct):
    """The two unscoped entries the real endpoint always sends alongside."""
    return [
        {
            "kind": "session", "group": "session", "percent": five_hour_pct,
            "severity": "normal", "resets_at": iso_future(hours=3),
            "scope": None, "is_active": False,
        },
        {
            "kind": "weekly_all", "group": "weekly", "percent": seven_day_pct,
            "severity": "normal", "resets_at": iso_future(days=4),
            "scope": None, "is_active": False,
        },
    ]


SCENARIOS = {
    "normal": {
        "five_hour": {"utilization": 25.0, "resets_at": iso_future(hours=3)},
        "seven_day": {"utilization": 45.0, "resets_at": iso_future(days=4)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "high": {
        "five_hour": {"utilization": 85.0, "resets_at": iso_future(hours=1)},
        "seven_day": {"utilization": 92.0, "resets_at": iso_future(days=2)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "maxed": {
        "five_hour": {"utilization": 100.0, "resets_at": iso_future(hours=4)},
        "seven_day": {"utilization": 100.0, "resets_at": iso_future(days=6)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "low": {
        "five_hour": {"utilization": 2.0, "resets_at": iso_future(hours=4)},
        "seven_day": {"utilization": 5.0, "resets_at": iso_future(days=6)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "extra": {
        "five_hour": {"utilization": 40.0, "resets_at": iso_future(hours=2)},
        "seven_day": {"utilization": 60.0, "resets_at": iso_future(days=3)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": True,
            "monthly_limit": 28000,
            "used_credits": 5230,
            "utilization": 18.68,
        },
    },
    "extra_high": {
        "five_hour": {"utilization": 95.0, "resets_at": iso_future(hours=1)},
        "seven_day": {"utilization": 98.0, "resets_at": iso_future(days=1)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": True,
            "monthly_limit": 10000,
            "used_credits": 9450,
            "utilization": 94.5,
        },
    },
    "per_model": {
        "five_hour": {"utilization": 35.0, "resets_at": iso_future(hours=3)},
        "seven_day": {"utilization": 55.0, "resets_at": iso_future(days=4)},
        "seven_day_opus": {"utilization": 70.0, "resets_at": iso_future(days=5)},
        "seven_day_sonnet": {"utilization": 15.0, "resets_at": iso_future(days=5)},
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "model_scoped": {
        "five_hour": {"utilization": 35.0, "resets_at": iso_future(hours=3)},
        "seven_day": {"utilization": 55.0, "resets_at": iso_future(days=4)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "limits": unscoped_limits(35.0, 55.0) + [
            weekly_scoped("Fable", 48.5),
            weekly_scoped("Opus", 70.0),
            weekly_scoped("Sonnet", 15.0),
        ],
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "model_scoped_no_reset": {
        "five_hour": {"utilization": 35.0, "resets_at": iso_future(hours=3)},
        "seven_day": {"utilization": 55.0, "resets_at": iso_future(days=4)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "limits": [weekly_scoped("Fable", 52.0, resets=False)],
        "extra_usage": {
            "is_enabled": False,
            "monthly_limit": None,
            "used_credits": None,
            "utilization": None,
        },
    },
    "fable_mixed": {
        "five_hour": {"utilization": 35.0, "resets_at": iso_future(hours=3)},
        "seven_day": {"utilization": 55.0, "resets_at": iso_future(days=4)},
        "seven_day_opus": {"utilization": 70.0, "resets_at": iso_future(days=5)},
        "seven_day_sonnet": {"utilization": 15.0, "resets_at": iso_future(days=5)},
        "seven_day_oauth_apps": None,
        "limits": [weekly_scoped("Fable", 48.5)],
        "extra_usage": {
            "is_enabled": True,
            "monthly_limit": 28000,
            "used_credits": 5230,
            "utilization": 18.68,
        },
    },
    "all_features": {
        "five_hour": {"utilization": 62.0, "resets_at": iso_future(hours=2)},
        "seven_day": {"utilization": 78.0, "resets_at": iso_future(days=3)},
        "seven_day_opus": None,
        "seven_day_sonnet": None,
        "seven_day_oauth_apps": None,
        "seven_day_cowork": None,
        "iguana_necktie": None,
        "limits": [
            weekly_scoped("Fable", 64.0, days=4),
            weekly_scoped("Opus", 88.0, days=4),
            weekly_scoped("Sonnet", 25.0, days=4),
        ],
        "extra_usage": {
            "is_enabled": True,
            "monthly_limit": 50000,
            "used_credits": 12750,
            "utilization": 25.5,
        },
    },
}


class MockHandler(BaseHTTPRequestHandler):
    scenario = "normal"

    def do_GET(self):
        if self.path == "/api/oauth/usage":
            self.handle_usage()
        elif self.path.startswith("/scenario/"):
            self.handle_set_scenario()
        elif self.path == "/api/oauth/userinfo":
            self.handle_userinfo()
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/v1/oauth/token":
            self.handle_token()
        else:
            self.send_error(404)

    def handle_set_scenario(self):
        name = self.path.split("/scenario/", 1)[1]
        all_scenarios = list(SCENARIOS.keys()) + ["unauthenticated", "rate_limited", "error"]
        if name not in all_scenarios:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"Unknown scenario: {name}", "available": all_scenarios}).encode())
            return
        self.server.scenario = name
        print(f"\n>>> Scenario switched to: {name}\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"scenario": name}).encode())

    def handle_userinfo(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"email": "test@example.com", "name": "Test User"}).encode())

    def handle_usage(self):
        scenario = self.server.scenario

        if scenario == "unauthenticated":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "unauthorized"}).encode())
            return

        if scenario == "rate_limited":
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "120")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "rate_limited"}).encode())
            return

        if scenario == "error":
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps({"error": "internal_server_error"}).encode()
            )
            return

        data = SCENARIOS.get(scenario, SCENARIOS["normal"])
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def handle_token(self):
        # Accept any code and return a fake token
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            json.dumps(
                {
                    "access_token": "mock-test-token-12345",
                    "token_type": "bearer",
                    "scope": "user:profile user:inference",
                }
            ).encode()
        )

    def log_message(self, format, *args):
        scenario = self.server.scenario
        print(f"[{scenario}] {args[0]}")


def main():
    parser = argparse.ArgumentParser(description="Mock Anthropic usage API server")
    parser.add_argument(
        "--port", type=int, default=8080, help="Port to listen on (0 picks a free one)"
    )
    parser.add_argument(
        "--scenario",
        default="normal",
        choices=list(SCENARIOS.keys())
        + ["unauthenticated", "rate_limited", "error"],
        help="Response scenario",
    )
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), MockHandler)
    server.scenario = args.scenario

    # Report the bound port, not the requested one: --port 0 picks a free port,
    # which lets callers (e.g. the integration tests) run without racing.
    port = server.server_address[1]

    print(f"Mock server running on http://127.0.0.1:{port}", flush=True)
    print(f"Scenario: {args.scenario}")
    print()
    print("Available scenarios:")
    for name in list(SCENARIOS.keys()) + ["unauthenticated", "rate_limited", "error"]:
        print(f"  --scenario {name}")
    print()
    print("Switch scenario at runtime:")
    print(f"  curl http://127.0.0.1:{port}/scenario/high")
    print(f"  curl http://127.0.0.1:{port}/scenario/low")
    print()
    print("Test notification flow:")
    print(f"  1. Point app at http://127.0.0.1:{port}")
    print(f"  2. Start with: --scenario low")
    print(f"  3. Wait for one poll, then: curl http://127.0.0.1:{port}/scenario/high")
    print(f"  4. Next poll should trigger a notification")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
