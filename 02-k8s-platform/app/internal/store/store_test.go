package store

import (
	"sync"
	"testing"
)

func TestConcurrentCreatesGetUniqueIDs(t *testing.T) {
	m := NewMemory()
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := m.Create("x"); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()

	notes, _ := m.List()
	if len(notes) != 200 {
		t.Fatalf("got %d notes, want 200", len(notes))
	}
	seen := map[string]bool{}
	for i, n := range notes {
		if seen[n.ID] {
			t.Fatalf("duplicate id %s", n.ID)
		}
		seen[n.ID] = true
		if i > 0 && notes[i-1].ID >= n.ID && len(notes[i-1].ID) == len(n.ID) {
			t.Fatalf("list not sorted numerically at %d", i)
		}
	}
}

func TestDeleteMissing(t *testing.T) {
	if err := NewMemory().Delete("nope"); err != ErrNotFound {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}
