package mcp

import "github.com/carryingon/courseplanner/server/internal/common/apperr"

func errBadChanges() error {
	return apperr.InvalidRequest("invalid change set")
}

func errRange() error {
	return apperr.Validation("range", "end must be after start")
}

func errRangeBig() error {
	return apperr.Validation("range", "range must not exceed 62 days")
}
