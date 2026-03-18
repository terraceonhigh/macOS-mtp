package mtp

/*
#cgo CFLAGS: -I../cvendor
#cgo LDFLAGS: -L/opt/homebrew/lib -lmtp
#include "libmtp.h"
#include <stdlib.h>

// Callback context for streaming file data to Go.
typedef struct {
	int id;
} callback_ctx;

// Defined in binding_callbacks.go via //export.
// MTPDataPutFunc signature: uint16_t (void* params, void* priv, uint32_t sendlen, unsigned char *data, uint32_t *putlen)
extern uint16_t goDataPutFunc(void *params, void *priv, uint32_t sendlen, unsigned char *data, uint32_t *putlen);
// MTPDataGetFunc signature: uint16_t (void* params, void* priv, uint32_t wantlen, unsigned char *data, uint32_t *gotlen)
extern uint16_t goDataGetFunc(void *params, void *priv, uint32_t wantlen, unsigned char *data, uint32_t *gotlen);

// Wrappers that call LIBMTP functions with Go-compatible callback signatures.
static int wrap_get_file_to_handler(LIBMTP_mtpdevice_t *dev, uint32_t id, int ctx_id) {
	callback_ctx ctx;
	ctx.id = ctx_id;
	return LIBMTP_Get_File_To_Handler(dev, id,
		(MTPDataPutFunc)goDataPutFunc, (void*)&ctx,
		NULL, NULL);
}

static int wrap_send_file_from_handler(LIBMTP_mtpdevice_t *dev, LIBMTP_file_t *fi, int ctx_id) {
	callback_ctx ctx;
	ctx.id = ctx_id;
	return LIBMTP_Send_File_From_Handler(dev,
		(MTPDataGetFunc)goDataGetFunc, (void*)&ctx,
		fi, NULL, NULL);
}
*/
import "C"
import (
	"fmt"
	"io"
	"log"
	"sync"
	"unsafe"
)

// Storage represents an MTP storage (internal, SD card, etc.)
type Storage struct {
	ID          uint32
	Description string
	FreeBytes   uint64
	MaxBytes    uint64
}

// FileMeta holds metadata for an MTP object (file or folder).
type FileMeta struct {
	ID        uint32
	ParentID  uint32
	StorageID uint32
	Name      string
	Size      uint64
	ModTime   int64 // Unix timestamp
	IsFolder  bool
	FileType  int
}

// Device wraps a libmtp device pointer.
type Device struct {
	dev *C.LIBMTP_mtpdevice_t
}

// callbackRegistry maps integer IDs to io.Writer/io.Reader for streaming.
var callbackRegistry struct {
	mu      sync.Mutex
	nextID  int
	writers map[int]io.Writer
	readers map[int]io.Reader
}

func init() {
	callbackRegistry.writers = make(map[int]io.Writer)
	callbackRegistry.readers = make(map[int]io.Reader)
	C.LIBMTP_Init()
}

func registerWriter(w io.Writer) int {
	callbackRegistry.mu.Lock()
	defer callbackRegistry.mu.Unlock()
	id := callbackRegistry.nextID
	callbackRegistry.nextID++
	callbackRegistry.writers[id] = w
	return id
}

func unregisterWriter(id int) {
	callbackRegistry.mu.Lock()
	defer callbackRegistry.mu.Unlock()
	delete(callbackRegistry.writers, id)
}

func registerReader(r io.Reader) int {
	callbackRegistry.mu.Lock()
	defer callbackRegistry.mu.Unlock()
	id := callbackRegistry.nextID
	callbackRegistry.nextID++
	callbackRegistry.readers[id] = r
	return id
}

func unregisterReader(id int) {
	callbackRegistry.mu.Lock()
	defer callbackRegistry.mu.Unlock()
	delete(callbackRegistry.readers, id)
}

// DetectDevice finds and opens the first available MTP device.
// Uses the raw detection API for better diagnostics.
func DetectDevice() (*Device, error) {
	var rawDevices *C.LIBMTP_raw_device_t
	var numDevices C.int

	log.Println("Calling LIBMTP_Detect_Raw_Devices...")
	rc := C.LIBMTP_Detect_Raw_Devices(&rawDevices, &numDevices)
	switch rc {
	case C.LIBMTP_ERROR_NO_DEVICE_ATTACHED:
		return nil, fmt.Errorf("no MTP device found (is File Transfer mode selected?)")
	case C.LIBMTP_ERROR_CONNECTING:
		return nil, fmt.Errorf("error connecting to MTP device")
	case C.LIBMTP_ERROR_MEMORY_ALLOCATION:
		return nil, fmt.Errorf("memory allocation error during MTP detection")
	case C.LIBMTP_ERROR_NONE:
		// success
	default:
		return nil, fmt.Errorf("unknown error %d during MTP detection", rc)
	}

	if numDevices == 0 || rawDevices == nil {
		return nil, fmt.Errorf("no MTP devices found")
	}
	defer C.free(unsafe.Pointer(rawDevices))

	log.Printf("Found %d raw MTP device(s), opening first...", int(numDevices))

	dev := C.LIBMTP_Open_Raw_Device_Uncached(rawDevices)
	if dev == nil {
		return nil, fmt.Errorf("failed to open MTP device (session may be locked by another process)")
	}

	log.Println("MTP device opened successfully")
	return &Device{dev: dev}, nil
}

// Close releases the MTP device.
func (d *Device) Close() {
	if d.dev != nil {
		C.LIBMTP_Release_Device(d.dev)
		d.dev = nil
	}
}

// FriendlyName returns the device's friendly name.
func (d *Device) FriendlyName() string {
	cname := C.LIBMTP_Get_Friendlyname(d.dev)
	if cname == nil {
		return "Android Device"
	}
	defer C.free(unsafe.Pointer(cname))
	name := C.GoString(cname)
	if name == "" {
		return "Android Device"
	}
	return name
}

// GetStorages returns all storages on the device.
func (d *Device) GetStorages() ([]Storage, error) {
	rc := C.LIBMTP_Get_Storage(d.dev, C.LIBMTP_STORAGE_SORTBY_NOTSORTED)
	if rc != 0 {
		return nil, fmt.Errorf("failed to get storages")
	}

	var storages []Storage
	for s := d.dev.storage; s != nil; s = s.next {
		desc := "Internal Storage"
		if s.StorageDescription != nil {
			desc = C.GoString(s.StorageDescription)
		}
		storages = append(storages, Storage{
			ID:          uint32(s.id),
			Description: desc,
			FreeBytes:   uint64(s.FreeSpaceInBytes),
			MaxBytes:    uint64(s.MaxCapacity),
		})
	}
	return storages, nil
}

// FilesAndFoldersRoot is the parent ID that means "root of storage".
const FilesAndFoldersRoot = 0xffffffff

// GetFilesAndFolders returns all objects (files and folders) under a given parent.
// Use FilesAndFoldersRoot for the root of a storage.
func (d *Device) GetFilesAndFolders(storageID, parentID uint32) []FileMeta {
	log.Printf("MTP GetFilesAndFolders(storage=%d, parent=0x%x)", storageID, parentID)
	files := C.LIBMTP_Get_Files_And_Folders(d.dev, C.uint32_t(storageID), C.uint32_t(parentID))

	// Check for MTP errors
	errs := C.LIBMTP_Get_Errorstack(d.dev)
	for e := errs; e != nil; e = e.next {
		log.Printf("MTP error: %s", C.GoString(e.error_text))
	}
	if errs != nil {
		C.LIBMTP_Clear_Errorstack(d.dev)
	}

	var result []FileMeta
	for f := files; f != nil; {
		meta := FileMeta{
			ID:        uint32(f.item_id),
			ParentID:  uint32(f.parent_id),
			StorageID: uint32(f.storage_id),
			Name:      C.GoString(f.filename),
			Size:      uint64(f.filesize),
			ModTime:   int64(f.modificationdate),
			FileType:  int(f.filetype),
			IsFolder:  f.filetype == C.LIBMTP_FILETYPE_FOLDER,
		}
		result = append(result, meta)
		next := f.next
		C.LIBMTP_destroy_file_t(f)
		f = next
	}
	return result
}

// GetFileToWriter streams a file from the device to the given writer.
func (d *Device) GetFileToWriter(objectID uint32, w io.Writer) error {
	cbID := registerWriter(w)
	defer unregisterWriter(cbID)

	rc := C.wrap_get_file_to_handler(d.dev, C.uint32_t(objectID), C.int(cbID))
	if rc != 0 {
		return fmt.Errorf("LIBMTP_Get_File_To_Handler failed for object %d", objectID)
	}
	return nil
}

// SendFileFromReader uploads a file to the device from the given reader.
func (d *Device) SendFileFromReader(parentID, storageID uint32, name string, size uint64, r io.Reader) (uint32, error) {
	cbID := registerReader(r)
	defer unregisterReader(cbID)

	fi := C.LIBMTP_new_file_t()
	defer C.LIBMTP_destroy_file_t(fi)
	// LIBMTP_destroy_file_t frees fi.filename, so let it own the CString.
	fi.filename = C.CString(name)
	fi.parent_id = C.uint32_t(parentID)
	fi.storage_id = C.uint32_t(storageID)
	fi.filesize = C.uint64_t(size)
	fi.filetype = C.LIBMTP_FILETYPE_UNKNOWN

	log.Printf("MTP SendFile(parent=0x%x, storage=0x%x, name=%q, size=%d)", parentID, storageID, name, size)
	rc := C.wrap_send_file_from_handler(d.dev, fi, C.int(cbID))
	if rc != 0 {
		d.dumpErrors()
		return 0, fmt.Errorf("LIBMTP_Send_File_From_Handler failed")
	}
	return uint32(fi.item_id), nil
}

// DeleteObject deletes an object on the device.
func (d *Device) DeleteObject(objectID uint32) error {
	rc := C.LIBMTP_Delete_Object(d.dev, C.uint32_t(objectID))
	if rc != 0 {
		d.dumpErrors()
		return fmt.Errorf("LIBMTP_Delete_Object failed for object %d", objectID)
	}
	return nil
}

// CreateFolder creates a folder on the device and returns the new folder's object ID.
func (d *Device) CreateFolder(name string, parentID, storageID uint32) (uint32, error) {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))

	log.Printf("MTP CreateFolder(name=%q, parent=0x%x, storage=0x%x)", name, parentID, storageID)
	id := C.LIBMTP_Create_Folder(d.dev, cname, C.uint32_t(parentID), C.uint32_t(storageID))
	if id == 0 {
		d.dumpErrors()
		return 0, fmt.Errorf("LIBMTP_Create_Folder failed for %q", name)
	}
	return uint32(id), nil
}

// dumpErrors logs and clears the MTP error stack.
func (d *Device) dumpErrors() {
	errs := C.LIBMTP_Get_Errorstack(d.dev)
	for e := errs; e != nil; e = e.next {
		log.Printf("MTP error: %s", C.GoString(e.error_text))
	}
	if errs != nil {
		C.LIBMTP_Clear_Errorstack(d.dev)
	}
}

