package spec

func DefaultInstallSpec(vars map[string]string) *InstallSpec {
	return &InstallSpec{
		Version: 1,
		Steps: []StepSpec{
			{ID: "ensure-user-group", Type: "ensure_user_group"},
			{ID: "ensure-dirs", Type: "ensure_dirs"},
			{ID: "install-binaries", Type: "install_binaries"},
			{ID: "install-files", Type: "install_files"},
			{ID: "install-services", Type: "install_services"},
			{ID: "normalize-scylla-config", Type: "normalize_scylla_config"},
			{ID: "start-services", Type: "start_services"},
			{ID: "health-checks", Type: "health_checks"},
			{ID: "install-placeholder", Type: "noop"},
		},
	}
}
