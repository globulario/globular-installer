//go:build linux

package platform

import "fmt"

var linuxPlatformCtor func() Platform

func RegisterLinuxPlatform(ctor func() Platform) {
	linuxPlatformCtor = ctor
}

func Detect() (Platform, error) {
	if linuxPlatformCtor == nil {
		return nil, fmt.Errorf("linux platform constructor not registered")
	}
	return linuxPlatformCtor(), nil
}
