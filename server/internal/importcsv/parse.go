// Package importcsv parses and imports course CSV files
// (docs/csv-import.md): 课程名称,星期,开始节数,结束节数,老师,地点,周数.
// Flow: upload -> parse -> validate -> preview -> user confirms -> commit.
package importcsv

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"io"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
)

// FieldError mirrors docs/csv-import.md §Errors.
type FieldError struct {
	Line    int    `json:"line"`
	Field   string `json:"field"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type ParsedCourse struct {
	Line        int    `json:"line"`
	Name        string `json:"name"`
	Weekday     int    `json:"weekday"`
	PeriodStart int    `json:"periodStart"`
	PeriodEnd   int    `json:"periodEnd"`
	Teacher     string `json:"teacher"`
	Location    string `json:"location"`
	WeekRule    string `json:"weeks"`
}

// ParseResult holds the parser/validator output.
type ParseResult struct {
	Courses []ParsedCourse `json:"courses"`
	Errors  []FieldError   `json:"errors"`
}

// Header normalization map (English + Chinese synonyms).
var headerAliases = map[string]string{
	"课程名称": "name", "课程名": "name", "name": "name", "课名": "name",
	"星期": "weekday", "周几": "weekday", "weekday": "weekday", "day": "weekday",
	"开始节数": "periodStart", "起始节次": "periodStart", "开始节次": "periodStart", "periodStart": "periodStart",
	"结束节数": "periodEnd", "结束节次": "periodEnd", "periodEnd": "periodEnd",
	"老师": "teacher", "教师": "teacher", "teacher": "teacher",
	"地点": "location", "教室": "location", "location": "location",
	"周数": "weeks", "周次": "weeks", "weeks": "weeks", "week": "weeks",
}

// Parse parses CSV bytes (UTF-8; a BOM is tolerated) into raw rows keyed by
// normalized header, without calendar-specific validation.
func Parse(data []byte) ([]map[string]string, error) {
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}) // UTF-8 BOM
	reader := csv.NewReader(bytes.NewReader(data))
	reader.TrimLeadingSpace = true
	reader.FieldsPerRecord = -1

	header, err := reader.Read()
	if err != nil {
		return nil, apperr.New(422, apperr.CodeCsvParseError, "cannot read CSV header: "+err.Error())
	}
	cols := make([]string, len(header))
	for i, h := range header {
		key, ok := headerAliases[strings.TrimSpace(strings.Trim(h, "\ufeff \t"))]
		if !ok {
			return nil, apperr.New(422, apperr.CodeCsvParseError,
				fmt.Sprintf("unknown column %q (expected: 课程名称,星期,开始节数,结束节数,老师,地点,周数)", h))
		}
		cols[i] = key
	}

	var rows []map[string]string
	lineNo := 1
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		lineNo++
		if err != nil {
			return nil, apperr.New(422, apperr.CodeCsvParseError, fmt.Sprintf("CSV syntax error near line %d: %v", lineNo, err))
		}
		row := map[string]string{}
		for i, key := range cols {
			val := strings.TrimSpace(record[i])
			row[key] = val
		}
		// All-blank line.
		if row["name"] == "" && row["weekday"] == "" && row["weeks"] == "" {
			continue
		}
		row["__line"] = fmt.Sprintf("%d", lineNo)
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		return nil, apperr.New(422, apperr.CodeCsvParseError, "CSV contains no course rows")
	}
	return rows, nil
}

// Validate converts raw rows to structured courses applying structural rules.
// totalWeeks bounds week numbers; calendar-specific period checks happen in
// ValidateWithPeriods (the service).
func Validate(rows []map[string]string, totalWeeks int) ParseResult {
	res := ParseResult{}
	for _, row := range rows {
		line := atoiOr(row["__line"], 0)
		name := row["name"]
		weekday := atoiOr(row["weekday"], 0)
		start := atoiOr(row["periodStart"], 0)
		end := atoiOr(row["periodEnd"], 0)
		if name == "" {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "课程名称", Code: "EMPTY_NAME", Message: "course name must not be empty"})
			continue
		}
		if len(name) > 100 {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "课程名称", Code: "NAME_TOO_LONG", Message: "course name is too long"})
			continue
		}
		if weekday < 1 || weekday > 7 {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "星期", Code: "BAD_WEEKDAY", Message: "weekday must be 1-7"})
			continue
		}
		if start < 1 || end < start {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "节次", Code: "BAD_PERIOD_RANGE", Message: "periodStart must be >= 1 and <= periodEnd"})
			continue
		}
		rule, err := weekrule.ParseCsv(row["weeks"])
		if err != nil {
			msg := "cannot parse week rule"
			if ae, ok := apperr.From(err); ok {
				if fields, ok := ae.Details["fields"].(map[string]string); ok {
					if m, ok2 := fields["weeks"]; ok2 {
						msg = m
					}
				}
			}
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "周数", Code: "BAD_WEEK_RULE", Message: msg})
			continue
		}
		tooFar := false
		for _, seg := range rule {
			if seg.End > totalWeeks {
				tooFar = true
			}
		}
		if tooFar {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "周数", Code: "WEEK_OUT_OF_RANGE",
				Message: fmt.Sprintf("week number exceeds the semester range (1-%d)", totalWeeks)})
			continue
		}
		res.Courses = append(res.Courses, ParsedCourse{
			Line: line, Name: name, Weekday: weekday,
			PeriodStart: start, PeriodEnd: end,
			Teacher: row["teacher"], Location: row["location"],
			WeekRule: rule.Describe(),
		})
	}
	return res
}

func atoiOr(s string, def int) int {
	n := 0
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return def
	}
	return n
}
