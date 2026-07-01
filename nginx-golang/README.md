## Compose sample application
### NGINX proxy with a Go backend

A minimal two-service web application that demonstrates how to put an NGINX
reverse proxy in front of an HTTP service written in Go, and wire them together
with Docker Compose. When you hit `http://localhost`, NGINX receives the
request, forwards it to the Go service on the internal Compose network, and
returns the Go service's response (the Docker whale ASCII banner and a "Hello
from Docker!" greeting).

This sample is intentionally small so it can be used as a starting point for
your own `nginx + Go` stack.

### What each piece does

- **`proxy` (NGINX)** is the only service exposed to the host. It listens on
  port `80` and proxies every request under `/` to the `backend` service. In a
  real deployment this is where you would add TLS termination, request logging,
  rate limiting, caching, static asset serving, etc.
- **`backend` (Go)** is an HTTP server built with the
  [chi](https://github.com/go-chi/chi) router. It listens on port `80` inside
  its own container and serves a single route (`GET /`) that writes the ASCII
  banner. It is not published to the host, so the only way in is through the
  proxy.

### Architecture

```
                 host:80
                    │
                    ▼
          ┌───────────────────┐
          │      proxy        │   nginx:latest
          │  (nginx.conf)     │   listens on :80
          └─────────┬─────────┘
                    │  proxy_pass http://backend:80
                    ▼
          ┌───────────────────┐
          │     backend       │   built from ./backend
          │   (Go + chi)      │   listens on :80
          └───────────────────┘

              Compose default bridge network
```

`proxy` reaches `backend` by its Compose service name (`backend`), which
Docker's embedded DNS resolves on the project's default network. Only the
`proxy` service publishes a port to the host, so the Go backend is not directly
reachable from outside.

### Project structure

```
.
├── backend
│   ├── Dockerfile        # multi-stage build for the Go service
│   ├── go.mod
│   ├── go.sum
│   └── main.go           # HTTP handler + chi router
├── proxy
│   └── nginx.conf        # single server block, proxy_pass to backend:80
├── compose.yaml
└── README.md
```

### [`compose.yaml`](compose.yaml)

```yaml
services:
  proxy:
    image: nginx
    volumes:
      - type: bind
        source: ./proxy/nginx.conf
        target: /etc/nginx/conf.d/default.conf
        read_only: true
    ports:
      - 80:80
    depends_on:
      - backend

  backend:
    build:
      context: backend
      target: builder
```

A few things worth calling out:

- The proxy's config is mounted read-only from `./proxy/nginx.conf` into
  `/etc/nginx/conf.d/default.conf`, so you can edit the file on the host and
  restart the proxy service without rebuilding an image.
- `depends_on: backend` only waits for the backend container to start, not for
  it to be listening. For a hello-world this is fine; for real services you
  would add a healthcheck.
- The backend service is built from the local `backend/` directory using the
  `builder` stage of its multi-stage Dockerfile.

Make sure port 80 on the host is not already in use.

## Deploy with docker compose

```
$ docker compose up -d
Creating network "nginx-golang_default" with the default driver
Building backend
...
Creating nginx-golang-backend-1 ... done
Creating nginx-golang-proxy-1   ... done
```

## Expected result

Listing containers must show two containers running and the port mapping as
below:

```
$ docker compose ps
NAME                     COMMAND                  SERVICE             STATUS              PORTS
nginx-golang-backend-1   "/code/bin/backend"      backend             running
nginx-golang-proxy-1     "/docker-entrypoint.…"   proxy               running             0.0.0.0:80->80/tcp
```

After the application starts, navigate to `http://localhost:80` in your web
browser or run:

```
$ curl localhost:80

          ##         .
    ## ## ##        ==
 ## ## ## ## ##    ===
/"""""""""""""""""\___/ ===
{                       /  ===-
\______ O           __/
 \    \         __/
  \____\_______/

	
Hello from Docker!
```

You can confirm the request path by tailing the proxy and backend logs in
another shell:

```
$ docker compose logs -f proxy backend
```

You should see NGINX log the inbound request and the Go backend log the
forwarded request that follows it.

Stop and remove the containers:

```
$ docker compose down
```
