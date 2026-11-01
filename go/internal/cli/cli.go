package cli

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/p2pool-starter-stack/pithead/go/internal/doctor"
	"github.com/p2pool-starter-stack/pithead/go/internal/status"
)

const commands = "setup apply render up down restart tor-recover upgrade logs status test-alert doctor support-bundle reset-dashboard config-reset factory-reset backup restore uninstall firstboot-wizard load-images local-miner os-update control-run-pending egress-run-pending egress-status lan-guard-check onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"

func Run(reference string, args []string, stdout io.Writer) error {
	switch os.Getenv("PITHEAD_GO_HELPER") {
	case "config-payout-ownership":
		return configPayoutOwnership(args, os.Stdin, stdout)
	case "config-compose-project":
		return configComposeProject(args, os.Stdin, stdout)
	case "config-env-read":
		return configEnvRead(args, os.Stdin, stdout)
	case "config-payout-keys":
		return configPayoutKeys(args, os.Stdin, stdout)
	case "config-preview":
		return configPreview(args, os.Stdin, stdout)
	case "config-worker-read":
		return configWorkerRead(args, os.Stdin, stdout)
	case "config-masked":
		return configMasked(args, os.Stdin, stdout)
	case "config-access-settings":
		return configAccessSettings(args, os.Stdin, stdout)
	case "config-version":
		return configVersion(args, os.Stdin, stdout)
	case "config-migrations":
		return configMigrations(args, os.Stdin, stdout)
	case "config-persistence":
		return configPersistence(args, os.Stdin, stdout)
	case "config-document":
		return configDocument(args, stdout)
	case "config-defaults":
		return configDefaults(args, os.Stdin, stdout)
	case "config-validation":
		return configValidation(args, stdout)
	case "config-stratum":
		return configStratum(args, stdout)
	case "config-network-settings":
		return configNetworkSettings(args, stdout)
	case "config-site-names":
		return configSiteNames(args, os.Stdin, stdout)
	case "config-proxy-settings":
		return configProxySettings(args, stdout)
	case "config-payout-settings":
		return configPayoutSettings(args, os.Stdin, stdout)
	case "config-wallet-settings":
		return configWalletSettings(args, os.Stdin, stdout)
	case "config-dashboard-access":
		return configDashboardAccess(args, os.Stdin, stdout)
	case "config-dashboard-auth":
		return configDashboardAuth(args, os.Stdin, stdout)
	case "config-directories":
		return configDirectories(args, os.Stdin, stdout)
	case "config-caddy":
		return configCaddy(args, os.Stdin, stdout)
	case "config-caddy-auth":
		return configCaddyAuth(args, os.Stdin, stdout)
	case "config-caddy-bind":
		return configCaddyBind(args, os.Stdin, stdout)
	case "config-env":
		return configEnv(args, os.Stdin, stdout)
	case "config-env-network":
		return configEnvNetwork(args, os.Stdin, stdout)
	case "config-env-dashboard":
		return configEnvDashboard(args, os.Stdin, stdout)
	case "config-env-memory":
		return configEnvMemory(args, os.Stdin, stdout)
	}
	switch nativeCommand(args) {
	case "help":
		return writeHelp(stdout, reference)
	case "version":
		dir, err := filepath.Abs(filepath.Dir(reference))
		if err != nil {
			return err
		}
		dir, err = filepath.EvalSymlinks(dir)
		if err != nil {
			return err
		}
		return writeVersion(stdout, dir)
	case "doctor-json":
		dir, err := filepath.Abs(filepath.Dir(reference))
		if err != nil {
			return err
		}
		dir, err = filepath.EvalSymlinks(dir)
		if err != nil {
			return err
		}
		runner := doctor.Runner{
			Reference: reference, Version: installedVersion(dir),
			Env: fallbackEnv(os.Environ()), Out: stdout, Err: os.Stderr,
		}
		code, err := runner.RunJSON()
		if errors.Is(err, doctor.ErrFallback) {
			return fallback(reference, args)
		}
		if errors.Is(err, doctor.ErrProbeAborted) {
			return &ExitError{Code: code}
		}
		var interrupted *doctor.SignalError
		if errors.As(err, &interrupted) {
			return &ExitError{Code: code, Signal: interrupted.Signal}
		}
		if err != nil {
			return err
		}
		if code != 0 {
			return &ExitError{Code: 1}
		}
		return nil
	case "status":
		if _, err := exec.LookPath("docker"); err != nil {
			return fallback(reference, args)
		}
		dir, err := filepath.Abs(filepath.Dir(reference))
		if err != nil {
			return err
		}
		dir, err = filepath.EvalSymlinks(dir)
		if err != nil {
			return err
		}
		envFile := os.Getenv("PITHEAD_ENV_FILE")
		if envFile == "" {
			envFile = ".env"
		}
		runner := status.Runner{Dir: dir, Program: reference, EnvFile: envFile, Out: stdout, Err: os.Stderr}
		if code := runner.Run(); code != 0 {
			return &ExitError{Code: code}
		}
		return nil
	default:
		return fallback(reference, args)
	}
}

func nativeCommand(args []string) string {
	if len(args) == 0 {
		return ""
	}
	if isChain(args) {
		return ""
	}
	switch args[0] {
	case "":
		return ""
	case "help", "-h", "--help":
		return "help"
	case "logs":
		return ""
	}
	for _, arg := range args[1:] {
		if arg == "-h" || arg == "--help" {
			return "help"
		}
	}
	switch args[0] {
	case "version", "-V", "--version":
		return "version"
	case "status":
		if len(args) == 1 {
			return "status"
		}
	case "doctor":
		if len(args) == 2 && args[1] == "--json" {
			return "doctor-json"
		}
	}
	return ""
}
