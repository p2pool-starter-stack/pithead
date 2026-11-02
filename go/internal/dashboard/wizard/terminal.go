package wizard

import (
	"fmt"
	"os"
	"path/filepath"
)

type TerminalRequest struct {
	Operation     string  `json:"operation"`
	Authenticated bool    `json:"authenticated"`
	Spool         *string `json:"spool,omitempty"`
	Handoff       string  `json:"handoff,omitempty"`
	Stage         any     `json:"stage,omitempty"`
}

type TerminalResult struct {
	Status    int               `json:"status"`
	Body      any               `json:"body,omitempty"`
	Raw       *string           `json:"raw,omitempty"`
	Redirect  string            `json:"redirect,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	NeedSpool bool              `json:"need_spool,omitempty"`
}

func HandleTerminal(request TerminalRequest) (TerminalResult, error) {
	return handleTerminal(request, systemTransactionIO{})
}

func handleTerminal(request TerminalRequest, io transactionIO) (TerminalResult, error) {
	switch request.Operation {
	case "handoff":
		if !request.Authenticated {
			return terminalJSON(401, "unauthenticated"), nil
		}
		raw, err := (View{Spool: terminalSpool(request.Spool), Handoff: request.Handoff}).Read("handoff.json", request.Handoff)
		if err != nil {
			return TerminalResult{}, err
		}
		if raw == nil || *raw == "" {
			return terminalJSON(404, "not ready"), nil
		}
		return TerminalResult{
			Status:  200,
			Raw:     raw,
			Headers: map[string]string{"Cache-Control": "no-store"},
		}, nil
	case "ack":
		if !request.Authenticated {
			return TerminalResult{Status: 302, Redirect: "/"}, nil
		}
		spool := terminalSpool(request.Spool)
		raw, err := (View{Spool: spool, Handoff: request.Handoff}).Read("handoff.json", request.Handoff)
		if err != nil {
			return TerminalResult{}, err
		}
		if raw == nil {
			return terminalJSON(400, "nothing to acknowledge"), nil
		}
		if err := (Txn{Spool: spool, IO: io}).Write("handoff-ack", []byte("1"), ""); err != nil {
			return TerminalResult{}, err
		}
		return terminalStatus("provisioning"), nil
	case "keep":
		if !request.Authenticated {
			return TerminalResult{Status: 302, Redirect: "/"}, nil
		}
		spool := terminalSpool(request.Spool)
		role, err := (View{Spool: spool}).SavedRole()
		if err != nil {
			return TerminalResult{}, err
		}
		if string(role) == "null" {
			return terminalJSON(400, "nothing to keep"), nil
		}
		if err := (Txn{Spool: spool, IO: io}).Write("keep-role", []byte("1"), ""); err != nil {
			return TerminalResult{}, err
		}
		return terminalStatus("kept"), nil
	case "retry":
		if !request.Authenticated {
			return TerminalResult{Status: 302, Redirect: "/"}, nil
		}
		stage, ok := request.Stage.(string)
		if !ok || stage != "failed" {
			return terminalJSON(409, "no failed install to reopen"), nil
		}
		if request.Spool == nil {
			return TerminalResult{NeedSpool: true}, nil
		}
		for _, name := range []string{"error.txt", "installing", "setup-failed"} {
			path := filepath.Join(*request.Spool, name)
			if _, err := os.Stat(path); err != nil {
				continue
			}
			if err := io.Unlink(path); err != nil {
				return TerminalResult{}, err
			}
		}
		return terminalStatus("settings"), nil
	default:
		return TerminalResult{}, ValidationError{fmt.Sprintf("unsupported wizard terminal operation: %s", request.Operation)}
	}
}

func terminalSpool(spool *string) string {
	if spool == nil {
		return ""
	}
	return *spool
}

func terminalJSON(status int, message string) TerminalResult {
	return TerminalResult{Status: status, Body: map[string]string{"error": message}}
}

func terminalStatus(status string) TerminalResult {
	return TerminalResult{Status: 200, Body: map[string]string{"status": status}}
}
