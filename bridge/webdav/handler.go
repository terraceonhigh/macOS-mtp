package webdav

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"
	"time"

	"macos-mtp/bridge/mtp"

	"golang.org/x/net/webdav"
)

// NewHandler creates an http.Handler that serves an MTP device over WebDAV.
func NewHandler(session *mtp.Session) http.Handler {
	filesystem := &mtpFS{session: session}
	lockSystem := webdav.NewMemLS()

	h := &webdav.Handler{
		FileSystem: filesystem,
		LockSystem: lockSystem,
		Logger: func(r *http.Request, err error) {
			if err != nil {
				log.Printf("WebDAV %s %s → error: %v", r.Method, r.URL.Path, err)
			}
		},
	}

	return &finderHandler{inner: h}
}

// finderHandler wraps the standard WebDAV handler with Finder-specific quirk handling.
type finderHandler struct {
	inner http.Handler
}

func (fh *finderHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	reqPath := cleanPath(r.URL.Path)

	// Intercept Finder probe files — return 404 without touching MTP
	if isFinderProbe(reqPath) {
		http.NotFound(w, r)
		return
	}

	fh.inner.ServeHTTP(w, r)
}

// mtpFS implements webdav.FileSystem backed by an MTP session.
type mtpFS struct {
	session *mtp.Session
}

func (mfs *mtpFS) Mkdir(_ context.Context, name string, _ os.FileMode) error {
	name = cleanPath(name)
	parent := path.Dir(name)
	base := path.Base(name)

	parentMeta, ok := mfs.session.Objects.GetByPath(parent)
	if !ok {
		return os.ErrNotExist
	}

	resp := mfs.session.Do(mtp.MTPRequest{
		Op:        mtp.OpCreateFolder,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      base,
	})
	if resp.Err != nil {
		return resp.Err
	}

	mfs.session.Objects.Put(&mtp.ObjectMeta{
		ID:        resp.ObjectID,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      base,
		Path:      name,
		IsDir:     true,
		ModTime:   time.Now(),
	})
	mfs.session.Objects.InvalidateDir(parent)
	return nil
}

func (mfs *mtpFS) RemoveAll(_ context.Context, name string) error {
	name = cleanPath(name)
	meta, ok := mfs.session.Objects.GetByPath(name)
	if !ok {
		return os.ErrNotExist
	}

	// Delete children first if directory
	if meta.IsDir {
		mfs.session.EnsurePopulated(name)
		children := mfs.session.Objects.ListChildren(name)
		for _, child := range children {
			if err := mfs.RemoveAll(context.Background(), child.Path); err != nil {
				return err
			}
		}
	}

	resp := mfs.session.Do(mtp.MTPRequest{
		Op:       mtp.OpDelete,
		ObjectID: meta.ID,
	})
	if resp.Err != nil {
		return resp.Err
	}
	parent := path.Dir(name)
	mfs.session.Objects.Remove(name)
	mfs.session.Objects.InvalidateDir(parent)
	return nil
}

func (mfs *mtpFS) Rename(_ context.Context, oldName, newName string) error {
	// MTP has no rename. Copy + delete.
	oldName = cleanPath(oldName)
	newName = cleanPath(newName)

	meta, ok := mfs.session.Objects.GetByPath(oldName)
	if !ok {
		return os.ErrNotExist
	}
	if meta.IsDir {
		return &os.PathError{Op: "rename", Path: oldName, Err: os.ErrPermission}
	}

	// Read file into memory
	var buf bytes.Buffer
	resp := mfs.session.Do(mtp.MTPRequest{
		Op:       mtp.OpGetFile,
		ObjectID: meta.ID,
		Writer:   &buf,
	})
	if resp.Err != nil {
		return resp.Err
	}

	// Determine destination parent
	newParent := path.Dir(newName)
	newBase := path.Base(newName)
	parentMeta, ok := mfs.session.Objects.GetByPath(newParent)
	if !ok {
		return os.ErrNotExist
	}

	// Upload to new location
	reader := bytes.NewReader(buf.Bytes())
	sendResp := mfs.session.Do(mtp.MTPRequest{
		Op:        mtp.OpSendFile,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      newBase,
		Size:      uint64(buf.Len()),
		Reader:    reader,
	})
	if sendResp.Err != nil {
		return sendResp.Err
	}

	// Add new entry to object map
	mfs.session.Objects.Put(&mtp.ObjectMeta{
		ID:        sendResp.ObjectID,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      newBase,
		Path:      newName,
		Size:      meta.Size,
		ModTime:   meta.ModTime,
		IsDir:     false,
	})

	// Delete old
	delResp := mfs.session.Do(mtp.MTPRequest{
		Op:       mtp.OpDelete,
		ObjectID: meta.ID,
	})
	if delResp.Err != nil {
		return delResp.Err
	}
	mfs.session.Objects.Remove(oldName)
	mfs.session.Objects.InvalidateDir(path.Dir(oldName))
	mfs.session.Objects.InvalidateDir(path.Dir(newName))
	return nil
}

func (mfs *mtpFS) OpenFile(_ context.Context, name string, flag int, _ os.FileMode) (webdav.File, error) {
	name = cleanPath(name)

	// Root directory
	if name == "/" {
		return &mtpDir{
			session: mfs.session,
			path:    "/",
			meta: &mtp.ObjectMeta{
				Path:    "/",
				Name:    "/",
				IsDir:   true,
				ModTime: time.Now(),
			},
		}, nil
	}

	// Ensure the parent directory is populated so this path is in the cache
	parent := path.Dir(name)
	mfs.session.EnsurePopulated(parent)

	meta, ok := mfs.session.Objects.GetByPath(name)

	// Handle file creation or overwrite (PUT)
	if flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC) != 0 {
		if ok && !meta.IsDir {
			// File exists — delete it first so we can replace it
			mfs.session.Do(mtp.MTPRequest{
				Op:       mtp.OpDelete,
				ObjectID: meta.ID,
			})
			mfs.session.Objects.Remove(name)
			mfs.session.Objects.InvalidateDir(path.Dir(name))
		}
		if !ok || !meta.IsDir {
			return &mtpNewFile{
				session: mfs.session,
				path:    name,
			}, nil
		}
	}

	if !ok {
		return nil, os.ErrNotExist
	}

	if meta.IsDir {
		return &mtpDir{
			session: mfs.session,
			path:    name,
			meta:    meta,
		}, nil
	}

	return &mtpFile{
		session: mfs.session,
		meta:    meta,
	}, nil
}

func (mfs *mtpFS) Stat(_ context.Context, name string) (os.FileInfo, error) {
	name = cleanPath(name)

	if name == "/" {
		return &mtpFileInfo{
			name:    "/",
			size:    0,
			modTime: time.Now(),
			isDir:   true,
		}, nil
	}

	// Ensure parent is populated so this entry exists in the cache
	parent := path.Dir(name)
	mfs.session.EnsurePopulated(parent)

	meta, ok := mfs.session.Objects.GetByPath(name)
	if !ok {
		return nil, os.ErrNotExist
	}

	return metaToFileInfo(meta), nil
}

// mtpDir represents an open MTP directory.
type mtpDir struct {
	session  *mtp.Session
	path     string
	meta     *mtp.ObjectMeta
	children []os.FileInfo
	pos      int
}

func (d *mtpDir) Close() error                                 { return nil }
func (d *mtpDir) Read(_ []byte) (int, error)                   { return 0, os.ErrInvalid }
func (d *mtpDir) Write(_ []byte) (int, error)                  { return 0, os.ErrInvalid }
func (d *mtpDir) Seek(_ int64, _ int) (int64, error)           { return 0, os.ErrInvalid }

func (d *mtpDir) Stat() (os.FileInfo, error) {
	return metaToFileInfo(d.meta), nil
}

func (d *mtpDir) Readdir(count int) ([]os.FileInfo, error) {
	if d.children == nil {
		// Lazily populate this directory from the device
		d.session.EnsurePopulated(d.path)
		entries := d.session.Objects.ListChildren(d.path)
		d.children = make([]os.FileInfo, 0, len(entries))
		for _, e := range entries {
			d.children = append(d.children, metaToFileInfo(e))
		}
	}

	if count <= 0 {
		if d.pos >= len(d.children) {
			return nil, nil
		}
		result := d.children[d.pos:]
		d.pos = len(d.children)
		return result, nil
	}

	if d.pos >= len(d.children) {
		return nil, io.EOF
	}
	end := d.pos + count
	if end > len(d.children) {
		end = len(d.children)
	}
	result := d.children[d.pos:end]
	d.pos = end
	if d.pos >= len(d.children) {
		return result, io.EOF
	}
	return result, nil
}

// mtpFile represents an open MTP file for reading.
type mtpFile struct {
	session *mtp.Session
	meta    *mtp.ObjectMeta
	reader  *bytes.Reader
}

func (f *mtpFile) Close() error { return nil }
func (f *mtpFile) Write(_ []byte) (int, error) {
	return 0, os.ErrPermission
}

func (f *mtpFile) ensureFetched() error {
	if f.reader != nil {
		return nil
	}
	var buf bytes.Buffer
	resp := f.session.Do(mtp.MTPRequest{
		Op:       mtp.OpGetFile,
		ObjectID: f.meta.ID,
		Writer:   &buf,
	})
	if resp.Err != nil {
		return resp.Err
	}
	f.reader = bytes.NewReader(buf.Bytes())
	return nil
}

func (f *mtpFile) Read(p []byte) (int, error) {
	if err := f.ensureFetched(); err != nil {
		return 0, err
	}
	return f.reader.Read(p)
}

func (f *mtpFile) Seek(offset int64, whence int) (int64, error) {
	if err := f.ensureFetched(); err != nil {
		return 0, err
	}
	return f.reader.Seek(offset, whence)
}

func (f *mtpFile) Stat() (os.FileInfo, error) {
	return metaToFileInfo(f.meta), nil
}

func (f *mtpFile) Readdir(_ int) ([]os.FileInfo, error) {
	return nil, os.ErrInvalid
}

// mtpNewFile handles PUT (file creation/upload).
type mtpNewFile struct {
	session *mtp.Session
	path    string
	buf     bytes.Buffer
}

func (f *mtpNewFile) Close() error {
	parent := path.Dir(f.path)
	base := path.Base(f.path)

	parentMeta, ok := f.session.Objects.GetByPath(parent)
	if !ok {
		return os.ErrNotExist
	}

	reader := bytes.NewReader(f.buf.Bytes())
	resp := f.session.Do(mtp.MTPRequest{
		Op:        mtp.OpSendFile,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      base,
		Size:      uint64(f.buf.Len()),
		Reader:    reader,
	})
	if resp.Err != nil {
		return resp.Err
	}

	f.session.Objects.Put(&mtp.ObjectMeta{
		ID:        resp.ObjectID,
		ParentID:  parentMeta.ID,
		StorageID: parentMeta.StorageID,
		Name:      base,
		Path:      f.path,
		Size:      uint64(f.buf.Len()),
		ModTime:   time.Now(),
		IsDir:     false,
	})
	f.session.Objects.InvalidateDir(parent)
	return nil
}

func (f *mtpNewFile) Read(_ []byte) (int, error)          { return 0, os.ErrInvalid }
func (f *mtpNewFile) Seek(_ int64, _ int) (int64, error)  { return 0, nil }
func (f *mtpNewFile) Stat() (os.FileInfo, error) {
	return &mtpFileInfo{
		name:    path.Base(f.path),
		size:    int64(f.buf.Len()),
		modTime: time.Now(),
		isDir:   false,
	}, nil
}
func (f *mtpNewFile) Readdir(_ int) ([]os.FileInfo, error) { return nil, os.ErrInvalid }
func (f *mtpNewFile) Write(p []byte) (int, error)          { return f.buf.Write(p) }

// mtpFileInfo implements os.FileInfo.
type mtpFileInfo struct {
	name    string
	size    int64
	modTime time.Time
	isDir   bool
}

func (fi *mtpFileInfo) Name() string      { return fi.name }
func (fi *mtpFileInfo) Size() int64       { return fi.size }
func (fi *mtpFileInfo) Mode() fs.FileMode {
	if fi.isDir {
		return fs.ModeDir | 0o755
	}
	return 0o644
}
func (fi *mtpFileInfo) ModTime() time.Time { return fi.modTime }
func (fi *mtpFileInfo) IsDir() bool        { return fi.isDir }
func (fi *mtpFileInfo) Sys() interface{}   { return nil }

func metaToFileInfo(m *mtp.ObjectMeta) *mtpFileInfo {
	return &mtpFileInfo{
		name:    path.Base(m.Path),
		size:    int64(m.Size),
		modTime: m.ModTime,
		isDir:   m.IsDir,
	}
}

func cleanPath(p string) string {
	p = path.Clean(p)
	if p == "." {
		return "/"
	}
	return p
}
