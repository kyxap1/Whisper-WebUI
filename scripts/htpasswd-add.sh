#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NGINX_DIR="$(cd "$SCRIPT_DIR/../nginx" && pwd)"
HTPASSWD_FILE="$NGINX_DIR/.htpasswd"

usage() {
    echo "Usage: $0 <username> [password]"
    echo ""
    echo "Add or update a user in .htpasswd file using Docker"
    echo ""
    echo "Arguments:"
    echo "  username    Username to add"
    echo "  password    Password (optional, will prompt if not provided)"
    echo ""
    echo "Examples:"
    echo "  $0 admin                  # Will prompt for password"
    echo "  $0 admin mysecretpass     # Set password directly"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

USERNAME="$1"
PASSWORD="$2"

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found."
    echo "This script requires Docker to run the htpasswd utility."
    exit 1
fi

# Generate hash and write to file (no mounting needed)
if [ -n "$PASSWORD" ]; then
    HASH=$(docker run --rm httpd:alpine htpasswd -nbB "$USERNAME" "$PASSWORD")
else
    echo "Enter password for $USERNAME:"
    read -s PASSWORD
    echo "Re-type password:"
    read -s PASSWORD2
    if [ "$PASSWORD" != "$PASSWORD2" ]; then
        echo "Passwords don't match"
        exit 1
    fi
    HASH=$(docker run --rm httpd:alpine htpasswd -nbB "$USERNAME" "$PASSWORD")
fi

# Remove existing entry for this user (if any)
if [ -f "$HTPASSWD_FILE" ]; then
    grep -v "^${USERNAME}:" "$HTPASSWD_FILE" > "$HTPASSWD_FILE.tmp" || true
    mv "$HTPASSWD_FILE.tmp" "$HTPASSWD_FILE"
fi

# Append new entry
echo "$HASH" >> "$HTPASSWD_FILE"

echo "User '$USERNAME' added/updated in $HTPASSWD_FILE"
