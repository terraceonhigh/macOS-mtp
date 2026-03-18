package webdav

import (
	"path"
	"strings"
)

// finderProbeFiles are files that Finder probes for on every directory access.
// Return 404 immediately without touching MTP.
var finderProbeFiles = []string{
	".DS_Store",
	"desktop.ini",
	"Thumbs.db",
	".Spotlight-V100",
	".fseventsd",
	".Trashes",
	".metadata_never_index",
	".metadata_never_index_unless_rootfs",
	".metadata_direct_scope_only",
	".hidden",
	".TemporaryItems",
	".apdisk",
	".vol",
	".com.apple.timemachine.donotpresent",
	"DCIM/.Trashes",
}

// isFinderProbe returns true if the path is a Finder metadata probe
// that should be immediately answered with 404.
func isFinderProbe(reqPath string) bool {
	base := path.Base(reqPath)

	// AppleDouble resource fork files
	if strings.HasPrefix(base, "._") {
		return true
	}

	for _, probe := range finderProbeFiles {
		if base == probe {
			return true
		}
	}
	return false
}
