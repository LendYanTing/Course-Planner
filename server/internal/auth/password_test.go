package auth

import "testing"

func TestPasswordHashRoundTrip(t *testing.T) {
	hash, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	ok, err := VerifyPassword("correct horse battery staple", hash)
	if err != nil || !ok {
		t.Fatalf("verify ok=%v err=%v", ok, err)
	}
	ok, _ = VerifyPassword("wrong password", hash)
	if ok {
		t.Fatal("wrong password must not verify")
	}
}

func TestPasswordValidatePolicy(t *testing.T) {
	if err := ValidatePasswordPolicy("short"); err == nil {
		t.Fatal("short password must fail")
	}
	if err := ValidatePasswordPolicy("password123"); err != nil {
		t.Fatalf("long password must pass: %v", err)
	}
}
