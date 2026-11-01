package api

import (
	"encoding/json"
	"io"
)

func jsonNumberComplete(decoder *json.Decoder) bool {
	var extra any
	return decoder.Decode(&extra) == io.EOF
}
