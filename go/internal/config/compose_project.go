package config

import "bytes"

const (
	composeProjectAssignmentWarning = "Use one literal COMPOSE_PROJECT_NAME assignment in the environment file."
	composeProjectValueWarning      = "COMPOSE_PROJECT_NAME must be a literal lowercase Compose project name."
)

func ComposeProjectName(raw []byte, filePresent, overridePresent bool, override string) (string, string, bool) {
	project := ""
	if overridePresent {
		project = override
	} else if filePresent {
		assignment := composeProjectAssignment(raw)
		if len(assignment) > 0 {
			if !bytes.HasPrefix(assignment, []byte("COMPOSE_PROJECT_NAME=")) || bytes.IndexByte(assignment, '\n') >= 0 {
				return "", composeProjectAssignmentWarning, false
			}
			project = string(assignment[len("COMPOSE_PROJECT_NAME="):])
			if len(project) >= 2 && ((project[0] == '\'' && project[len(project)-1] == '\'') ||
				(project[0] == '"' && project[len(project)-1] == '"')) {
				project = project[1 : len(project)-1]
			}
		}
	}
	if project == "" {
		project = "pithead"
	}
	if !validComposeProject(project) {
		return "", composeProjectValueWarning, false
	}
	return project, "", true
}

func composeProjectAssignment(raw []byte) []byte {
	var matches [][]byte
	for _, line := range bytes.Split(raw, []byte{'\n'}) {
		if composeProjectLineMatches(line) {
			matches = append(matches, line)
		}
	}
	return bytes.Join(matches, []byte{'\n'})
}

func composeProjectLineMatches(line []byte) bool {
	index := 0
	for index < len(line) && asciiSpace(line[index]) {
		index++
	}
	if bytes.HasPrefix(line[index:], []byte("export")) {
		index += len("export")
		if index == len(line) || !asciiSpace(line[index]) {
			return false
		}
		for index < len(line) && asciiSpace(line[index]) {
			index++
		}
	}
	const name = "COMPOSE_PROJECT_NAME"
	if !bytes.HasPrefix(line[index:], []byte(name)) {
		return false
	}
	index += len(name)
	return index == len(line) || !asciiAlphaNumericUnderscore(line[index])
}

func validComposeProject(project string) bool {
	for index := 0; index < len(project); index++ {
		char := project[index]
		if index == 0 {
			if (char < 'a' || char > 'z') && (char < '0' || char > '9') {
				return false
			}
			continue
		}
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '_' && char != '-' {
			return false
		}
	}
	return len(project) > 0
}

func asciiSpace(char byte) bool {
	return char == ' ' || char == '\t' || char == '\r' || char == '\v' || char == '\f'
}

func asciiAlphaNumericUnderscore(char byte) bool {
	return char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || char == '_'
}
