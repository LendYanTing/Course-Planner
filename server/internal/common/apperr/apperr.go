// Package apperr defines the structured application error contract used by
// every layer of the server. Handlers map these errors onto the HTTP envelope
// documented in docs/api.md §2; domain services return them verbatim.
package apperr

import (
	"errors"
	"fmt"
	"net/http"
)

// Canonical error codes (docs/api.md §16). Clients must branch on Code only.
const (
	CodeInvalidRequest       = "INVALID_REQUEST"
	CodeUnauthorized         = "UNAUTHORIZED"
	CodeForbidden            = "FORBIDDEN"
	CodeNotFound             = "NOT_FOUND"
	CodeValidationError      = "VALIDATION_ERROR"
	CodeInvalidTimezone      = "INVALID_TIMEZONE"
	CodeCrossMidnight        = "CROSS_MIDNIGHT_NOT_ALLOWED"
	CodeScheduleConflict     = "SCHEDULE_CONFLICT"
	CodeCourseConflict       = "COURSE_CONFLICT"
	CodeStaleRevision        = "STALE_REVISION"
	CodeSyncConflict         = "SYNC_CONFLICT"
	CodeDuplicateOperation   = "DUPLICATE_OPERATION"
	CodeCsvParseError        = "CSV_PARSE_ERROR"
	CodeCsvValidationError   = "CSV_VALIDATION_ERROR"
	CodeConfirmationRequired = "CONFIRMATION_REQUIRED"
	CodeConfirmationExpired  = "CONFIRMATION_EXPIRED"
	CodeInternal             = "INTERNAL_ERROR"
)

// Error is a structured error with a stable machine code plus optional
// per-field details for validation-style failures.
type Error struct {
	Status  int
	Code    string
	Message string
	Details map[string]any
	cause   error
}

func (e *Error) Error() string {
	if e.cause != nil {
		return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.cause)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *Error) Unwrap() error { return e.cause }

// WithDetail returns a shallow copy with one extra detail entry.
func (e *Error) WithDetail(key string, value any) *Error {
	d := make(map[string]any, len(e.Details)+1)
	for k, v := range e.Details {
		d[k] = v
	}
	d[key] = value
	return &Error{Status: e.Status, Code: e.Code, Message: e.Message, Details: d, cause: e.cause}
}

func New(status int, code, message string) *Error {
	return &Error{Status: status, Code: code, Message: message}
}

func Newf(status int, code, format string, args ...any) *Error {
	return &Error{Status: status, Code: code, Message: fmt.Sprintf(format, args...)}
}

// ---- convenience constructors -------------------------------------------

func InvalidRequest(msg string) *Error {
	return New(http.StatusBadRequest, CodeInvalidRequest, msg)
}

func Unauthorized(msg string) *Error {
	return New(http.StatusUnauthorized, CodeUnauthorized, msg)
}

func Forbidden(msg string) *Error {
	return New(http.StatusForbidden, CodeForbidden, msg)
}

func NotFound(what string) *Error {
	return New(http.StatusNotFound, CodeNotFound, what+" not found")
}

func Validation(field, message string) *Error {
	return &Error{
		Status:  http.StatusUnprocessableEntity,
		Code:    CodeValidationError,
		Message: "validation failed",
		Details: map[string]any{"fields": map[string]string{field: message}},
	}
}

func ValidationMulti(fields map[string]string) *Error {
	return &Error{
		Status:  http.StatusUnprocessableEntity,
		Code:    CodeValidationError,
		Message: "validation failed",
		Details: map[string]any{"fields": fields},
	}
}

func InvalidTimezone(tz string) *Error {
	return Newf(http.StatusBadRequest, CodeInvalidTimezone, "unknown IANA timezone %q", tz)
}

func CrossMidnight(what string) *Error {
	return Newf(http.StatusUnprocessableEntity, CodeCrossMidnight, "%s must not cross midnight in the user timezone", what)
}

func CourseConflict(msg string) *Error {
	return New(http.StatusConflict, CodeCourseConflict, msg)
}

func ScheduleConflict(msg string) *Error {
	return New(http.StatusConflict, CodeScheduleConflict, msg)
}

func StaleRevision(entityType string, current, base int64) *Error {
	return &Error{
		Status:  http.StatusConflict,
		Code:    CodeStaleRevision,
		Message: "entity was modified concurrently",
		Details: map[string]any{"entityType": entityType, "currentRevision": current, "baseRevision": base},
	}
}

func ConfirmationExpired() *Error {
	return New(http.StatusGone, CodeConfirmationExpired, "confirmation expired or already applied")
}

// From extracts an *Error; ok=false means err is an unexpected internal error.
func From(err error) (*Error, bool) {
	var ae *Error
	if errors.As(err, &ae) {
		return ae, true
	}
	return nil, false
}

// HTTPStatus maps any error onto a response status. Non-app errors are 500.
func HTTPStatus(err error) int {
	if ae, ok := From(err); ok {
		return ae.Status
	}
	return http.StatusInternalServerError
}
