import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func sendRichWithFileAndReplyUsesAttachmentBridge() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "text": ["here it is"],
      "file": ["~/Desktop/pic.jpg"],
      "replyTo": ["parent-guid"],
      "effect": ["impact"],
      "subject": ["subject"],
      "part": ["2"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  var stagedSource = ""

  let (output, _) = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "sent-guid"]
      },
      stageAttachment: { path in
        stagedSource = path
        return "/staged/pic.jpg"
      }
    )
  }

  #expect(capturedAction == .sendAttachment)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["message"] as? String == "here it is")
  #expect(capturedParams["filePath"] as? String == "/staged/pic.jpg")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["effectId"] as? String == "com.apple.MobileSMS.expressivesend.impact")
  #expect(capturedParams["subject"] as? String == "subject")
  #expect(capturedParams["partIndex"] as? Int == 2)
  #expect(capturedParams["isAudioMessage"] as? Bool == false)
  #expect(stagedSource.hasSuffix("/Desktop/pic.jpg"))
  #expect(output.contains("send-rich: sent (guid=sent-guid)"))
}

@Test
func sendRichTextOnlyStillUsesMessageBridge() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;-;+15551234567"],
      "text": ["hi"],
      "replyTo": ["parent-guid"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await SendRichCommand.run(
      values: values,
      runtime: runtime,
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return ["messageGuid": "sent-guid"]
      }
    )
  }

  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+15551234567")
  #expect(capturedParams["message"] as? String == "hi")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
  #expect(capturedParams["filePath"] == nil)
}
