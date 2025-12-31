//go:build !linux

package platform

import "errors"

func Detect() (Platform, error) {
	return nil, errors.New("unsupported platform")
}
