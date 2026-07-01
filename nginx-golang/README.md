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

## Deploy to a local Kubernetes cluster with Compose Bridge

You can also convert this Compose project into a set of Kubernetes manifests
and deploy them to a local [Kind](https://kind.sigs.k8s.io/) cluster running
on Docker Desktop, using [Docker Compose Bridge](https://docs.docker.com/compose/bridge/).

Prerequisites: Docker Desktop, `kubectl`, and `kind` installed and on your
`PATH`.

### 1. Build the backend image locally

Compose Bridge references the images that Compose would use, so the backend
image needs to exist on your host before you generate manifests:

```
$ docker compose build
```

This produces a local image tagged `nginx-golang-backend:latest`.

### 2. Generate the Kubernetes manifests

```
$ docker compose bridge convert -o out
```

This writes a kustomize-style tree to `./out/`:

```
out/
├── base/
│   ├── 0-nginx-golang-namespace.yaml
│   ├── backend-deployment.yaml
│   ├── proxy-deployment.yaml
│   ├── proxy-service.yaml          # ClusterIP for the published port
│   ├── proxy-expose.yaml           # cluster-internal service
│   ├── default-network-policy.yaml
│   └── kustomization.yaml
└── overlays/
    └── desktop/                    # patches proxy-service to LoadBalancer;
        ├── kustomization.yaml      # designed for Docker Desktop's built-in
        └── proxy-service.yaml      # Kubernetes, not Kind
```

Everything lands in a `nginx-golang` namespace, and the backend deployment
references the `nginx-golang-backend` image with `imagePullPolicy: IfNotPresent`
so the cluster uses the locally loaded image instead of trying to pull it.

### 3. Create a Kind cluster

```
$ kind create cluster --name nginx-golang
```

### 4. Load the backend image into the Kind node

Kind runs Kubernetes nodes as containers, and those nodes cannot see images
in your host's Docker daemon. Load the built image explicitly:

```
$ kind load docker-image nginx-golang-backend:latest --name nginx-golang
```

The `proxy` service uses the public `nginx` image, which the node pulls from
Docker Hub on its own, so no manual load is needed for it.

### 5. Apply the manifests

Use `base/`, not `overlays/desktop/`: the desktop overlay switches the proxy
service to `type: LoadBalancer`, which stays `Pending` on Kind without an
external load-balancer controller.

```
$ kubectl apply -k out/base
```

Verify the pods come up:

```
$ kubectl -n nginx-golang get pods
NAME                       READY   STATUS    RESTARTS   AGE
backend-xxxxxxxxxx-xxxxx   1/1     Running   0          10s
proxy-xxxxxxxxxx-xxxxx     1/1     Running   0          10s
```

### 6. Access the app

Port-forward the proxy's published service to your host:

```
$ kubectl -n nginx-golang port-forward svc/proxy-published 8080:80
```

Then in another terminal:

```
$ curl localhost:8080
```

You should see the same Docker whale ASCII banner as the Compose deployment.

### 7. Tear down

```
$ kubectl delete -k out/base
$ kind delete cluster --name nginx-golang
```
