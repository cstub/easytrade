# The -otel variant of the same nginx version ships ngx_otel_module (OTLP/gRPC traces only).
FROM nginx:1.29.0-alpine3.22-otel@sha256:8df5f99417893742f475f37513c29692b9e630d66d87fb3ad4e12bdbbd6137a2

RUN rm /etc/nginx/conf.d/default.conf \
    && sed -i '1i load_module modules/ngx_otel_module.so;' /etc/nginx/nginx.conf

# Turns the OTEL_* environment variables into ngx_otel_module settings at startup.
COPY --chmod=755 otel.sh /docker-entrypoint.d/25-otel.sh

COPY nginx.conf /etc/nginx/templates/nginx.conf.template

EXPOSE 80

# Set default values for environment variables
ENV LOGIN_SERVICE_URL=http://loginservice:8080 \
    BROKER_SERVICE_URL=http://broker-service:8080 \
    ACCOUNT_SERVICE_URL=http://accountservice:8080 \
    PRICING_SERVICE_URL=http://pricing-service:8080 \
    OFFER_SERVICE_URL=http://offerservice:8080 \
    ENGINE_URL=http://engine:8080 \
    MANAGER_URL=http://manager:8080 \
    CREDIT_CARD_ORDER_SERVICE_URL=http://credit-card-order-service:8080 \
    THIRD_PARTY_SERVICE_URL=http://third-party-service:8080 \
    FEATURE_FLAG_SERVICE_URL=http://feature-flag-service:8080 \
    FRONTEND_URL=http://frontend:3000/ \
    FRONTEND_REVERSE_PROXY_PORT=80 \
    OTEL_SERVICE_NAME=frontendreverseproxy \
    OTEL_EXPORTER_OTLP_ENDPOINT=localhost:4317

CMD ["nginx", "-g", "daemon off;"]
