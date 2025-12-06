// Package send dispatches outbound Messages via AppleScript.
package send

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/steipete/imsg/internal/util"
)

// Service represents the transport preference.
type Service string

// Service values control which Messages transport is used.
const (
	// ServiceAuto picks iMessage when available, otherwise SMS.
	ServiceAuto Service = "auto"
	// ServiceIMessage forces iMessage.
	ServiceIMessage Service = "imessage"
	// ServiceSMS forces SMS/Text Relay.
	ServiceSMS Service = "sms"
)

// Options controls how a message is sent.
type Options struct {
	Recipient      string
	Text           string
	AttachmentPath string
	Service        Service
	Region         string
}

// Send dispatches a message via Messages.app using AppleScript.
func Send(ctx context.Context, opts Options) error {
	if opts.Region == "" {
		opts.Region = "US"
	}
	opts.Recipient = util.NormalizeE164(opts.Recipient, opts.Region)
	svc := opts.Service
	if svc == "" {
		svc = ServiceAuto
	}

	attachFlag := "0"
	if opts.AttachmentPath != "" {
		attachFlag = "1"
	}

	script := appleScript()
	args := []string{"-l", "AppleScript", "-e", script, opts.Recipient, opts.Text, string(svc), opts.AttachmentPath, attachFlag}
	cmd := exec.CommandContext(ctx, "osascript", args...)

	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("osascript failed: %w (output: %s)", err, string(out))
	}
	return nil
}

func appleScript() string {
	// Items: 1 recipient, 2 text, 3 service, 4 file path, 5 useAttachment
	return `on run argv
    set theRecipient to item 1 of argv
    set theMessage to item 2 of argv
    set theService to item 3 of argv
    set theFilePath to item 4 of argv
    set useAttachment to item 5 of argv

    tell application "Messages"
        if theService is "sms" then
            set targetService to first service whose service type is SMS
        else
            set targetService to first service whose service type is iMessage
        end if

        set targetBuddy to buddy theRecipient of targetService
        if theMessage is not "" then
            send theMessage to targetBuddy
        end if
        if useAttachment is "1" then
            -- Messages expects an alias; the coercion prevents "Can't get POSIX file" errors.
            set theFile to POSIX file theFilePath as alias
            send theFile to targetBuddy
        end if
    end tell
end run`
}
