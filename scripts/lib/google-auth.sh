#!/usr/bin/env bash
# Google OAuth2 token refresh helper for "installed app" flow.
# Sources .env for GOOGLE_OAUTH_CREDENTIALS path.
# Outputs a valid access token to stdout.
# Diagnostics go to stderr.
#
# Usage (from other scripts):
#   source "$(dirname "$0")/lib/google-auth.sh"
#   ACCESS_TOKEN=$(get_google_access_token)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOKEN_FILE="$REPO_ROOT/token.json"
ENV_FILE="$REPO_ROOT/.env"

# Load .env if present
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

SCOPES="https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly"

get_google_access_token() {
  local creds_file="${GOOGLE_OAUTH_CREDENTIALS:-}"

  if [[ -z "$creds_file" ]]; then
    echo "ERROR: GOOGLE_OAUTH_CREDENTIALS not set in .env" >&2
    return 1
  fi

  # Resolve relative paths from repo root
  if [[ "$creds_file" != /* ]]; then
    creds_file="$REPO_ROOT/$creds_file"
  fi

  if [[ ! -f "$creds_file" ]]; then
    echo "ERROR: Credentials file not found: $creds_file" >&2
    return 1
  fi

  local client_id client_secret
  client_id=$(jq -r '.installed.client_id // .web.client_id' "$creds_file")
  client_secret=$(jq -r '.installed.client_secret // .web.client_secret' "$creds_file")

  if [[ -z "$client_id" || "$client_id" == "null" ]]; then
    echo "ERROR: Could not extract client_id from credentials file" >&2
    return 1
  fi

  # If we have a saved refresh token, use it
  if [[ -f "$TOKEN_FILE" ]]; then
    local refresh_token
    refresh_token=$(jq -r '.refresh_token' "$TOKEN_FILE")

    if [[ -n "$refresh_token" && "$refresh_token" != "null" ]]; then
      local response
      response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
        -d "client_id=$client_id" \
        -d "client_secret=$client_secret" \
        -d "refresh_token=$refresh_token" \
        -d "grant_type=refresh_token")

      local access_token
      access_token=$(echo "$response" | jq -r '.access_token // empty')

      if [[ -n "$access_token" ]]; then
        echo "$access_token"
        return 0
      fi

      echo "WARNING: Refresh token expired or invalid, re-authorizing..." >&2
    fi
  fi

  # First-run: need browser consent
  echo "No valid token found. Starting OAuth2 consent flow..." >&2
  echo "A browser window will open for Google authorization." >&2

  local redirect_uri="http://localhost:8085"
  local auth_url="https://accounts.google.com/o/oauth2/v2/auth?client_id=${client_id}&redirect_uri=${redirect_uri}&response_type=code&scope=$(echo "$SCOPES" | sed 's/ /%20/g')&access_type=offline&prompt=consent"

  echo "Opening: $auth_url" >&2
  open "$auth_url" 2>/dev/null || echo "Please open this URL in your browser: $auth_url" >&2

  # Start a minimal listener to capture the redirect
  echo "Waiting for authorization callback on port 8085..." >&2
  local auth_code
  auth_code=$(
    # Use a single-request netcat listener to capture the auth code
    (echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authorization complete!</h2><p>You can close this tab.</p></body></html>" | \
      nc -l 8085 2>/dev/null) | head -1 | sed -n 's/.*code=\([^& ]*\).*/\1/p'
  )

  if [[ -z "$auth_code" ]]; then
    echo "ERROR: Failed to capture authorization code" >&2
    return 1
  fi

  # Exchange auth code for tokens
  local token_response
  token_response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
    -d "client_id=$client_id" \
    -d "client_secret=$client_secret" \
    -d "code=$auth_code" \
    -d "redirect_uri=$redirect_uri" \
    -d "grant_type=authorization_code")

  local access_token refresh_token
  access_token=$(echo "$token_response" | jq -r '.access_token // empty')
  refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')

  if [[ -z "$access_token" ]]; then
    echo "ERROR: Token exchange failed: $(echo "$token_response" | jq -r '.error_description // .error // "unknown error"')" >&2
    return 1
  fi

  # Save refresh token for future use
  if [[ -n "$refresh_token" ]]; then
    echo "$token_response" | jq '{refresh_token, access_token, token_type, expires_in}' > "$TOKEN_FILE"
    echo "Token saved to $TOKEN_FILE" >&2
  fi

  echo "$access_token"
}
