#!/bin/bash
set -e

echo "Starting custom entrypoint script for Kiwi TCMS"

# Create the settings directory if it does not exist
mkdir -p /venv/lib64/python3.11/site-packages/tcms_settings_dir/

# Write custom settings file with stronger overrides
echo "Creating custom Django settings with os.environ approach"
cat >/venv/lib64/python3.11/site-packages/tcms_settings_dir/custom_settings.py <<EOF
import os

# Disable all HTTPS redirection
SECURE_SSL_REDIRECT = False

# Trust HTTPS from proxy
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

# Get domain values from environment
KIWI_SUBDOMAIN = os.environ.get('KIWI_SUBDOMAIN', 'test')
ROOT_DOMAIN = os.environ.get('ROOT_DOMAIN', 'example.com')
FULL_DOMAIN = f"{KIWI_SUBDOMAIN}.{ROOT_DOMAIN}"

# Critical: Fix CSRF settings with proper environment variables
CSRF_TRUSTED_ORIGINS = [
    f"https://{FULL_DOMAIN}",
    f"http://{FULL_DOMAIN}",
    "https://test.nursegpt.ca",
    "http://test.nursegpt.ca",
    f"https://*.{ROOT_DOMAIN}",
]

# CSRF Verification settings
CSRF_COOKIE_DOMAIN = None
CSRF_USE_SESSIONS = False
CSRF_COOKIE_HTTPONLY = False
CSRF_COOKIE_SECURE = False
CSRF_COOKIE_SAMESITE = 'Lax'

# Disable any additional SSL enforcement
USE_X_FORWARDED_HOST = True
USE_X_FORWARDED_PORT = True
ALLOWED_HOSTS = ["*"]

# Add our own safe cookies - set to False to work with HTTP
SESSION_COOKIE_SECURE = False

# Improved static files configuration
STATIC_URL = '/static/'
STATIC_ROOT = '/Kiwi/static/'
STATICFILES_DIRS = [
    '/venv/lib64/python3.11/site-packages/tcms/static/',
]

# Make sure Django can locate static files
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
]

# Media files
MEDIA_URL = '/uploads/'
MEDIA_ROOT = '/Kiwi/uploads/'

# Debug settings
DEBUG = True
TEMPLATE_DEBUG = True

# Print debugging info for CSRF issues
print("FULL_DOMAIN:", FULL_DOMAIN)
print("CSRF_TRUSTED_ORIGINS:", CSRF_TRUSTED_ORIGINS)
print("STATIC_URL:", STATIC_URL)
print("STATIC_ROOT:", STATIC_ROOT)
EOF

# Create uwsgi_params file
echo "Creating uwsgi_params file"
mkdir -p /Kiwi/etc
cat >/Kiwi/etc/uwsgi_params <<EOF
uwsgi_param QUERY_STRING \$query_string;
uwsgi_param REQUEST_METHOD \$request_method;
uwsgi_param CONTENT_TYPE \$content_type;
uwsgi_param CONTENT_LENGTH \$content_length;
uwsgi_param REQUEST_URI \$request_uri;
uwsgi_param PATH_INFO \$document_uri;
uwsgi_param DOCUMENT_ROOT \$document_root;
uwsgi_param SERVER_PROTOCOL \$server_protocol;
uwsgi_param REMOTE_ADDR \$remote_addr;
uwsgi_param REMOTE_PORT \$remote_port;
uwsgi_param SERVER_ADDR \$server_addr;
uwsgi_param SERVER_PORT \$server_port;
uwsgi_param SERVER_NAME \$server_name;
EOF

# Create a custom uwsgi.ini file with proper logging configuration
echo "Creating custom uwsgi.ini"
cat >/Kiwi/etc/uwsgi.ini <<EOF
[uwsgi]
# Application integration
chdir = /venv/lib64/python3.11/site-packages/tcms
module = tcms.wsgi:application
env = DJANGO_SETTINGS_MODULE=tcms.settings.product

# Process configuration
master = true
processes = 4
threads = 2

# Socket configuration - use HTTP protocol on port 8080
http-socket = :8080

# Static file serving
static-map = /static=/Kiwi/static
check-static = /Kiwi/static
static-map = /static=/venv/lib64/python3.11/site-packages/tcms/static
check-static = /venv/lib64/python3.11/site-packages/tcms/static

# Media files
static-map = /uploads=/Kiwi/uploads
check-static = /Kiwi/uploads

# Logging configuration - fix log rotation issues
disable-logging = false
log-master = true
log-reopen = true
logger = stdio

# Performance settings
harakiri = 120
max-requests = 5000

# Header forwarding
route-host = .* addheader:X-Forwarded-Proto: https
route-host = .* addheader:X-Forwarded-Port: 443
route-host = .* addheader:X-Forwarded-Host: ${KIWI_SITE_DOMAIN}
EOF

# Create static directory
echo "Creating static directory"
mkdir -p /Kiwi/static
mkdir -p /venv/lib64/python3.11/site-packages/tcms/static

# Collect static files if static directory doesn't have content
if [ -z "$(ls -A /Kiwi/static 2>/dev/null)" ]; then
    echo "Static directory is empty, collecting static files..."
    cd /venv/lib64/python3.11/site-packages/tcms
    python /Kiwi/manage.py collectstatic --noinput || true
fi

# Skip Nginx configuration entirely
echo "Skipping Nginx configuration as it's disabled"

# Collect static files more reliably
echo "Running collectstatic forcefully to ensure all static files are available..."
cd /venv/lib64/python3.11/site-packages/tcms
python /Kiwi/manage.py collectstatic --noinput --clear || echo "Error running collectstatic, continuing anyway"

# Check and create static directories if needed
echo "Checking static file directories..."
mkdir -p /Kiwi/static
mkdir -p /venv/lib64/python3.11/site-packages/tcms/static

# Copy static files as a failsafe method
echo "Copying static files as a backup method..."
cp -r /venv/lib64/python3.11/site-packages/tcms/static/* /Kiwi/static/ || echo "Could not copy static files, but continuing anyway"

# List the static files for debugging
echo "Static files in Kiwi static directory:"
ls -la /Kiwi/static/ || echo "No files found"

# Start uWSGI in foreground
echo "Starting uWSGI server directly on port 8080..."
cd /venv/lib64/python3.11/site-packages/tcms
exec uwsgi --ini /Kiwi/etc/uwsgi.ini
