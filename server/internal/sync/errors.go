package sync

import "github.com/carryingon/courseplanner/server/internal/common/apperr"

func errBadAfter() error {
	return apperr.Validation("after", "must be a non-negative integer cursor")
}

func errTooManyOperations() error {
	return apperr.Validation("operations", "at most 1000 operations per push")
}
