// Package weekrule models academic week rules: an ordered list of segments
// like 1-5、7-11单、12-16双 (docs/csv-import.md). Segments are stored on
// course meetings and recurring-schedule rules as JSONB; expansion to a
// concrete week set happens in Go.
package weekrule

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
)

type Parity string

const (
	ParityAll  Parity = "all"
	ParityOdd  Parity = "odd"
	ParityEven Parity = "even"
)

// Segment covers weeks [Start, End] (inclusive) filtered by parity.
type Segment struct {
	Start  int    `json:"start"`
	End    int    `json:"end"`
	Parity Parity `json:"parity"`
}

// Rule is a normalized segment list. Zero value means "every week".
type Rule []Segment

// ParseSegments validates a raw rule payload (accepts both a bare array and
// {"segments": [...]}).
func ParseSegments(raw json.RawMessage) (Rule, error) {
	if len(raw) == 0 {
		return nil, apperr.Validation("weekRule", "week rule is required")
	}
	var direct []Segment
	if err := json.Unmarshal(raw, &direct); err == nil {
		return Validate(direct)
	}
	var wrapped struct {
		Segments []Segment `json:"segments"`
	}
	if err := json.Unmarshal(raw, &wrapped); err == nil {
		return Validate(wrapped.Segments)
	}
	return nil, apperr.Validation("weekRule", "must be an array of {start,end,parity} segments")
}

// Validate normalizes and checks a segment list.
func Validate(segs []Segment) (Rule, error) {
	if len(segs) == 0 {
		return nil, apperr.Validation("weekRule", "at least one week segment is required")
	}
	out := make(Rule, 0, len(segs))
	for i, s := range segs {
		if s.Start < 1 {
			return nil, apperr.Validation("weekRule", fmt.Sprintf("segment %d: start must be >= 1", i+1))
		}
		if s.End < s.Start {
			return nil, apperr.Validation("weekRule", fmt.Sprintf("segment %d: end must be >= start", i+1))
		}
		if s.End-s.Start > 200 {
			return nil, apperr.Validation("weekRule", fmt.Sprintf("segment %d: range too large", i+1))
		}
		switch s.Parity {
		case ParityAll, "":
			s.Parity = ParityAll
		case ParityOdd, ParityEven:
		default:
			return nil, apperr.Validation("weekRule", fmt.Sprintf("segment %d: parity must be all|odd|even", i+1))
		}
		out = append(out, s)
	}
	return out, nil
}

// Weeks expands the rule to the sorted set of matching weeks within
// [1, totalWeeks]. Results are clamped, deduplicated and sorted.
func (r Rule) Weeks(totalWeeks int) []int {
	if totalWeeks < 1 {
		return nil
	}
	set := map[int]bool{}
	for _, seg := range r {
		lo := max(seg.Start, 1)
		hi := min(seg.End, totalWeeks)
		for w := lo; w <= hi; w++ {
			switch seg.Parity {
			case ParityOdd:
				if w%2 == 1 {
					set[w] = true
				}
			case ParityEven:
				if w%2 == 0 {
					set[w] = true
				}
			default:
				set[w] = true
			}
		}
	}
	out := make([]int, 0, len(set))
	for w := range set {
		out = append(out, w)
	}
	sort.Ints(out)
	return out
}

// MatchesWeek reports whether week w is covered by the rule (ignores clamp).
func (r Rule) MatchesWeek(w int) bool {
	for _, seg := range r {
		if w < seg.Start || w > seg.End {
			continue
		}
		switch seg.Parity {
		case ParityOdd:
			if w%2 == 1 {
				return true
			}
		case ParityEven:
			if w%2 == 0 {
				return true
			}
		default:
			return true
		}
	}
	return false
}

// RestrictBefore returns a copy of the rule limited to weeks < upper
// (used by THIS_AND_FUTURE series splits).
func (r Rule) RestrictBefore(upper int) Rule {
	out := make(Rule, 0, len(r))
	for _, seg := range r {
		hi := min(seg.End, upper-1)
		if hi < seg.Start {
			continue
		}
		out = append(out, Segment{Start: seg.Start, End: hi, Parity: seg.Parity})
	}
	return out
}

// RestrictFrom returns a copy limited to weeks >= lower.
func (r Rule) RestrictFrom(lower int) Rule {
	out := make(Rule, 0, len(r))
	for _, seg := range r {
		lo := max(seg.Start, lower)
		if lo > seg.End {
			continue
		}
		out = append(out, Segment{Start: lo, End: seg.End, Parity: seg.Parity})
	}
	return out
}

func (r Rule) IsEmpty() bool { return len(r) == 0 }

// Describe renders a human-readable form for previews, e.g. "1-5、7-11单".
func (r Rule) Describe() string {
	if len(r) == 0 {
		return "none"
	}
	parts := make([]string, 0, len(r))
	for _, seg := range r {
		s := fmt.Sprintf("%d-%d", seg.Start, seg.End)
		switch seg.Parity {
		case ParityOdd:
			s += "单"
		case ParityEven:
			s += "双"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, "、")
}

// ---- CSV week-column parser ---------------------------------------------
//
// Supports (docs/csv-import.md §Supported Week Syntax):
//	1-16 | 1-5 | 2、5、8 | 1-5、7-11单、12-16双
// separators: 、，, and spaces; 单=odd, 双=even.

var csvSeparators = strings.NewReplacer("、", ",", "，", ",", " ", ",")

// ParseCsv parses a week-number column into a normalized rule.
func ParseCsv(text string) (Rule, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, apperr.Validation("weeks", "week column is empty")
	}
	normalized := csvSeparators.Replace(text)
	// Collapse separator runs produced by the space replacement.
	for strings.Contains(normalized, ",,") {
		normalized = strings.ReplaceAll(normalized, ",,", ",")
	}
	normalized = strings.Trim(normalized, ",")

	parts := strings.Split(normalized, ",")
	var segs []Segment
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		seg, err := parseCsvPart(p)
		if err != nil {
			return nil, err
		}
		segs = append(segs, seg)
	}
	return Validate(segs)
}

func parseCsvPart(p string) (Segment, error) {
	parity := ParityAll
	if strings.HasSuffix(p, "单") {
		parity = ParityOdd
		p = strings.TrimSuffix(p, "单")
	} else if strings.HasSuffix(p, "双") {
		parity = ParityEven
		p = strings.TrimSuffix(p, "双")
	}
	var a, b int
	if strings.Contains(p, "-") {
		if _, err := fmt.Sscanf(p, "%d-%d", &a, &b); err != nil {
			return Segment{}, apperr.Validation("weeks", "cannot parse week token: "+p)
		}
	} else {
		if _, err := fmt.Sscanf(p, "%d", &a); err != nil {
			return Segment{}, apperr.Validation("weeks", "cannot parse week token: "+p)
		}
		b = a
	}
	if a < 1 || b < a {
		return Segment{}, apperr.Validation("weeks", "invalid week range: "+p)
	}
	return Segment{Start: a, End: b, Parity: parity}, nil
}
