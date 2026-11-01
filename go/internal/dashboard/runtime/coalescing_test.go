package runtime

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"
)

type waitingContext struct {
	context.Context
	waiting chan<- struct{}
}

func (c waitingContext) Done() <-chan struct{} {
	c.waiting <- struct{}{}
	return c.Context.Done()
}

func awaitWaiters(t *testing.T, waiting <-chan struct{}, count int) {
	t.Helper()
	for range count {
		select {
		case <-waiting:
		case <-time.After(5 * time.Second):
			t.Fatal("state requests did not join the flight")
		}
	}
}

func releaseFlight(release chan struct{}) {
	select {
	case <-release:
	default:
		close(release)
	}
}

func TestConcurrentStateInputsShareOneFlight(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		<-release
		_, _ = w.Write([]byte(`{"ok":true,"input":{"generation":"old"}}`))
	}))
	defer server.Close()
	defer releaseFlight(release)
	target, _ := url.Parse(server.URL)
	provider := inputProvider(target)
	waiting := make(chan struct{}, 12)
	results := make(chan error, 12)
	for range 12 {
		go func() {
			raw, err := provider(waitingContext{context.Background(), waiting}, "state", "range=all")
			if err == nil && string(raw) != `{"generation":"old"}` {
				err = errors.New("state flight returned a different generation")
			}
			results <- err
		}()
	}
	awaitWaiters(t, waiting, 12)
	close(release)
	for range 12 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("concurrent collections = %d, want 1", calls.Load())
	}
	if _, err := provider(context.Background(), "state", "range=all"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("completed flight was cached: %d collections", calls.Load())
	}
}

func TestCanceledCallerDoesNotCancelSharedState(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		select {
		case <-release:
			_, _ = w.Write([]byte(`{"ok":true,"input":{}}`))
		case <-r.Context().Done():
			t.Error("one caller canceled the shared request")
		}
	}))
	defer server.Close()
	defer releaseFlight(release)
	target, _ := url.Parse(server.URL)
	provider := inputProvider(target)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	waiting := make(chan struct{}, 2)
	first := make(chan error, 1)
	second := make(chan error, 1)
	go func() {
		_, err := provider(waitingContext{ctx, waiting}, "state", "")
		first <- err
	}()
	awaitWaiters(t, waiting, 1)
	go func() {
		_, err := provider(waitingContext{context.Background(), waiting}, "state", "")
		second <- err
	}()
	awaitWaiters(t, waiting, 1)
	cancel()
	if err := <-first; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled caller = %v", err)
	}
	close(release)
	if err := <-second; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("shared collection count = %d", calls.Load())
	}
}

func TestLastCanceledWaiterStopsStateCollection(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
		close(stopped)
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := inputProvider(target)(ctx, "state", "")
		result <- err
	}()
	<-started
	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("last waiter = %v", err)
	}
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("collection continued after its last caller disconnected")
	}
}

func TestDistinctStateCollectionsHaveBoundedConcurrency(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{}, 8)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-release
		_, _ = w.Write([]byte(`{"ok":true,"input":{}}`))
	}))
	defer server.Close()
	defer releaseFlight(release)
	target, _ := url.Parse(server.URL)
	provider := inputProvider(target)
	results := make(chan error, 4)
	for index := range 4 {
		go func() {
			_, err := provider(context.Background(), "state", string(rune('a'+index)))
			results <- err
		}()
	}
	awaitWaiters(t, started, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	waiting := make(chan struct{}, 1)
	fifth := make(chan error, 1)
	go func() {
		_, err := provider(waitingContext{ctx, waiting}, "state", "fifth")
		fifth <- err
	}()
	awaitWaiters(t, waiting, 1)
	select {
	case <-started:
		t.Fatal("a fifth distinct collection bypassed the bound")
	case <-time.After(50 * time.Millisecond):
	}
	cancel()
	if err := <-fifth; !errors.Is(err, context.Canceled) {
		t.Fatalf("queued caller = %v", err)
	}
	close(release)
	for range 4 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}
