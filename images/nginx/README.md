NGINX base image

### Build the patched controller locally

This fork builds NGINX 1.30.7 to address CVE-2026-123007, CVE-2026-123634,
CVE-2026-123633, CVE-2026-121810, and CVE-2026-113425 without disabling HTTP/2.
The `CVE-2025-23419` backport for NGINX 1.27.1 is no longer needed: the fix
is already in the upstream NGINX source. Build the base image and controller
for the same architecture so the binary, modules, and libraries stay matched.

From the repository root, on a machine with Docker and the Go version in
`go.mod`. Pass the custom `BASE_IMAGE` explicitly: the default `NGINX_BASE`
still points to the upstream registry image.

```sh
base=karnov/ingress-nginx-base:1.30.7
version=v1.15.1-nginx1.30.7
revision=$(git rev-parse --short HEAD)
docker build --platform linux/amd64 -t "$base" images/nginx/rootfs
GOOS=linux ARCH=amd64 PKG=k8s.io/ingress-nginx COMMIT_SHA="$revision" \
  REPO_INFO=https://github.com/karnov/ingress-nginx TAG="$version" \
  bash build/build.sh
docker build --platform linux/amd64 --build-arg BASE_IMAGE="$base" \
  --build-arg VERSION="$version" --build-arg TARGETARCH=amd64 \
  --build-arg COMMIT_SHA="$revision" \
  -t "karnov/ingress-nginx-controller:$version" rootfs
docker run --rm --platform linux/amd64 \
  "karnov/ingress-nginx-controller:$version" nginx -v
```

These commands build local images only. Run the local smoke test with Docker,
`grpcurl`, `jq`, and OpenSSL installed:

```sh
bash images/nginx/test-grpc.sh "karnov/ingress-nginx-controller:$version"
```

It checks the NGINX configuration and dynamic-module loading, Lua-based upstream
balancing and the Lua TLS certificate callback, TLS/HTTP2, unary,
server/client/bidirectional streaming gRPC, and an active stream across a reload.
It creates isolated local containers, a network, and a temporary self-signed
certificate, then cleans them up automatically. It does not contact Kubernetes.
Before deploying, also validate the real rendered controller configuration and
production routing/annotations in staging.

### HTTP/3 Support

**HTTP/3 support is experimental and under development**

[HTTP/3](https://datatracker.ietf.org/doc/html/rfc9114)\
[QUIC](https://datatracker.ietf.org/doc/html/rfc9000)

[According to the documentation, NGINX 1.25.0 or higher supports HTTP/3:](https://nginx.org/en/docs/quic.html)

> Support for QUIC and HTTP/3 protocols is available since 1.25.0.

But this requires adding a new flag during the build:

> When configuring nginx, it is possible to enable QUIC and HTTP/3 using the --with-http_v3_module configuration parameter.

[We have added this flag](https://github.com/kubernetes/ingress-nginx/pull/11470), but it is not enough to use HTTP/3 in ingress-nginx, this is the first step.

The next steps will be:

1. **Waiting for OpenSSL 3.4.**\
    The main problem is, that we still use OpenSSL (3.x) and it does not support the important mechanism of TLS 1.3 - [early_data](https://datatracker.ietf.org/doc/html/rfc8446#section-2.3):

    > Otherwise, the OpenSSL compatibility layer will be used that does not support early data.
    
    [And although another part of the documentation says that the directive is supported with OpenSSL:](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_early_data)

    > The directive is supported when using OpenSSL 1.1.1 or higher.
    
    But this is incomplete support, because OpenSSL does not support this feature, and [it has only client side support:](https://github.com/openssl/openssl)

    > ... the QUIC (currently client side only) version 1 protocol
   
    [And also there are some issues even with client side](https://github.com/openssl/openssl/discussions/23339)

    Due to this, we currently have incomplete HTTP/3 support, without important security and performance features.\
    But the good news is that [OpenSSL plans to add server-side support in 3.4](https://github.com/openssl/web/blob/master/roadmap.md):

    > Server-side QUIC support
    
    [Overview of SSL libraries(HAProxy Documentation)](https://github.com/haproxy/wiki/wiki/SSL-Libraries-Support-Status#tldr)  

2. **Adding [parameters](https://nginx.org/en/docs/http/ngx_http_v3_module.html) to the configmap to configure HTTP/3 and quic(enableHTTP3, enableHTTP/0.9, maxCurrentStream, and so on).**
3. **Adding options to the nginx config template(`listen 443 quic` to server blocks and `add_header Alt-Svc 'h3=":8443"; ma=86400';` to location blocks).**
4. **Opening the https port for UDP in the container(because QUIC uses UDP).**
5. **Adding tests.**
