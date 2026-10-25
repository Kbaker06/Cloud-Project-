// Package store is a deliberately simple, concurrency-safe in-memory note store.
// Swap it for Postgres (project 01) or DynamoDB (project 03) as a stretch goal:
// the Store interface is the seam.
package store

import (
	"errors"
	"sort"
	"strconv"
	"sync"
	"time"
)

var ErrNotFound = errors.New("not found")

type Note struct {
	ID        string    `json:"id"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

type Store interface {
	Create(text string) (Note, error)
	Get(id string) (Note, error)
	List() ([]Note, error)
	Delete(id string) error
}

type Memory struct {
	mu     sync.RWMutex
	nextID int
	notes  map[string]Note
	now    func() time.Time
}

func NewMemory() *Memory {
	return &Memory{notes: map[string]Note{}, now: time.Now}
}

func (m *Memory) Create(text string) (Note, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nextID++
	n := Note{ID: strconv.Itoa(m.nextID), Text: text, CreatedAt: m.now().UTC()}
	m.notes[n.ID] = n
	return n, nil
}

func (m *Memory) Get(id string) (Note, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n, ok := m.notes[id]
	if !ok {
		return Note{}, ErrNotFound
	}
	return n, nil
}

func (m *Memory) List() ([]Note, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Note, 0, len(m.notes))
	for _, n := range m.notes {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool {
		a, _ := strconv.Atoi(out[i].ID)
		b, _ := strconv.Atoi(out[j].ID)
		return a < b
	})
	return out, nil
}

func (m *Memory) Delete(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.notes[id]; !ok {
		return ErrNotFound
	}
	delete(m.notes, id)
	return nil
}
