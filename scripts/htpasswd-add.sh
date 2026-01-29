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

# Set -c flag if file needs to be created or is empty
CREATE_FLAG=""

if [ ! -f "$HTPASSWD_FILE" ]; then
    touch "$HTPASSWD_FILE"
    CREATE_FLAG="-c"
    echo "Created $HTPASSWD_FILE"
elif [ ! -s "$HTPASSWD_FILE" ]; then
    CREATE_FLAG="-c"
fi

# Mount directory instead of file (htpasswd needs to create temp files)
if [ -n "$PASSWORD" ]; then
    docker run --rm \
        -v "$NGINX_DIR:/auth" \
        httpd:alpine \
        htpasswd -bB ${CREATE_FLAG} /auth/.htpasswd "$USERNAME" "$PASSWORD"
else
    docker run --rm -it \
        -v "$NGINX_DIR:/auth" \
        httpd:alpine \
        htpasswd -B ${CREATE_FLAG} /auth/.htpasswd "$USERNAME"
fi

echo ""
echo "User '$USERNAME' added/updated in $HTPASSWD_FILE"
