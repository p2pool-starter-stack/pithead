package network

const (
	routeTor      = "tor"
	routeClearnet = "clearnet"
	routeIncoming = "incoming"
	routeLocal    = "local"
	routeLAN      = "lan"
	routeUnknown  = "unknown"
	routeInactive = "inactive"
)

type Connection struct {
	To                string `json:"to"`
	Route             string `json:"route"`
	ChosenClearnet    bool   `json:"chosen_clearnet,omitempty"`
	BlockedByFirewall bool   `json:"blocked_by_firewall,omitempty"`
}

type Component struct {
	Name       string       `json:"name"`
	Firewalled *bool        `json:"firewalled,omitempty"`
	Conns      []Connection `json:"conns"`
}

type Summary struct {
	Firewall          bool   `json:"firewall"`
	Leaks             int    `json:"leaks"`
	BlockedByFirewall int    `json:"blocked_by_firewall"`
	Unverified        int    `json:"unverified"`
	AllTor            bool   `json:"all_tor"`
	Level             string `json:"level"`
	Label             string `json:"label"`
}

type Posture struct {
	Components []Component `json:"components"`
	Summary    Summary     `json:"summary"`
}

type policyInput struct {
	Firewall            bool
	P2PoolClearnet      bool
	XVBEnabled          bool
	XVBTor              bool
	MoneroClearnetSync  bool
	TariClearnetSync    bool
	MoneroRoute         string
	TariRoute           string
	TariEnabled         bool
	HealthchecksEnabled bool
	TelegramEnabled     bool
	PriceFeedEnabled    bool
	NotifySinksEnabled  bool
	NotifyTor           bool
	NotifySinksPrivate  bool
	StandbyRoute        string
	TorAutoHeal         bool
	TariExplorer        bool
	LocalMinerEnabled   bool
	StratumLabel        string
}

func boolPointer(value bool) *bool {
	return &value
}

func xvbRoute(enabled, tor bool) string {
	if !enabled {
		return routeInactive
	}
	if tor {
		return routeTor
	}
	return routeClearnet
}

func notifyRoute(enabled, tor, private bool) string {
	if !enabled {
		return routeInactive
	}
	if tor {
		return routeTor
	}
	if private {
		return routeLocal
	}
	return routeClearnet
}

func buildPosture(input policyInput) Posture {
	xvb := xvbRoute(input.XVBEnabled, input.XVBTor)
	sinks := notifyRoute(input.NotifySinksEnabled, input.NotifyTor, input.NotifySinksPrivate)
	moneroConns := []Connection{{To: "Monero P2P / tx relay", Route: routeTor}}
	if input.MoneroRoute != routeLocal {
		moneroConns = []Connection{{To: "remote Monero node (get_info RPC)", Route: input.MoneroRoute}}
	} else if input.MoneroClearnetSync {
		moneroConns = append(moneroConns, Connection{To: "initial block download (clearnet sync)", Route: routeClearnet})
	}
	monero := Component{Name: "monerod", Firewalled: boolPointer(input.MoneroRoute == routeLocal), Conns: moneroConns}

	var tari Component
	if input.TariRoute == routeLocal {
		conns := []Connection{{To: "Tari P2P transport", Route: routeTor}, {To: "DNS resolution", Route: routeLocal}}
		if input.TariClearnetSync {
			conns = append(conns, Connection{To: "initial sync (clearnet)", Route: routeClearnet})
		}
		tari = Component{Name: "tari", Firewalled: boolPointer(true), Conns: conns}
	} else {
		tari = Component{Name: "tari", Conns: []Connection{{To: "remote Tari node (gRPC)", Route: input.TariRoute}}}
	}

	components := []Component{
		monero,
		{Name: "p2pool", Firewalled: boolPointer(true), Conns: []Connection{{To: "sidechain P2P peers", Route: chooseRoute(input.P2PoolClearnet, routeClearnet, routeTor)}, {To: "monerod RPC/ZMQ", Route: input.MoneroRoute}}},
	}
	if input.TariEnabled {
		components = append(components, tari)
	}
	components = append(components,
		Component{Name: "xmrig-proxy", Firewalled: boolPointer(true), Conns: []Connection{{To: "upstream pool (local p2pool stratum)", Route: routeLocal}, {To: "XvB donation pool", Route: xvb}, {To: "dev donation", Route: routeInactive}}},
		Component{Name: "dashboard", Firewalled: boolPointer(false), Conns: dashboardConnections(input, sinks)},
		Component{Name: "caddy", Firewalled: boolPointer(true), Conns: []Connection{{To: "TLS (internal CA, no ACME)", Route: routeLocal}}},
	)

	leaks, chosen, blocked, unverified := classifyConnections(components, input.Firewall)
	return Posture{Components: components, Summary: Summary{
		Firewall: input.Firewall, Leaks: leaks, BlockedByFirewall: blocked, Unverified: unverified,
		AllTor: leaks == 0 && chosen == 0 && unverified == 0,
		Level:  chooseRoute(leaks == 0 && chosen == 0 && unverified == 0, "ok", "warn"),
		Label:  summaryLabel(input, leaks, chosen, blocked, unverified),
	}}
}

func dashboardConnections(input policyInput, sinks string) []Connection {
	connections := []Connection{
		{To: "XvB stats (xmrvsbeast.com)", Route: chooseRoute(input.XVBEnabled, routeTor, routeInactive)},
		{To: "update check (github)", Route: routeTor},
		{To: "Healthchecks.io ping", Route: chooseRoute(input.HealthchecksEnabled, routeTor, routeInactive)},
		{To: "Telegram bot", Route: chooseRoute(input.TelegramEnabled, routeTor, routeInactive)},
		{To: "price feed (coingecko.com)", Route: chooseRoute(input.PriceFeedEnabled, routeTor, routeInactive)},
		{To: "alert sinks (webhook / ntfy)", Route: sinks},
		{To: "XvB standby pull (backup ← primary)", Route: input.StandbyRoute},
		{To: "Tor egress probe", Route: chooseRoute(input.TorAutoHeal, routeTor, routeInactive)},
		{To: "Tari explorer reference", Route: chooseRoute(input.TariExplorer && input.TariEnabled, routeTor, routeInactive)},
	}
	if input.TariEnabled && input.TariRoute != routeLocal {
		connections = append(connections, Connection{To: "remote Tari node (sync gRPC)", Route: input.TariRoute})
	}
	return connections
}

func classifyConnections(components []Component, firewall bool) (int, int, int, int) {
	leaks, chosen, blocked, unverified := 0, 0, 0, 0
	for componentIndex := range components {
		component := &components[componentIndex]
		for connectionIndex := range component.Conns {
			connection := &component.Conns[connectionIndex]
			if connection.Route == routeUnknown {
				unverified++
				continue
			}
			if connection.Route != routeClearnet {
				continue
			}
			if chosenConnection(component.Name, connection.To) {
				connection.ChosenClearnet = true
				chosen++
			} else if component.Firewalled != nil && *component.Firewalled && firewall {
				connection.BlockedByFirewall = true
				blocked++
			} else {
				leaks++
			}
		}
	}
	return leaks, chosen, blocked, unverified
}

func chosenConnection(component, destination string) bool {
	return (component == "monerod" || component == "tari") && contains(destination, "initial") ||
		component == "p2pool" && destination == "sidechain P2P peers" ||
		component == "xmrig-proxy" && destination == "XvB donation pool"
}

func summaryLabel(input policyInput, leaks, chosen, blocked, unverified int) string {
	if leaks > 0 {
		label := plural(leaks, "clearnet egress path(s) exposing your IP")
		if unverified > 0 {
			label += "; " + plural(unverified, "path(s) unverified")
		}
		return label
	}
	if chosen > 0 {
		label := ""
		chains := ""
		if input.MoneroClearnetSync {
			chains = "Monero"
		}
		if input.TariClearnetSync {
			if chains == "" {
				chains = "Tari"
			} else {
				chains += " + Tari"
			}
		}
		if chains != "" {
			label = chains + " clearnet first sync or Tor transition pending by your choice — your IP may be visible to peers until host verification"
		}
		if input.P2PoolClearnet {
			label = appendLabel(label, "P2Pool clearnet by your choice: your IP is visible to peers")
		}
		if input.XVBEnabled && !input.XVBTor {
			label = appendLabel(label, "XvB clearnet by your choice: your IP is visible to the pool")
		}
		return label
	}
	if unverified > 0 {
		return plural(unverified, "egress path(s) unverified; Tor-only status cannot be confirmed")
	}
	if blocked > 0 {
		return "All egress via Tor (" + plural(blocked, "clearnet path(s) blocked by the egress firewall") + ")"
	}
	return "All egress via Tor"
}

func chooseRoute[T any](condition bool, yes, no T) T {
	if condition {
		return yes
	}
	return no
}

func appendLabel(label, addition string) string {
	if label == "" {
		return addition
	}
	return label + "; " + addition
}
