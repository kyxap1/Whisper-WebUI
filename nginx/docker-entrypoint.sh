#!/bin/sh
set -e

CERTS_DIR="/etc/nginx/certs"
ACME_DIR="/var/cache/nginx/acme"
DHPARAM_FILE="${CERTS_DIR}/dhparam.pem"
SELF_SIGNED_CERT="${CERTS_DIR}/selfsigned.crt"
SELF_SIGNED_KEY="${CERTS_DIR}/selfsigned.key"

# Defaults
USE_LETSENCRYPT="${USE_LETSENCRYPT:-false}"
LETSENCRYPT_ENV="${LETSENCRYPT_ENV:-staging}"

# ACME servers
ACME_STAGING="https://acme-staging-v02.api.letsencrypt.org/directory"
ACME_PRODUCTION="https://acme-v02.api.letsencrypt.org/directory"

# Determine server name (DOMAIN > IP > auto-detect > localhost)
if [ -n "$DOMAIN" ]; then
    SERVER_NAME="$DOMAIN"
elif [ -n "$IP" ]; then
    SERVER_NAME="$IP"
else
    # Try to auto-detect public IP
    echo "==> Auto-detecting public IP..."
    PUBLIC_IP=$(curl -sSL --connect-timeout 5 ip.kyxap.pro/csv 2>/dev/null | cut -d',' -f1)
    if [ -n "$PUBLIC_IP" ] && echo "$PUBLIC_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        SERVER_NAME="$PUBLIC_IP"
        echo "    Detected: $SERVER_NAME"
    else
        SERVER_NAME="localhost"
        echo "    Failed to detect, using localhost"
    fi
fi

# Determine ACME server
if [ "$LETSENCRYPT_ENV" = "production" ]; then
    ACME_SERVER="$ACME_PRODUCTION"
else
    ACME_SERVER="$ACME_STAGING"
fi

# Validate ACME_EMAIL if Let's Encrypt is enabled
if [ "$USE_LETSENCRYPT" = "true" ] && [ -z "$ACME_EMAIL" ]; then
    echo "ERROR: ACME_EMAIL is required when USE_LETSENCRYPT=true"
    exit 1
fi

echo "==> Configuration:"
echo "    Server name: $SERVER_NAME"
echo "    Use Let's Encrypt: $USE_LETSENCRYPT"
echo "    Let's Encrypt env: $LETSENCRYPT_ENV"

# Generate DH parameters if not exists
if [ ! -f "$DHPARAM_FILE" ]; then
    echo "==> Generating DH parameters (2048 bit)..."
    openssl dhparam -out "$DHPARAM_FILE" 2048
    echo "==> DH parameters generated"
fi

# Prepare SSL certificate configuration
if [ "$USE_LETSENCRYPT" = "true" ]; then
    echo "==> Using Let's Encrypt certificates"

    # ACME certificate directive
    SSL_CERTIFICATE_CONFIG="acme_certificate letsencrypt ${SERVER_NAME};
        ssl_certificate \$acme_certificate;
        ssl_certificate_key \$acme_certificate_key;"

    OCSP_STAPLING_CONFIG="ssl_stapling on;
    ssl_stapling_verify on;"
else
    echo "==> Using self-signed certificates"
    OCSP_STAPLING_CONFIG=""

    # Generate self-signed certificate if not exists or SERVER_NAME changed
    CERT_CN=""
    if [ -f "$SELF_SIGNED_CERT" ]; then
        CERT_CN=$(openssl x509 -in "$SELF_SIGNED_CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
    fi

    if [ ! -f "$SELF_SIGNED_CERT" ] || [ "$CERT_CN" != "$SERVER_NAME" ]; then
        echo "==> Generating self-signed certificate for $SERVER_NAME..."

        # Build SAN (Subject Alternative Names)
        if [ "$SERVER_NAME" = "localhost" ]; then
            # localhost - include both DNS and IP
            SAN="DNS:localhost,IP:127.0.0.1"
        elif echo "$SERVER_NAME" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            # IP address
            SAN="IP:${SERVER_NAME}"
        else
            # Domain name
            SAN="DNS:${SERVER_NAME}"
        fi

        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SELF_SIGNED_KEY" \
            -out "$SELF_SIGNED_CERT" \
            -subj "/CN=${SERVER_NAME}" \
            -addext "subjectAltName=${SAN}"

        echo "==> Self-signed certificate generated"
    fi

    SSL_CERTIFICATE_CONFIG="ssl_certificate ${SELF_SIGNED_CERT};
        ssl_certificate_key ${SELF_SIGNED_KEY};"

    # Explicitly disable stapling with a comment
    OCSP_STAPLING_CONFIG="# OCSP Stapling disabled"
fi

# Authentication method configuration
AUTH_METHOD="${AUTH_METHOD:-basic}"

if [ "$AUTH_METHOD" = "cognito" ]; then
    echo "==> Using Cognito (oauth2-proxy) authentication"
    AUTH_CONFIG='# OAuth2 authentication via oauth2-proxy
    location /oauth2/ {
        proxy_pass http://oauth2-proxy:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
    }

    location = /oauth2/auth {
        proxy_pass http://oauth2-proxy:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
    }'
    
    LOCATION_AUTH='auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;
        auth_request_set $user   $upstream_http_x_auth_request_user;
        auth_request_set $email  $upstream_http_x_auth_request_email;
        proxy_set_header X-User  $user;
        proxy_set_header X-Email $email;'
else
    echo "==> Using Basic (htpasswd) authentication"
    AUTH_CONFIG=''
    LOCATION_AUTH='auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;'
fi

# Export variables for envsubst
export SERVER_NAME
export ACME_SERVER
export ACME_EMAIL
export SSL_CERTIFICATE_CONFIG
export OCSP_STAPLING_CONFIG
export AUTH_CONFIG
export LOCATION_AUTH

# Generate nginx config from template
echo "==> Generating nginx configuration..."
envsubst '${SERVER_NAME} ${ACME_SERVER} ${ACME_EMAIL} ${SSL_CERTIFICATE_CONFIG} ${OCSP_STAPLING_CONFIG} ${AUTH_CONFIG} ${LOCATION_AUTH}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# Validate nginx config
echo "==> Validating nginx configuration..."
nginx -t

echo "==> Starting nginx..."
exec "$@"
