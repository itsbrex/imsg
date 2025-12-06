package send

import (
	"strings"
	"testing"
)

func TestAppleScriptIncludesMessages(t *testing.T) {
	s := appleScript()
	if s == "" {
		t.Fatal("empty script")
	}
	if !containsAll(s, []string{"Messages", "send", "buddy"}) {
		t.Fatalf("script missing expected tokens: %s", s)
	}
}

func TestAppleScriptCoercesAttachmentAlias(t *testing.T) {
	s := appleScript()
	if !strings.Contains(s, "POSIX file theFilePath as alias") {
		t.Fatalf("script should coerce attachment to alias to satisfy Messages: %s", s)
	}
}

func containsAll(s string, parts []string) bool {
	for _, p := range parts {
		if !strings.Contains(s, p) {
			return false
		}
	}
	return true
}
