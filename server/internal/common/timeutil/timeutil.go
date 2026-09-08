// Package timeutil centralizes the datetime contract (docs/datetime.md):
//
//   - All absolute instants are UTC and serialized as RFC3339.
//   - All local-calendar semantics (recurrence, week numbers, cross-midnight
//     checks) are computed in the user's immutable IANA timezone, then
//     converted to UTC. DST is handled by Go's tzdata.
//   - Local dates travel as 'YYYY-MM-DD' strings; local wall-clock times as
//     'HH:MM' strings. Neither is ever interpreted in the server's local zone.
package timeutil

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
)

// Now returns the current server time in UTC.
func Now() time.Time { return time.Now().UTC() }

var (
	dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	hhmmRe = regexp.MustCompile(`^([01]\d|2[0-3]):[0-5]\d$`)
	rfcRe  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$`)
)

// LoadTimezone validates and loads an IANA timezone. Invalid zones yield
// INVALID_TIMEZONE (also rejects fixed-offset pseudo-zones like "UTC+8").
func LoadTimezone(name string) (*time.Location, error) {
	if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "..") {
		return nil, apperr.InvalidTimezone(name)
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, apperr.InvalidTimezone(name)
	}
	return loc, nil
}

// ParseInstant parses an RFC3339 datetime and normalizes it to UTC.
// Offsets are accepted; zoneless datetimes are rejected per docs/datetime.md §1.
func ParseInstant(s string) (time.Time, error) {
	if !rfcRe.MatchString(s) {
		return time.Time{}, apperr.Validation("datetime", "must be an RFC3339 UTC offset datetime, e.g. 2026-09-08T01:00:00Z")
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, apperr.Validation("datetime", "invalid RFC3339 datetime: "+s)
	}
	return t.UTC(), nil
}

// FormatInstant renders an instant as RFC3339 with Z suffix.
func FormatInstant(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

// ValidateDate checks the 'YYYY-MM-DD' shape (semantic range validated by time.Parse).
func ValidateDate(s string) error {
	if !dateRe.MatchString(s) {
		return apperr.Validation("date", "must look like YYYY-MM-DD")
	}
	if _, err := ParseDate(s); err != nil {
		return err
	}
	return nil
}

// ParseDate parses 'YYYY-MM-DD' into a zone-less civil date.
func ParseDate(s string) (time.Time, error) {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, apperr.Validation("date", "invalid calendar date: "+s)
	}
	return t, nil
}

// FormatDate renders a civil date from a time interpreted in loc.
func FormatDate(t time.Time, loc *time.Location) string {
	return t.In(loc).Format("2006-01-02")
}

// ValidateHHMM checks a 'HH:MM' wall-clock string (00:00..23:59).
func ValidateHHMM(s string) error {
	if !hhhmmMatch(s) {
		return apperr.Validation("time", "must look like HH:MM with 00:00 <= time < 24:00")
	}
	return nil
}

func hhhmmMatch(s string) bool { return hhmmRe.MatchString(s) }

// HHMMToMinutes converts 'HH:MM' to minutes since local midnight.
func HHMMToMinutes(s string) (int, error) {
	if !hhhmmMatch(s) {
		return 0, apperr.Validation("time", "must look like HH:MM, got "+s)
	}
	var h, m int
	if _, err := fmt.Sscanf(s, "%d:%d", &h, &m); err != nil {
		return 0, apperr.Validation("time", "bad HH:MM value "+s)
	}
	return h*60 + m, nil
}

// MinutesToHHMM converts minutes since local midnight to 'HH:MM'.
func MinutesToHHMM(mins int) string {
	return fmt.Sprintf("%02d:%02d", mins/60%24, mins%60)
}

// Localize converts civil date + 'HH:MM' wall-clock in loc into a UTC instant.
// DST-correct via time.Date normalization rules.
func Localize(date string, hhmm string, loc *time.Location) (time.Time, error) {
	d, err := ParseDate(date)
	if err != nil {
		return time.Time{}, err
	}
	mins, err := HHMMToMinutes(hhmm)
	if err != nil {
		return time.Time{}, err
	}
	return time.Date(d.Year(), d.Month(), d.Day(), mins/60, mins%60, 0, 0, loc).UTC(), nil
}

// LocalizeMinute is Localize for minute-of-day instead of 'HH:MM'.
func LocalizeMinute(date string, minuteOfDay int, loc *time.Location) (time.Time, error) {
	d, err := ParseDate(date)
	if err != nil {
		return time.Time{}, err
	}
	return time.Date(d.Year(), d.Month(), d.Day(), minuteOfDay/60, minuteOfDay%60, 0, 0, loc).UTC(), nil
}

// LocalMidnightUTC returns the UTC instant of local midnight for date in loc.
func LocalMidnightUTC(date string, loc *time.Location) (time.Time, error) {
	d, err := ParseDate(date)
	if err != nil {
		return time.Time{}, err
	}
	return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, loc).UTC(), nil
}

// DateRangeInLoc lists every civil date in [start, end] (inclusive, both
// 'YYYY-MM-DD'), bounded to maxDays as a safety valve.
func DateRangeInLoc(start, end string, maxDays int) ([]string, error) {
	s, err := ParseDate(start)
	if err != nil {
		return nil, err
	}
	e, err := ParseDate(end)
	if err != nil {
		return nil, err
	}
	if e.Before(s) {
		return nil, apperr.Validation("dateRange", "end date is before start date")
	}
	days := int(e.Sub(s).Hours()/24) + 1
	if days > maxDays {
		return nil, apperr.Validation("dateRange", fmt.Sprintf("range too large: %d days (max %d)", days, maxDays))
	}
	out := make([]string, 0, days)
	for d := s; !d.After(e); d = d.AddDate(0, 0, 1) {
		out = append(out, d.Format("2006-01-02"))
	}
	return out, nil
}

// WeekdayOf returns ISO weekday (1=Monday..7=Sunday) of a civil date.
func WeekdayOf(date string) (int, error) {
	d, err := ParseDate(date)
	if err != nil {
		return 0, err
	}
	return ISOWeekday(d.Weekday()), nil
}

// ISOWeekday converts time.Weekday to 1..7 (Mon..Sun).
func ISOWeekday(w time.Weekday) int {
	if w == time.Sunday {
		return 7
	}
	return int(w)
}

// AddDays shifts a civil date by n days.
func AddDays(date string, n int) (string, error) {
	d, err := ParseDate(date)
	if err != nil {
		return "", err
	}
	return d.AddDate(0, 0, n).Format("2006-01-02"), nil
}

// DiffDays returns end-start in days (civil arithmetic).
func DiffDays(start, end string) (int, error) {
	s, err := ParseDate(start)
	if err != nil {
		return 0, err
	}
	e, err := ParseDate(end)
	if err != nil {
		return 0, err
	}
	return int(e.Sub(s).Hours() / 24), nil
}

// CheckSameLocalDay verifies that both instants fall on the same civil date
// in loc — the "no cross-midnight" rule for meetings, schedules and blocks.
// what is used for the error message.
func CheckSameLocalDay(start, end time.Time, loc *time.Location, what string) error {
	if !end.After(start) {
		return apperr.Validation(what, "end must be after start")
	}
	sd := start.In(loc)
	ed := end.In(loc)
	if sd.Format("2006-01-02") != ed.Format("2006-01-02") {
		return apperr.CrossMidnight(what)
	}
	return nil
}

// Overlap reports whether two half-open intervals intersect.
func Overlap(aStart, aEnd, bStart, bEnd time.Time) bool {
	return aStart.Before(bEnd) && bStart.Before(aEnd)
}
