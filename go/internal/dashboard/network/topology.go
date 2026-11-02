package network

type Edge struct {
	From              string `json:"from"`
	To                string `json:"to"`
	Route             string `json:"route"`
	Label             string `json:"label"`
	Kind              string `json:"kind"`
	ChosenClearnet    bool   `json:"chosen_clearnet,omitempty"`
	BlockedByFirewall bool   `json:"blocked_by_firewall,omitempty"`
	Leak              bool   `json:"leak,omitempty"`
}

type Node struct {
	ID   string `json:"id"`
	Zone string `json:"zone"`
}

type NodeRelocation struct {
	Index  int    `json:"index"`
	Zone   string `json:"zone"`
	Remote bool   `json:"remote"`
	Route  string `json:"route"`
}

type NodePlan struct {
	Indices     []int            `json:"indices"`
	Relocatable []NodeRelocation `json:"relocatable"`
}

func buildEdges(input policyInput) []Edge {
	xvb := xvbRoute(input.XVBEnabled, input.XVBTor)
	sinks := notifyRoute(input.NotifySinksEnabled, input.NotifyTor, input.NotifySinksPrivate)
	sidechain := chooseRoute(input.P2PoolClearnet, routeClearnet, routeTor)
	moneroKind := chooseRoute(input.MoneroRoute == routeLocal, "internal", "egress")
	tariKind := chooseRoute(input.TariRoute == routeLocal, "internal", "egress")
	edges := []Edge{
		edge("rigs", "xmrig-proxy", routeIncoming, input.StratumLabel, "ingress"),
		edge("browser", "caddy", routeIncoming, "https :443", "ingress"),
		edge("p2pool", externalNode(sidechain), sidechain, "sidechain P2P", "p2p"),
	}
	if input.MoneroRoute == routeLocal {
		edges = append(edges, edge("monerod", "tor", routeTor, "Monero P2P + tx", "p2p"))
	}
	if input.TariEnabled && input.TariRoute == routeLocal {
		edges = append(edges, edge("tari", "tor", routeTor, "Tari P2P", "p2p"))
	}
	edges = append(edges,
		edge("xmrig-proxy", externalNode(xvb), xvb, "XvB donation", "egress"),
		edge("dashboard", "tor", routeTor, "update check", "egress"),
		edge("dashboard", "tor", chooseRoute(input.XVBEnabled, routeTor, routeInactive), "XvB stats", "egress"),
		edge("dashboard", "tor", chooseRoute(input.TorAutoHeal, routeTor, routeInactive), "Tor egress probe", "egress"),
		edge("dashboard", "tor", chooseRoute(input.TariExplorer && input.TariEnabled, routeTor, routeInactive), "Tari explorer reference", "egress"),
		edge("dashboard", "tor", chooseRoute(input.HealthchecksEnabled, routeTor, routeInactive), "Healthchecks ping", "egress"),
		edge("dashboard", "tor", chooseRoute(input.TelegramEnabled, routeTor, routeInactive), "Telegram bot", "egress"),
		edge("dashboard", "tor", chooseRoute(input.PriceFeedEnabled, routeTor, routeInactive), "price feed", "egress"),
	)
	if sinks != routeLocal {
		edges = append(edges, edge("dashboard", externalNode(sinks), sinks, "alert sinks", "egress"))
	}
	if input.StandbyRoute != routeLocal {
		edges = append(edges, edge("dashboard", externalNode(input.StandbyRoute), input.StandbyRoute, "XvB standby", "egress"))
	}
	edges = append(edges,
		edge("tor", "internet", routeTor, "SOCKS + onion circuits", "p2p"),
		edge("xmrig-proxy", "p2pool", routeLocal, "upstream pool", "internal"),
		edge("p2pool", "monerod", input.MoneroRoute, "RPC / ZMQ", moneroKind),
	)
	if input.TariEnabled {
		edges = append(edges, edge("p2pool", "tari", input.TariRoute, "gRPC merge-mine", tariKind))
	}
	edges = append(edges,
		edge("caddy", "dashboard", routeLocal, "reverse-proxy :8000", "internal"),
		edge("dashboard", "monerod", input.MoneroRoute, "get_info RPC", moneroKind),
		edge("dashboard", "xmrig-proxy", routeLocal, "proxy API", "internal"),
	)
	if input.TariEnabled {
		edges = append(edges, edge("dashboard", "tari", input.TariRoute, "gRPC", tariKind))
	}
	edges = append(edges, edge("dashboard", "docker", routeLocal, "container API", "internal"))
	if input.LocalMinerEnabled {
		edges = append(edges, edge("local-miner", "xmrig-proxy", routeLocal, "local stratum", "ingress"))
	}
	if input.MoneroClearnetSync && input.MoneroRoute == routeLocal {
		edges = append(edges, edge("monerod", "internet", routeClearnet, "clearnet IBD", "egress"))
	}
	if input.TariEnabled && input.TariClearnetSync && input.TariRoute == routeLocal {
		edges = append(edges, edge("tari", "internet", routeClearnet, "clearnet IBD", "egress"))
	}
	classifyEdges(edges, input.Firewall)
	return edges
}

func edge(from, to, route, label, kind string) Edge {
	return Edge{From: from, To: to, Route: route, Label: label, Kind: kind}
}

func externalNode(route string) string {
	if route == routeClearnet {
		return "internet"
	}
	return "tor"
}

func classifyEdges(edges []Edge, firewall bool) {
	for index := range edges {
		link := &edges[index]
		if link.Route != routeClearnet {
			continue
		}
		if (link.From == "monerod" || link.From == "tari") && link.Label == "clearnet IBD" ||
			link.From == "p2pool" && link.Label == "sidechain P2P" ||
			link.From == "xmrig-proxy" && link.Label == "XvB donation" {
			link.ChosenClearnet = true
		} else if link.From != "dashboard" && firewall {
			link.BlockedByFirewall = true
		} else {
			link.Leak = true
		}
	}
}

func buildNodePlan(nodes []Node, moneroRoute, tariRoute string, tariEnabled, localMinerEnabled bool) NodePlan {
	plan := NodePlan{Indices: []int{}, Relocatable: []NodeRelocation{}}
	for index, node := range nodes {
		if !localMinerEnabled && node.ID == "local-miner" || !tariEnabled && node.ID == "tari" {
			continue
		}
		plan.Indices = append(plan.Indices, index)
		route := ""
		switch node.ID {
		case "monerod":
			route = moneroRoute
		case "tari":
			route = tariRoute
		}
		if route == "" {
			continue
		}
		remote := route != routeLocal
		zone := node.Zone
		if remote {
			zone = "remote"
		}
		plan.Relocatable = append(plan.Relocatable, NodeRelocation{Index: index, Zone: zone, Remote: remote, Route: route})
	}
	return plan
}
