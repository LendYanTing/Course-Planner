package schedule

import "github.com/carryingon/courseplanner/server/internal/common/apperr"

func errRuleRequired() error {
	return apperr.Validation("rule", "a rule object is required")
}

func errRuleInvalid() error {
	return apperr.Validation("rule", "invalid rule object")
}
