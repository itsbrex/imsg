import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func isGroupHandleFlagsGroup() {
  #expect(isGroupHandle(identifier: "iMessage;+;chat123", guid: "") == true)
  #expect(isGroupHandle(identifier: "", guid: "iMessage;-;chat999") == false)
  #expect(isGroupHandle(identifier: "+1555", guid: "") == false)
}

@Test
func chatPayloadIncludesParticipantsAndGroupFlag() {
  let date = Date(timeIntervalSince1970: 0)
  let payload = chatPayload(
    id: 1,
    identifier: "iMessage;+;chat123",
    guid: "iMessage;+;chat123",
    name: "Group",
    service: "iMessage",
    lastMessageAt: date,
    participants: ["+111", "+222"]
  )
  #expect(payload["id"] as? Int64 == 1)
  #expect(payload["identifier"] as? String == "iMessage;+;chat123")
  #expect(payload["is_group"] as? Bool == true)
  #expect((payload["participants"] as? [String])?.count == 2)
}

@Test
func chatPayloadIncludesContactName() {
  let payload = chatPayload(
    id: 2,
    identifier: "+15551234567",
    guid: "iMessage;-;+15551234567",
    name: "+15551234567",
    service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0),
    participants: ["+15551234567"],
    contactName: "Alice"
  )
  #expect(payload["contact_name"] as? String == "Alice")
}

@Test
func messagePayloadIncludesChatFields() throws {
  let message = Message(
    rowID: 5,
    chatID: 10,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 1,
    guid: "msg-guid-5",
    replyToGUID: "msg-guid-1",
    threadOriginatorGUID: "thread-guid-5",
    destinationCallerID: "me@icloud.com"
  )
  let chatInfo = ChatInfo(
    id: 10,
    identifier: "iMessage;+;chat123",
    guid: "iMessage;+;chat123",
    name: "Group",
    service: "iMessage"
  )
  let attachment = AttachmentMeta(
    filename: "file.dat",
    transferName: "file.dat",
    uti: "public.data",
    mimeType: "application/octet-stream",
    totalBytes: 12,
    isSticker: false,
    originalPath: "/tmp/file.dat",
    convertedPath: "/tmp/file.png",
    convertedMimeType: "image/png",
    missing: false
  )
  let reaction = Reaction(
    rowID: 99,
    reactionType: .like,
    sender: "+123",
    isFromMe: false,
    date: Date(timeIntervalSince1970: 2),
    associatedMessageID: 5
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: ["+111"],
    attachments: [attachment],
    reactions: [reaction]
  )
  #expect(payload["chat_id"] as? Int64 == 10)
  #expect(payload["guid"] as? String == "msg-guid-5")
  #expect(payload["reply_to_guid"] as? String == "msg-guid-1")
  #expect(payload["destination_caller_id"] as? String == "me@icloud.com")
  #expect(payload["thread_originator_guid"] as? String == "thread-guid-5")
  #expect(payload["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(payload["chat_name"] as? String == "Group")
  #expect(payload["is_group"] as? Bool == true)
  #expect((payload["attachments"] as? [[String: Any]])?.count == 1)
  let attachmentPayload = (payload["attachments"] as? [[String: Any]])?.first
  #expect(attachmentPayload?["converted_path"] as? String == "/tmp/file.png")
  #expect(attachmentPayload?["converted_mime_type"] as? String == "image/png")
  #expect(
    (payload["reactions"] as? [[String: Any]])?.first?["emoji"] as? String
      == ReactionType.like.emoji)
}

@Test
func messagePayloadExposesReplyParentSnakeCaseKeys() throws {
  let message = Message(
    rowID: 11,
    chatID: 10,
    sender: "+456",
    text: "Calendar",
    date: Date(timeIntervalSince1970: 3),
    isFromMe: false,
    service: "iMessage",
    handleID: 2,
    attachmentsCount: 0,
    guid: "reply-guid",
    threadOriginatorGUID: "parent-guid",
    replyToText: "Should I lead with calendar, family, or email?",
    replyToSender: "+123"
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: []
  )

  #expect(
    payload["reply_to_text"] as? String == "Should I lead with calendar, family, or email?"
  )
  #expect(payload["reply_to_sender"] as? String == "+123")
  #expect(payload["thread_originator_guid"] as? String == "parent-guid")
}

@Test
func messagePayloadOmitsReplyParentWhenAbsent() throws {
  let message = Message(
    rowID: 12,
    chatID: 10,
    sender: "+456",
    text: "standalone",
    date: Date(timeIntervalSince1970: 3),
    isFromMe: false,
    service: "iMessage",
    handleID: 2,
    attachmentsCount: 0,
    guid: "msg-guid-12"
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: []
  )

  // JSONSerialization preserves Codable `nil` as a missing key (the bridging
  // omits NSNull entries from `Encodable?` properties). Treat both
  // "missing key" and "NSNull" as absent so the assertion stays robust to
  // SQLite.swift / Foundation behaviour changes.
  let replyText = payload["reply_to_text"]
  let replySender = payload["reply_to_sender"]
  #expect(replyText == nil || replyText is NSNull)
  #expect(replySender == nil || replySender is NSNull)
}

@Test
func messagePayloadIncludesSenderAndReactionNames() throws {
  let message = Message(
    rowID: 7,
    chatID: 10,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-guid-7"
  )
  let reaction = Reaction(
    rowID: 101,
    reactionType: .love,
    sender: "+456",
    isFromMe: false,
    date: Date(timeIntervalSince1970: 2),
    associatedMessageID: 7
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: [reaction],
    senderName: "Alice",
    reactionSenderNames: [101: "Bob"]
  )
  #expect(payload["sender_name"] as? String == "Alice")
  let reactions = payload["reactions"] as? [[String: Any]]
  #expect(reactions?.first?["sender_name"] as? String == "Bob")
}

@Test
func messagePayloadOmitsEmptyReplyToGuid() throws {
  let message = Message(
    rowID: 6,
    chatID: 10,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-guid-6",
    replyToGUID: nil
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: []
  )
  #expect(payload["reply_to_guid"] == nil)
  #expect(payload["destination_caller_id"] == nil)
  #expect(payload["thread_originator_guid"] == nil)
  #expect(payload["guid"] as? String == "msg-guid-6")
}

@Test
func watchDebounceIntervalDefaultsToHalfSecond() throws {
  #expect(try watchDebounceIntervalParam([:]) == 0.5)
}

@Test
func watchDebounceIntervalAcceptsSnakeAndCamelCaseMilliseconds() throws {
  #expect(try watchDebounceIntervalParam(["debounce_ms": 750]) == 0.75)
  #expect(try watchDebounceIntervalParam(["debounceMs": "125"]) == 0.125)
}

@Test
func watchDebounceIntervalRejectsInvalidValues() {
  do {
    _ = try watchDebounceIntervalParam(["debounce_ms": -1])
    #expect(Bool(false))
  } catch let error as RPCError {
    #expect(error.code == -32602)
    #expect(error.data?.contains("debounce_ms") == true)
  } catch {
    #expect(Bool(false))
  }
}

@Test
func paramParsingHelpers() {
  #expect(stringParam(123 as NSNumber) == "123")
  #expect(intParam("42") == 42)
  #expect(int64Param(NSNumber(value: 9_223_372_036_854_775_000 as Int64)) != nil)
  #expect(boolParam("true") == true)
  #expect(boolParam("false") == false)
  #expect(stringArrayParam("a,b , c").count == 3)
  #expect(stringArrayParam(["x", "y"]).count == 2)
}
