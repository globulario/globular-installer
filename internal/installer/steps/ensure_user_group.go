package steps

type EnsureUserGroupStep struct{}

func NewEnsureUserGroup(user, group string) *EnsureUserGroupStep {
	_ = user
	_ = group
	return &EnsureUserGroupStep{}
}
