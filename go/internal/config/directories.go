package config

import "strings"

type DirectoryPlan struct {
	Values [12]string
}

func DeriveDirectories(raw []byte, workingDirectory string) (DirectoryPlan, error) {
	if !supportedDirectoryPath(workingDirectory) {
		return DirectoryPlan{}, ErrUnsupportedValidation
	}
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return DirectoryPlan{}, ErrUnsupportedValidation
	}

	paths := [...]string{"monero.data_dir", "tari.data_dir", "p2pool.data_dir", "tor.data_dir", "dashboard.data_dir"}
	defaults := [...]string{"monero", "tari", "p2pool", "tor"}
	plan := DirectoryPlan{}
	for index := range defaults {
		configured, err := directoryConfigValue(document.root, paths[index])
		if err != nil {
			return DirectoryPlan{}, err
		}
		if dashboardAccessResolveDefault(configured) != "" && !supportedDirectoryPath(configured) {
			return DirectoryPlan{}, ErrUnsupportedValidation
		}
		plan.Values[index] = directoryResolveDefault(configured, workingDirectory+"/data/"+defaults[index])
	}

	dataRoot := directoryParent(plan.Values[0])
	for index := 1; index < 4; index++ {
		if directoryParent(plan.Values[index]) != dataRoot {
			dataRoot = workingDirectory + "/data"
			break
		}
	}
	dashboardConfig, err := directoryConfigValue(document.root, paths[4])
	if err != nil {
		return DirectoryPlan{}, err
	}
	if dashboardAccessResolveDefault(dashboardConfig) != "" && !supportedDirectoryPath(dashboardConfig) {
		return DirectoryPlan{}, ErrUnsupportedValidation
	}
	plan.Values[4] = directoryResolveDefault(dashboardConfig, dataRoot+"/dashboard")
	plan.Values[5] = "1"
	if plan.Values[4] == dashboardConfig {
		plan.Values[5] = "0"
	}
	plan.Values[6] = dataRoot + "/proxy-tls"
	plan.Values[7] = workingDirectory + "/data/clearnet-state"
	plan.Values[8] = workingDirectory + "/data/control"
	plan.Values[9] = workingDirectory + "/data/caddy-logs"
	plan.Values[10] = dataRoot
	plan.Values[11] = dashboardConfig
	return plan, nil
}

func directoryConfigValue(root node, path string) (string, error) {
	value, err := networkSettingsScalar(root, path, node{value: ""}, false)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	return value, nil
}

func directoryResolveDefault(value, fallback string) string {
	if dashboardAccessResolveDefault(value) == "" {
		return fallback
	}
	return value
}

func supportedDirectoryPath(value string) bool {
	if !strings.HasPrefix(value, "/") || strings.HasPrefix(value, "//") || strings.HasPrefix(value, "-") {
		return false
	}
	for _, current := range value {
		if current <= 0x1f || current >= 0x7f && current <= 0x9f {
			return false
		}
	}
	return true
}

func directoryParent(value string) string {
	for len(value) > 1 && value[len(value)-1] == '/' {
		value = value[:len(value)-1]
	}
	index := strings.LastIndexByte(value, '/')
	if index == 0 {
		return "/"
	}
	for index > 0 && value[index-1] == '/' {
		index--
	}
	return value[:index]
}
