#!/bin/bash
set -e

echo "Starting custom entrypoint script for Kiwi TCMS"

# Create the settings directory if it does not exist
mkdir -p /venv/lib64/python3.11/site-packages/tcms_settings_dir/

# Write custom settings file with stronger overrides
echo "Creating custom Django settings"
cat > /venv/lib64/python3.11/site-packages/tcms_settings_dir/custom_settings.py << EOF
# Disable all HTTPS redirection
SECURE_SSL_REDIRECT = False

# Trust HTTPS from proxy
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

# Allow our domain
CSRF_TRUSTED_ORIGINS = ["https://${KIWI_SUBDOMAIN}.${ROOT_DOMAIN}"]

# Disable any additional SSL enforcement
USE_X_FORWARDED_HOST = True
USE_X_FORWARDED_PORT = True
ALLOWED_HOSTS = ["*"]

# Add our own safe cookies
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True

# Debug settings
DEBUG = True
TEMPLATE_DEBUG = True
EOF

# Create dummy certificates for Nginx
mkdir -p /Kiwi/ssl/
if [ ! -f /Kiwi/ssl/localhost.crt ]; then
  echo "Creating dummy self-signed certificate"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /Kiwi/ssl/localhost.key -out /Kiwi/ssl/localhost.crt \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost"
fi

# Create uwsgi_params file
echo "Creating uwsgi_params file"
mkdir -p /Kiwi/etc
cat > /Kiwi/etc/uwsgi_params << EOF
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

# Completely rewrite the Nginx configuration file
if [ -f /Kiwi/etc/nginx.conf ]; then
  echo "Backing up original nginx.conf"
  cp /Kiwi/etc/nginx.conf /Kiwi/etc/nginx.conf.bak
  
  echo "Writing new nginx.conf without SSL"
  cat > /Kiwi/etc/nginx.conf << EOF
worker_processes auto;
pid /tmp/nginx.pid;

# Enable debug logging
error_log /dev/stderr debug;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /dev/stdout;
    error_log /dev/stderr debug;

    # Debugging
    log_format debug_format '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                          '\$status \$body_bytes_sent "\$http_referer" '
                          '"\$http_user_agent"';
    access_log /dev/stdout debug_format;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100M;

    # Enable server status page
    server {
        listen 8081;
        server_name _;
        
        location /nginx_status {
            stub_status on;
            access_log off;
            allow all;
        }
    }

    server {
        listen 8080 default_server;
        server_name _;
        
        # Root directory and index files
        root /Kiwi;
        index index.html;

        # Enable debug logging
        access_log /dev/stdout debug_format;
        error_log /dev/stderr debug;

        # Status check endpoint
        location = /status {
            add_header Content-Type text/plain;
            return 200 "OK";
        }

        # Static files
        location /static/ {
            alias /venv/lib64/python3.11/site-packages/tcms/static/;
        }

        # Media files
        location /uploads/ {
            alias /Kiwi/uploads/;
        }

        # Main application through uWSGI
        location / {
            include /Kiwi/etc/uwsgi_params;
            uwsgi_pass unix:/tmp/kiwitcms.sock;
            uwsgi_read_timeout 86400;
            uwsgi_send_timeout 86400;
            
            # Add debug headers
            add_header X-Debug-Message "Request processed by Nginx" always;
        }
    }
}
EOF
fi

# Print network configuration for debugging
echo "Network configuration:"
ip addr show
echo ""
echo "Listening ports:"
netstat -tulpn || ss -tulpn || echo "Network tools not available"

echo "Launching httpd foreground process"
exec /httpd-foreground