package installer

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func ensureRuntimeMaps(rt *RuntimeState) {
	if rt == nil {
		return
	}
	if rt.ChangedFiles == nil {
		rt.ChangedFiles = make(map[string]bool)
	}
	if rt.ChangedUnits == nil {
		rt.ChangedUnits = make(map[string]bool)
	}
	if rt.ChangedBinaries == nil {
		rt.ChangedBinaries = make(map[string]bool)
	}
}
