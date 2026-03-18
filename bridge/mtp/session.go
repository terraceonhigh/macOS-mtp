package mtp

import (
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
	"time"
)

// ObjectMeta holds POSIX-like metadata for an MTP object.
type ObjectMeta struct {
	ID        uint32
	ParentID  uint32
	StorageID uint32
	Name      string
	Path      string
	Size      uint64
	ModTime   time.Time
	IsDir     bool
}

// ObjectMap maintains a bidirectional mapping between POSIX paths and MTP object IDs.
// Directories are lazily populated: a directory exists in the map once its parent
// has been listed, but its children are only fetched when ListDir is called.
type ObjectMap struct {
	mu         sync.RWMutex
	byPath     map[string]*ObjectMeta
	byID       map[uint32]*ObjectMeta
	populated  map[string]bool // tracks which directories have had their children fetched
}

func NewObjectMap() *ObjectMap {
	return &ObjectMap{
		byPath:    make(map[string]*ObjectMeta),
		byID:      make(map[uint32]*ObjectMeta),
		populated: make(map[string]bool),
	}
}

func (m *ObjectMap) Put(meta *ObjectMeta) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.byPath[meta.Path] = meta
	m.byID[meta.ID] = meta
}

func (m *ObjectMap) Remove(objPath string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if meta, ok := m.byPath[objPath]; ok {
		delete(m.byPath, objPath)
		delete(m.byID, meta.ID)
	}
	// Also invalidate this directory's populated status
	delete(m.populated, objPath)
}

func (m *ObjectMap) GetByPath(p string) (*ObjectMeta, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	meta, ok := m.byPath[p]
	return meta, ok
}

func (m *ObjectMap) GetByID(id uint32) (*ObjectMeta, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	meta, ok := m.byID[id]
	return meta, ok
}

// InvalidateDir marks a directory as needing re-enumeration from the device.
func (m *ObjectMap) InvalidateDir(dirPath string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.populated, strings.TrimSuffix(dirPath, "/"))
}

// IsPopulated returns whether a directory's children have been fetched.
func (m *ObjectMap) IsPopulated(dirPath string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.populated[dirPath]
}

// MarkPopulated marks a directory as having had its children fetched.
func (m *ObjectMap) MarkPopulated(dirPath string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.populated[dirPath] = true
}

// ListChildren returns cached children of a directory (does not fetch from device).
func (m *ObjectMap) ListChildren(dirPath string) []*ObjectMeta {
	m.mu.RLock()
	defer m.mu.RUnlock()

	dirPath = strings.TrimSuffix(dirPath, "/")
	prefix := dirPath + "/"
	var children []*ObjectMeta
	for p, meta := range m.byPath {
		if !strings.HasPrefix(p, prefix) {
			continue
		}
		// Only direct children: no further slashes after the prefix
		rest := p[len(prefix):]
		if rest != "" && !strings.Contains(rest, "/") {
			children = append(children, meta)
		}
	}
	return children
}

// MTPOp identifies the type of MTP operation.
type MTPOp int

const (
	OpGetFile MTPOp = iota
	OpSendFile
	OpDelete
	OpCreateFolder
	OpListDir // lazy enumeration of a single directory
)

// MTPRequest is sent to the session goroutine.
type MTPRequest struct {
	Op        MTPOp
	ObjectID  uint32
	ParentID  uint32
	StorageID uint32
	Name      string
	Size      uint64
	Path      string // for OpListDir: the directory path
	Writer    io.Writer
	Reader    io.Reader
	Response  chan MTPResponse
}

// MTPResponse is returned from the session goroutine.
type MTPResponse struct {
	Entries  []*ObjectMeta
	ObjectID uint32
	Err      error
}

// Session owns the MTP device and serialises all operations.
type Session struct {
	device   *Device
	Objects  *ObjectMap
	requests chan MTPRequest
	done     chan struct{}
}

// NewSession opens a device and populates the root-level storage entries.
func NewSession() (*Session, error) {
	dev, err := DetectDevice()
	if err != nil {
		return nil, err
	}

	s := &Session{
		device:   dev,
		Objects:  NewObjectMap(),
		requests: make(chan MTPRequest, 16),
		done:     make(chan struct{}),
	}

	if err := s.initStorages(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("initializing storages: %w", err)
	}

	go s.run()
	return s, nil
}

// DeviceName returns the friendly name of the connected device.
func (s *Session) DeviceName() string {
	return s.device.FriendlyName()
}

// Close shuts down the session goroutine and releases the device.
func (s *Session) Close() {
	close(s.requests)
	<-s.done
	s.device.Close()
}

// Do sends a request to the session goroutine and waits for the response.
func (s *Session) Do(req MTPRequest) MTPResponse {
	req.Response = make(chan MTPResponse, 1)
	s.requests <- req
	return <-req.Response
}

// EnsurePopulated makes sure the children of dirPath have been fetched from the device.
// This is safe to call from any goroutine — the actual MTP call runs on the session goroutine.
func (s *Session) EnsurePopulated(dirPath string) {
	if s.Objects.IsPopulated(dirPath) {
		return
	}
	s.Do(MTPRequest{Op: OpListDir, Path: dirPath})
}

func (s *Session) run() {
	defer close(s.done)
	for req := range s.requests {
		resp := s.dispatch(req)
		req.Response <- resp
	}
}

func (s *Session) dispatch(req MTPRequest) MTPResponse {
	switch req.Op {
	case OpGetFile:
		err := s.device.GetFileToWriter(req.ObjectID, req.Writer)
		return MTPResponse{Err: err}
	case OpSendFile:
		parentID := s.resolveParentID(req.ParentID, req.StorageID)
		id, err := s.device.SendFileFromReader(parentID, req.StorageID, req.Name, req.Size, req.Reader)
		return MTPResponse{ObjectID: id, Err: err}
	case OpDelete:
		err := s.device.DeleteObject(req.ObjectID)
		return MTPResponse{Err: err}
	case OpCreateFolder:
		parentID := s.resolveParentID(req.ParentID, req.StorageID)
		id, err := s.device.CreateFolder(req.Name, parentID, req.StorageID)
		return MTPResponse{ObjectID: id, Err: err}
	case OpListDir:
		entries := s.populateDir(req.Path)
		return MTPResponse{Entries: entries}
	default:
		return MTPResponse{Err: fmt.Errorf("unknown op: %d", req.Op)}
	}
}

// initStorages fetches storage list and registers them as top-level directories.
func (s *Session) initStorages() error {
	storages, err := s.device.GetStorages()
	if err != nil {
		return err
	}

	log.Printf("Found %d storage(s)", len(storages))
	for _, st := range storages {
		log.Printf("  Storage %d: %s (%.1f GB free / %.1f GB total)",
			st.ID, st.Description,
			float64(st.FreeBytes)/1e9, float64(st.MaxBytes)/1e9)

		storagePath := "/" + sanitizeName(st.Description)
		s.Objects.Put(&ObjectMeta{
			ID:        st.ID,
			StorageID: st.ID,
			Name:      st.Description,
			Path:      storagePath,
			IsDir:     true,
			ModTime:   time.Now(),
		})
	}

	// Mark root as populated (its children are the storages)
	s.Objects.MarkPopulated("/")
	return nil
}

// populateDir fetches children of a directory from the device and caches them.
// Must be called from the session goroutine.
func (s *Session) populateDir(dirPath string) []*ObjectMeta {
	dirPath = strings.TrimSuffix(dirPath, "/")

	if s.Objects.IsPopulated(dirPath) {
		return s.Objects.ListChildren(dirPath)
	}

	meta, ok := s.Objects.GetByPath(dirPath)
	if !ok || !meta.IsDir {
		return nil
	}

	// For storage roots, parentID for enumeration is FilesAndFoldersRoot
	mtpParentID := meta.ID
	storageID := meta.StorageID

	// Check if this is a storage root (its ID == its StorageID and parentID is 0)
	// For storage entries, we enumerate with the root constant
	if meta.ID == meta.StorageID {
		mtpParentID = FilesAndFoldersRoot
	}

	entries := s.device.GetFilesAndFolders(storageID, mtpParentID)
	log.Printf("Lazy enumerate %s: %d entries", dirPath, len(entries))

	var result []*ObjectMeta
	for _, e := range entries {
		objPath := dirPath + "/" + sanitizeName(e.Name)
		obj := &ObjectMeta{
			ID:        e.ID,
			ParentID:  e.ParentID,
			StorageID: e.StorageID,
			Name:      e.Name,
			Path:      objPath,
			Size:      e.Size,
			ModTime:   time.Unix(e.ModTime, 0),
			IsDir:     e.IsFolder,
		}
		s.Objects.Put(obj)
		result = append(result, obj)
	}

	s.Objects.MarkPopulated(dirPath)
	return result
}

// resolveParentID converts our internal parent ID to the MTP parent ID.
// Storage root entries have ID == StorageID, but MTP expects parent_id=0xFFFFFFFF
// for objects at the root of a storage.
func (s *Session) resolveParentID(parentID, storageID uint32) uint32 {
	if parentID == storageID {
		return FilesAndFoldersRoot // 0xFFFFFFFF = root of storage
	}
	return parentID
}

func sanitizeName(name string) string {
	return strings.ReplaceAll(name, "/", "_")
}
