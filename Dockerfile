FROM openresty/openresty:alpine

RUN apk add --no-cache curl

# Copy webhook files
COPY webhook.lua /usr/local/openresty/webhook.lua
COPY lua_webhook/ /usr/local/openresty/lualib/lua_webhook/

# Keep the location-only config as a drop-in include, but include it from a server block.
RUN mkdir -p /etc/nginx/conf.d /etc/nginx/includes \
    && rm -f /etc/nginx/conf.d/*.conf

COPY examples/nginx-example.conf /etc/nginx/includes/webhook-location.conf
COPY examples/webhook-env.main /etc/nginx/conf.d/webhook-env.main

# Update path in the included location config
RUN sed -i 's|/path/to/webhook/webhook.lua|/usr/local/openresty/webhook.lua|' \
    /etc/nginx/includes/webhook-location.conf \
    && printf '%s\n' \
      'server {' \
      '    listen 80;' \
      '    server_name localhost;' \
            '' \
            '    # Docker embedded DNS resolver (required for cosocket hostname resolution)' \
            '    resolver 127.0.0.11 ipv6=off valid=30s;' \
      '' \
      '    include /etc/nginx/includes/webhook-location.conf;' \
      '}' \
      > /etc/nginx/conf.d/webhook.conf

EXPOSE 80
