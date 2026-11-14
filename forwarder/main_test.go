package main

import "testing"

func TestParse(t *testing.T) {
	if l, tg, err := parse("61000:3000"); err != nil || l != 61000 || tg != 3000 {
		t.Fatalf("got %d %d %v", l, tg, err)
	}
	for _, bad := range []string{"3000", "a:1", "1:0", "70000:1"} {
		if _, _, err := parse(bad); err == nil {
			t.Fatalf("%q should fail", bad)
		}
	}
}

func TestCandidatesTryLoopbackFirst(t *testing.T) {
	c := candidates(3000)
	if c[0] != "127.0.0.1:3000" || c[1] != "[::1]:3000" {
		t.Fatalf("unexpected order: %v", c)
	}
}
