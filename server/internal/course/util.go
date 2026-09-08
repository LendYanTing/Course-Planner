package course

import (
	"github.com/google/uuid"
)

type uuidValue = uuid.UUID

func uuidParse(s string) (uuid.UUID, error) {
	return uuid.Parse(s)
}
