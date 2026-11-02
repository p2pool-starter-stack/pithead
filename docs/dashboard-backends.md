# Dashboard backend selection

Dashboard images built with the `go-production` target include the Go backend and
the Python reference. Python remains the default.

Select Go when applying the stack:

```bash
PITHEAD_DASHBOARD_IMPL=go ./pithead apply
```

Select the Python reference when applying the stack:

```bash
PITHEAD_DASHBOARD_IMPL=python ./pithead apply
```

Export the setting for subsequent Compose operations. It selects the dashboard
independently of the CLI's `PITHEAD_IMPL` setting. Direct container launches use
`PITHEAD_IMPL=go` or `PITHEAD_IMPL=python` inside the container instead.

The Go backend remains a hybrid: Python supplies remaining polling, providers
and callbacks. Keep the Python runtime and locked dependencies in the image.
The Go process retains the loopback bind, Caddy access path, HTTP contracts and
SQLite database location. Existing and corrupt databases use the native SQLite
schema, migration and recovery path under Go selection.

An unknown selector or an unavailable requested Go executable stops startup.
Select Python explicitly to use the reference. Switching back does not require
a database conversion.

Build the Go-capable development image from the repository root:

```bash
docker build --target go-production --build-context pithead-go=go \
  -t pithead-dashboard:dev dashboard
```

Plain `docker build dashboard` retains the reference-only production target;
`docker build --target test dashboard` retains the original Python test stage.
Compose, release builds and appliance builds select the Go-capable target.
Release bundles and appliance roots also include both native commands under
`go/bin/`, beside the generated Bash CLI. Bash remains the CLI default.
