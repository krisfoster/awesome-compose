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

## Deploy to Docker Desktop's Kubernetes cluster with Compose Bridge

You can convert this Compose project into a set of Kubernetes manifests and
deploy them to the Kubernetes cluster built into Docker Desktop, using
[Docker Compose Bridge](https://docs.docker.com/compose/bridge/). Docker
Desktop runs its Kubernetes cluster as a [Kind](https://kind.sigs.k8s.io/)
cluster under the hood (visible as `Mode: kind` in `docker desktop kubernetes
status`), so the standard `kind` CLI works against it directly and there is no
separate cluster to create.

Prerequisites: Docker Desktop, `kubectl`, and the `kind` CLI on your `PATH`
(needed only for image loading in step 4).

### 1. Enable Kubernetes in Docker Desktop

Kubernetes has to be enabled once from the Docker Desktop UI:
**Settings → Kubernetes → Enable Kubernetes → Apply & restart**. Docker
Desktop doesn't currently expose an `enable` CLI flag for the Kubernetes
feature, but once it's on you can drive it entirely from the command line.

Verify:

```
$ docker desktop kubernetes status
Field               Value
State:              running
Mode:               kind
Version:            1.33.12
Progress Message:   Kubernetes is up and running
```

Point kubectl at Docker Desktop's context:

```
$ kubectl config use-context docker-desktop
```

### 2. Build the backend image

Compose Bridge references the images that Compose would use, so the backend
image needs to exist on your host first:

```
$ docker compose build
```

This produces a local image tagged `nginx-golang-backend:latest`.

### 3. Generate the Kubernetes manifests

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
    └── desktop/                    # patches proxy-service to LoadBalancer,
        ├── kustomization.yaml      # which Docker Desktop binds to localhost
        └── proxy-service.yaml
```

Everything lands in a `nginx-golang` namespace, and the backend deployment
references the `nginx-golang-backend` image with `imagePullPolicy: IfNotPresent`
so the cluster uses the locally loaded image instead of trying to pull it.

### 4. Load the backend image into Docker Desktop's Kubernetes node

Docker Desktop's Kubernetes nodes are Kind nodes, which do not automatically
see images in your host's Docker daemon. Docker Desktop names its cluster
`kind`, so load the image against that name:

```
$ kind load docker-image nginx-golang-backend:latest --name kind
```

The `proxy` service uses the public `nginx` image, which the node pulls from
Docker Hub on its own, so no manual load is needed for it.

### 5. Apply the manifests

Use the `desktop` overlay. It patches the proxy service to
`type: LoadBalancer`, which Docker Desktop transparently binds to `localhost`:

```
$ kubectl apply -k out/overlays/desktop
```

Verify the pods and services come up:

```
$ kubectl -n nginx-golang get pods,svc
```

### 6. Access the app

Because the proxy service is a `LoadBalancer` on Docker Desktop, the app is
reachable directly on `localhost:80`:

```
$ curl localhost:80
```

You should see the same Docker whale ASCII banner as the Compose deployment.
If port 80 is already in use on your host, `kubectl port-forward` still works
as a fallback:

```
$ kubectl -n nginx-golang port-forward svc/proxy-published 8080:80
```

### 7. Tear down

Remove the app:

```
$ kubectl delete -k out/overlays/desktop
```

To wipe the whole Kubernetes cluster and start fresh (kept containers, volumes,
and manifests are unaffected):

```
$ docker desktop kubernetes reset-cluster
```

## Develop this sample in an isolated sandbox

If you want to poke at the code (or turn an AI agent loose on it) without
letting anything touch your host, this repo ships a
[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit that spins up a
microVM, brings up the devcontainer inside it, and exposes a
[VS Code tunnel](https://code.visualstudio.com/docs/remote/tunnels) URL you can
open in a browser or attach VS Code Desktop to.

**The sandbox uses the Claude base template** (`docker.io/library/acp-claude:latest`),
which includes Claude Code pre-installed and running in unsafe mode. This provides
full AI-assisted development capabilities within the isolated sandbox environment.

Nesting when the sandbox is up:

```
host  ->  sbx microVM (Claude base)  ->  devcontainer (Debian + Go + DinD)  ->  `code tunnel`
                  └-> Claude Code (unsafe mode)                            \-> `docker compose up`
```

The full recipe lives in [`.sbx/spec.yaml`](.sbx/spec.yaml) (the sandbox kit)
and [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json) (what
the devcontainer looks like once it's inside).

Prerequisites: Docker Desktop with Docker Sandboxes enabled and the `sbx` CLI
on your `PATH`. See the [get-started guide](https://docs.docker.com/ai/sandboxes/get-started/).

### Bring it up

```
$ ./scripts/sandbox-up.sh
```

The script creates a sandbox named `nginx-golang`, loads the kit, and waits for
the tunnel URL. First run only, `code tunnel` prints a GitHub device-code prompt
into the tunnel log; tail it to complete auth:

```
$ sbx exec nginx-golang -- docker exec <devcontainer-id> cat /tmp/tunnel.log
```

Once authenticated, the log contains a `https://vscode.dev/tunnel/...` URL. The
auth token is persisted in a named volume, so subsequent starts skip the prompt.

### Work inside the sandbox

Open the tunnel URL. You get full VS Code, running inside the devcontainer,
running inside the sandbox. In a terminal:

```
$ docker compose up
```

VS Code's port panel picks up the forwarded proxy port and offers a browser
preview. Editing Go code triggers gopls in the container; nothing on your host
is touched.

### Using Claude Code in the sandbox

The sandbox base layer includes Claude Code running in unsafe mode, providing
AI-assisted development. You can access Claude Code directly from within the
sandbox:

```
$ sbx exec nginx-golang -- claude
```

Or interact with it programmatically. Since it's running in unsafe mode, Claude
has full access to the development environment and can:

- Read and edit files
- Run commands and tests
- Install packages and dependencies
- Work with Git operations
- Execute Docker commands

This provides a complete AI-powered development environment while maintaining
isolation from your host system.

### Tear it down

```
$ sbx rm --force nginx-golang
```

### Notes

- The devcontainer is DinD-based, so the sample runs three layers deep (host
  Docker &rarr; sandbox Docker &rarr; devcontainer's inner Docker). Fine for a
  small sample, worth knowing if you push it hard.
- The sandbox kit uses `schemaVersion: "2"`. Kit format is
  [experimental](https://docs.docker.com/ai/sandboxes/customize/) and may
  change; the shell script is the source of truth for what the kit does.
- Egress from the sandbox goes through Docker's HTTP proxy and is restricted to
  the domains declared in `caps.network.allow`. If a devcontainer feature you
  add needs a new host, add it there.
