package network

import "errors"

const maxAuditCap = 4096

type auditCapRequest struct {
	Operation string `json:"operation"`
	Limit     *int   `json:"limit"`
}

type auditCapPolicy struct {
	Limit     int       `json:"limit"`
	NamesFull []bool    `json:"names_full"`
	Spend     [][2]bool `json:"spend"`
}

func buildAuditCapPolicy(request auditCapRequest) (auditCapPolicy, error) {
	if request.Limit == nil {
		return auditCapPolicy{}, errors.New("missing audit cap input")
	}
	if *request.Limit < 0 || *request.Limit > maxAuditCap {
		return auditCapPolicy{}, errors.New("audit cap input exceeds limit")
	}
	namesFull := make([]bool, *request.Limit+2)
	for count := range namesFull {
		namesFull[count] = count >= *request.Limit
	}
	spend := make([][2]bool, *request.Limit+2)
	for count := range spend {
		spend[count] = [2]bool{count < *request.Limit, count == *request.Limit}
	}
	return auditCapPolicy{
		Limit:     *request.Limit,
		NamesFull: namesFull,
		Spend:     spend,
	}, nil
}
