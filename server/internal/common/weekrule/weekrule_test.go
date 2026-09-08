package weekrule

import (
	"reflect"
	"testing"
)

func TestParseCsvSyntax(t *testing.T) {
	cases := []struct {
		in   string
		want Rule
	}{
		{"1-16", Rule{{1, 16, ParityAll}}},
		{"2、5、8", Rule{{2, 2, ParityAll}, {5, 5, ParityAll}, {8, 8, ParityAll}}},
		{"1-5、7-11单、12-16双", Rule{{1, 5, ParityAll}, {7, 11, ParityOdd}, {12, 16, ParityEven}}},
		{"1,2，3 4", Rule{{1, 1, ParityAll}, {2, 2, ParityAll}, {3, 3, ParityAll}, {4, 4, ParityAll}}},
	}
	for _, c := range cases {
		got, err := ParseCsv(c.in)
		if err != nil {
			t.Fatalf("ParseCsv(%q): %v", c.in, err)
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Fatalf("ParseCsv(%q) = %v, want %v", c.in, got, c.want)
		}
	}

	for _, bad := range []string{"", "abc", "1-", "单", "0-3", "5-2"} {
		if _, err := ParseCsv(bad); err == nil {
			t.Fatalf("ParseCsv(%q) should fail", bad)
		}
	}
}

func TestExpandWeeks(t *testing.T) {
	rule, _ := ParseCsv("1-5、7-11单、12-16双")
	got := rule.Weeks(16)
	want := []int{1, 2, 3, 4, 5, 7, 9, 11, 12, 14, 16}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Weeks = %v, want %v", got, want)
	}
	// clamp beyond total weeks
	got = rule.Weeks(10)
	want = []int{1, 2, 3, 4, 5, 7, 9}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Weeks(10) = %v, want %v", got, want)
	}
}

func TestRestrictBeforeFrom(t *testing.T) {
	rule, _ := ParseCsv("1-16")
	if got := rule.RestrictBefore(6); len(got) != 1 || got[0].End != 5 {
		t.Fatalf("RestrictBefore(6) = %v", got)
	}
	if got := rule.RestrictFrom(6); len(got) != 1 || got[0].Start != 6 {
		t.Fatalf("RestrictFrom(6) = %v", got)
	}
	odd, _ := ParseCsv("1-5单")
	if got := odd.RestrictBefore(4); got.IsEmpty() {
		// no odd week below 4 except 1,3 -> segment 1-3 single -> 1,3
		if w := got.Weeks(16); !reflect.DeepEqual(w, []int{1, 3}) {
			t.Fatalf("odd restrict weeks = %v", w)
		}
	}
}

func TestValidateSegments(t *testing.T) {
	if _, err := Validate([]Segment{{0, 5, ParityAll}}); err == nil {
		t.Fatal("start < 1 should fail")
	}
	if _, err := Validate([]Segment{{5, 3, ParityAll}}); err == nil {
		t.Fatal("end < start should fail")
	}
	if _, err := Validate([]Segment{{1, 5, "midnight"}}); err == nil {
		t.Fatal("bad parity should fail")
	}
	if _, err := Validate(nil); err == nil {
		t.Fatal("empty rule should fail")
	}
}

func TestMatchesWeek(t *testing.T) {
	rule, _ := ParseCsv("1-10单")
	if rule.MatchesWeek(1) != true || rule.MatchesWeek(3) != true {
		t.Fatal("odd week must match")
	}
	if rule.MatchesWeek(2) != false {
		t.Fatal("even week must not match")
	}
}

func TestDescribeRoundTrip(t *testing.T) {
	rule, _ := ParseCsv("1-5、7-11单、12-16双")
	d := rule.Describe()
	rule2, err := ParseCsv(d)
	if err != nil {
		t.Fatalf("describe %q failed parse: %v", d, err)
	}
	if !reflect.DeepEqual(rule, rule2) {
		t.Fatalf("round trip mismatch: %v vs %v", rule, rule2)
	}
}
