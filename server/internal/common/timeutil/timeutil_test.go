package timeutil

import (
	"testing"
	"time"
)

func TestLocalize(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Shanghai") // UTC+8, no DST
	got, err := Localize("2026-09-07", "08:00", loc)
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 9, 7, 0, 0, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestLocalizeDST(t *testing.T) {
	loc, _ := time.LoadLocation("America/New_York")
	// 2026-03-08 02:30 is skipped by DST spring-forward; Go normalizes.
	got, err := Localize("2026-03-08", "02:30", loc)
	if err != nil {
		t.Fatal(err)
	}
	if got.Location() != time.UTC {
		t.Fatal("must return UTC")
	}
	// Winter date (EST = UTC-5): 12:00 -> 17:00Z
	winter, _ := Localize("2026-01-10", "12:00", loc)
	if !winter.Equal(time.Date(2026, 1, 10, 17, 0, 0, 0, time.UTC)) {
		t.Fatalf("winter %v", winter)
	}
	// Summer date (EDT = UTC-4): 12:00 -> 16:00Z
	summer, _ := Localize("2026-07-10", "12:00", loc)
	if !summer.Equal(time.Date(2026, 7, 10, 16, 0, 0, 0, time.UTC)) {
		t.Fatalf("summer %v", summer)
	}
}

func TestNoCrossMidnight(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Shanghai")
	start := time.Date(2026, 9, 7, 15, 0, 0, 0, time.UTC) // 23:00 local
	end := time.Date(2026, 9, 7, 17, 0, 0, 0, time.UTC)   // 01:00 local next day
	if err := CheckSameLocalDay(start, end, loc, "block"); err == nil {
		t.Fatal("cross-midnight must be rejected")
	}
	okStart := time.Date(2026, 9, 7, 0, 0, 0, 0, time.UTC) // 08:00 local
	okEnd := time.Date(2026, 9, 7, 1, 40, 0, 0, time.UTC)  // 09:40 local
	if err := CheckSameLocalDay(okStart, okEnd, loc, "block"); err != nil {
		t.Fatalf("same-day must pass: %v", err)
	}
}

func TestParseInstantRejectsZoneLess(t *testing.T) {
	if _, err := ParseInstant("2026-09-07T08:00:00"); err == nil {
		t.Fatal("zoneless datetime must be rejected (docs/datetime.md §1)")
	}
	for _, ok := range []string{"2026-09-07T08:00:00Z", "2026-09-07T08:00:00+08:00", "2026-09-07T00:00:00.123Z"} {
		tm, err := ParseInstant(ok)
		if err != nil {
			t.Fatalf("ParseInstant(%q): %v", ok, err)
		}
		if tm.Location() != time.UTC {
			t.Fatalf("ParseInstant(%q) must normalize to UTC", ok)
		}
	}
}

func TestDateRange(t *testing.T) {
	days, err := DateRangeInLoc("2026-09-07", "2026-09-13", 366)
	if err != nil || len(days) != 7 {
		t.Fatalf("range = %v err=%v", days, err)
	}
	if _, err := DateRangeInLoc("2026-09-13", "2026-09-07", 366); err == nil {
		t.Fatal("reversed range must fail")
	}
	if _, err := DateRangeInLoc("2026-01-01", "2026-01-02", 1); err == nil {
		t.Fatal("oversized range must fail")
	}
}

func TestISOWeekday(t *testing.T) {
	// 2026-09-07 is a Monday.
	if wd, _ := WeekdayOf("2026-09-07"); wd != 1 {
		t.Fatalf("2026-09-07 weekday = %d", wd)
	}
	if wd, _ := WeekdayOf("2026-09-13"); wd != 7 {
		t.Fatalf("2026-09-13 weekday = %d", wd)
	}
}

func TestHHMMValidation(t *testing.T) {
	for _, bad := range []string{"8:00", "24:00", "23:60", "aa:bb", ""} {
		if err := ValidateHHMM(bad); err == nil {
			t.Fatalf("HHMM %q should fail", bad)
		}
	}
	m, err := HHMMToMinutes("23:59")
	if err != nil || m != 1439 {
		t.Fatalf("1439 expected, got %d err %v", m, err)
	}
}
