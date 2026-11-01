package storage

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
)

type request struct {
	Op          string  `json:"op"`
	Path        string  `json:"path"`
	SQL         string  `json:"sql"`
	Args        []any   `json:"args"`
	ArgsList    [][]any `json:"args_list"`
	Where       string  `json:"where"`
	Message     string  `json:"message"`
	Reason      string  `json:"reason"`
	SchemaError string  `json:"schema_error"`
	OpenError   string  `json:"open_error"`
}

type session struct {
	store *Store
	tx    *sql.Tx
}

func Run(input io.Reader, output io.Writer) error {
	s := &session{}
	defer s.close()
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		var command request
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		var result any
		err := decoder.Decode(&command)
		if err == nil {
			result, err = s.run(command)
		}
		reply := map[string]any{
			"ok": err == nil, "result": wireValue(result),
			"health": s.health(), "connected": s.store != nil && s.store.DB() != nil,
		}
		if err != nil {
			reply["error"], reply["error_kind"] = ErrorMessage(err), errorKind(err)
		}
		if err := encoder.Encode(reply); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func (s *session) run(command request) (any, error) {
	ctx := context.Background()
	if command.Op == "classify" {
		return IsCorruption(errors.New(command.Message)), nil
	}
	if command.Op == "open" {
		s.close()
		var err error
		s.store, err = OpenConnection(command.Path)
		return nil, err
	}
	if s.store == nil {
		return nil, ErrClosed
	}
	switch command.Op {
	case "initialize", "apply-schema", "integrity", "recover", "db-error":
		if err := s.finish(false); err != nil {
			return nil, err
		}
		original := s.store.openDB
		if command.OpenError != "" {
			s.store.openDB = func(string) (*sql.DB, error) { return nil, errors.New(command.OpenError) }
		}
		defer func() { s.store.openDB = original }()
		schema := func() error {
			if command.SchemaError != "" {
				return errors.New(command.SchemaError)
			}
			return s.store.ApplySchema(ctx)
		}
		switch command.Op {
		case "initialize":
			return nil, s.store.InitializeWith(ctx, schema)
		case "apply-schema":
			return nil, schema()
		case "integrity":
			return nil, s.store.CheckIntegrity(ctx)
		case "recover":
			return nil, s.store.RecoverWithSchema(command.Reason, schema)
		default:
			err := errors.New(command.Message)
			if command.Where != "DB Recovery Error" && IsCorruption(err) {
				s.store.markFailed(false)
				return nil, s.store.RecoverWithSchema(command.Where+": "+command.Message, schema)
			}
			return nil, s.store.DBError(command.Where, err)
		}
	case "prune":
		s.store.PruneQuarantined()
		return nil, nil
	case "health":
		return s.health(), nil
	case "begin":
		return nil, s.begin(ctx)
	case "commit":
		return nil, s.finish(true)
	case "rollback":
		return nil, s.finish(false)
	case "close":
		s.close()
		return nil, nil
	case "execute":
		return s.execute(ctx, command.SQL, command.Args)
	case "executemany":
		batch := command.ArgsList
		if batch == nil {
			for _, item := range command.Args {
				values, ok := item.([]any)
				if !ok {
					return nil, errors.New("parameters are of unsupported type")
				}
				batch = append(batch, values)
			}
		}
		result := sqlResult{Rowcount: 0}
		for _, args := range batch {
			row, err := s.execute(ctx, command.SQL, args)
			if err != nil {
				return nil, err
			}
			result.Rowcount += row.Rowcount
		}
		return result, nil
	default:
		return nil, errors.New("unsupported storage operation")
	}
}

func (s *session) begin(ctx context.Context) error {
	if s.tx != nil {
		return nil
	}
	var err error
	s.tx, err = s.store.BeginTx(ctx, nil)
	return err
}

func (s *session) finish(commit bool) error {
	if s.tx == nil {
		return nil
	}
	tx := s.tx
	s.tx = nil
	if commit {
		return tx.Commit()
	}
	return tx.Rollback()
}

func (s *session) close() {
	_ = s.finish(false)
	if s.store != nil {
		_ = s.store.Close()
	}
}

func (s *session) health() any {
	if s.store == nil {
		return nil
	}
	health := s.store.Health()
	var reset any
	if health.LastReset != nil {
		var quarantine any
		if health.LastReset.Quarantine != "" {
			quarantine = health.LastReset.Quarantine
		}
		reset = map[string]any{"ts": health.LastReset.Time, "reason": health.LastReset.Reason, "quarantine": quarantine}
	}
	return map[string]any{
		"healthy": health.Healthy, "unrecoverable": health.Unrecoverable,
		"reset_count": health.ResetCount, "last_reset": reset,
	}
}

func errorKind(err error) string {
	var parameter *parameterError
	if errors.As(err, &parameter) {
		return parameter.kind
	}
	if errors.Is(err, ErrClosed) {
		return "ProgrammingError"
	}
	var coded interface{ Code() int }
	if errors.As(err, &coded) {
		switch coded.Code() & 255 {
		case 19:
			return "IntegrityError"
		case 11, 26:
			return "DatabaseError"
		}
	}
	return "OperationalError"
}
