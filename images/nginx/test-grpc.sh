#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
# SPDX-License-Identifier: Apache-2.0

# Local image smoke test only: no registry pushes or Kubernetes changes.
set -euo pipefail
image=${1:-karnov/ingress-nginx-controller:v1.15.1-nginx1.30.7}
platform=${PLATFORM:-linux/amd64}
backend_image=ghcr.io/anddd7/grpcbin@sha256:9b8885d2999fd9bb01a90df4984e29575b1b8cc0de30219bd2a839b05bfc1de4
for tool in docker grpcurl jq openssl; do command -v "$tool" >/dev/null; done
work=$(mktemp -d)
name="nginx-grpc-smoke-$$"
cleanup() {
  docker rm -f "${name}-nginx" "${name}-backend" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
chmod 755 "$work"
chmod 644 "$work/tls.key"
cat >"$work/nginx.conf" <<'EOF'
worker_processes 1;
error_log stderr notice;
pid /tmp/nginx-smoke.pid;
events { worker_connections 128; }
http {
  access_log /dev/stdout;
  log_escape_non_ascii off;
  init_by_lua_block { require "resty.core"; require "ngx.ssl"; }
  upstream grpc_backend {
    server backend:50051;
    balancer_by_lua_block {
      local balancer = require "ngx.balancer"
      assert(balancer.set_current_peer("BACKEND_IP", 50051))
    }
  }
  client_body_temp_path /tmp/client_body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  server {
    listen 8443 ssl;
    http2 on;
    ssl_certificate /smoke/tls.crt;
    ssl_certificate_key /smoke/tls.key;
    ssl_certificate_by_lua_block {
      local ssl = require "ngx.ssl"
      assert(ssl.raw_server_addr())
    }
    location / { grpc_pass grpc://grpc_backend; }
  }
}
EOF
docker network create "$name" >/dev/null
docker run -d --platform "$platform" --name "${name}-backend" \
  --network "$name" --network-alias backend "$backend_image" >/dev/null
backend_ip=$(docker inspect "${name}-backend" \
  --format "{{(index .NetworkSettings.Networks \"$name\").IPAddress}}")
sed "s/BACKEND_IP/$backend_ip/g" "$work/nginx.conf" >"$work/nginx.resolved.conf"
mv "$work/nginx.resolved.conf" "$work/nginx.conf"
docker run --rm --platform "$platform" "$image" nginx -v
docker run --rm --platform "$platform" "$image" /nginx-ingress-controller --version
docker run --rm --platform "$platform" --network "$name" \
  -v "$work:/smoke:ro" "$image" nginx -t -e stderr -p /tmp -c /smoke/nginx.conf
# Check dynamic module ABI/load compatibility in separate processes.
for module in ngx_http_auth_digest_module ngx_http_modsecurity_module \
  ngx_http_geoip2_module ngx_stream_geoip2_module ngx_http_brotli_filter_module \
  ngx_http_brotli_static_module ngx_http_js_module ngx_stream_js_module otel_ngx_module; do
  printf 'load_module /etc/nginx/modules/%s.so;\n' "$module" >"$work/module.conf"
  cat "$work/nginx.conf" >>"$work/module.conf"
  docker run --rm --platform "$platform" --network "$name" \
    -v "$work:/smoke:ro" "$image" nginx -t -e stderr -p /tmp -c /smoke/module.conf
done
docker run -d --platform "$platform" --name "${name}-nginx" --network "$name" \
  -p 127.0.0.1::8443 -v "$work:/smoke:ro" "$image" \
  nginx -e stderr -p /tmp -c /smoke/nginx.conf -g 'daemon off;' >/dev/null
endpoint=$(docker port "${name}-nginx" 8443)
ready=false
for attempt in {1..20}; do
  if grpcurl -max-time 2 -insecure "$endpoint" list >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ $ready != true ]]; then docker logs "${name}-nginx"; exit 1; fi
call() { grpcurl -max-time 15 -insecure -d "$1" "$endpoint" "main.GrpcbinService/$2"; }
call '{"data":"unary"}' Unary | jq -e '.result == "unary"'
call '{"data":"stream","count":3}' ServerStreaming | \
  jq -es 'length == 3 and .[0].result == "stream_1 stream" and .[2].result == "stream_3 stream"'
call '{"data":"a"} {"data":"b"}' ClientStreaming | jq -e '.result != null'
call '{"data":"a"} {"data":"b"}' BidirectionalStreaming | jq -es 'length == 2'
# Delay between responses keeps a stream active while the worker reloads.
call '{"data":"reload","count":5,"requestAttributes":{"delay":1}}' ServerStreaming >"$work/reload.json" &
stream_pid=$!
first_response=false
for attempt in {1..10}; do
  if grep -q '"result"' "$work/reload.json"; then first_response=true; break; fi
  sleep 1
done
if [[ $first_response != true ]]; then wait "$stream_pid"; exit 1; fi
docker exec "${name}-nginx" nginx -p /tmp -c /smoke/nginx.conf -e stderr -s reload
wait "$stream_pid"
jq -es 'length == 5 and .[4].result == "stream_5 reload"' "$work/reload.json"
call '{"data":"after-reload"}' Unary | jq -e '.result == "after-reload"'
printf 'PASS: modules, Lua balancer/TLS callback, TLS/HTTP2, unary and streaming gRPC, stream across reload\n'
