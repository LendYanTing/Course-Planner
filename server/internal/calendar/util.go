package calendar

import (
	"github.com/google/uuid"
)

// uuidValue aliases google/uuid for internal scan helpers.
type uuidValue = uuid.UUID

// parseUUID validates a uuid string.
func parseUUID(s string) (uuid.UUID, error) {
	return uuid.Parse(s)
}
