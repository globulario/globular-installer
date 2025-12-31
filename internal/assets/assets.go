package assets

import (
	"embed"
	"io/fs"
)

//go:embed bin/*
var embedded embed.FS

// BinFS exposes the embedded bin/ directory.
func BinFS() fs.FS {
	sub, err := fs.Sub(embedded, "bin")
	if err != nil {
		panic(err)
	}
	return sub
}
