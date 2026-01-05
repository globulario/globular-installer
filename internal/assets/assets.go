package assets

import (
	"embed"
	"io/fs"
	"path"
)

var (
	//go:embed bin/*
	//go:embed config/*/*
	embedded embed.FS
)

// BinFS exposes the embedded bin/ directory.
func BinFS() fs.FS {
	sub, err := fs.Sub(embedded, "bin")
	if err != nil {
		panic(err)
	}
	return sub
}

// ConfigFS exposes the embedded config/ directory.
func ConfigFS() fs.FS {
	sub, err := fs.Sub(embedded, "config")
	if err != nil {
		panic(err)
	}
	return sub
}

// ReadConfigAsset returns the contents of a file stored under config/.
func ReadConfigAsset(relPath string) ([]byte, error) {
	return embedded.ReadFile(path.Join("config", relPath))
}
