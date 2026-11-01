package web

import "net/http"

type Route struct {
	Method  string
	Pattern string
}

var baseRoutes = []Route{
	{http.MethodGet, "/"},
	{http.MethodGet, "/api/state"},
	{http.MethodGet, "/api/miner-connection"},
	{http.MethodGet, "/api/xvb-standby"},
	{http.MethodGet, "/metrics"},
	{http.MethodGet, "/api/access"},
	{http.MethodGet, "/ui-preview"},
	{http.MethodGet, "/static/{tail:.*}"},
}

var controlRoutes = []Route{
	{http.MethodGet, "/api/config"},
	{http.MethodPost, "/api/control/preview"},
	{http.MethodPost, "/api/control/commit"},
	{http.MethodPost, "/api/control/upgrade"},
	{http.MethodGet, "/api/control/result"},
	{http.MethodGet, "/api/audit"},
	{http.MethodGet, "/api/worker"},
	{http.MethodPost, "/api/control/worker-apply"},
	{http.MethodPost, "/api/control/worker-upgrade"},
	{http.MethodPost, "/api/control/backup"},
	{http.MethodGet, "/api/control/backup-download"},
	{http.MethodPost, "/api/control/os-update"},
	{http.MethodPost, "/api/control/diag-doctor"},
	{http.MethodPost, "/api/control/diag-logs"},
	{http.MethodPost, "/api/control/onion-client-key"},
}

func Routes(controlEnabled bool) []Route {
	routes := make([]Route, 0, len(baseRoutes)+len(controlRoutes))
	routes = append(routes, baseRoutes...)
	if controlEnabled {
		routes = append(routes, controlRoutes...)
	}
	return routes
}
