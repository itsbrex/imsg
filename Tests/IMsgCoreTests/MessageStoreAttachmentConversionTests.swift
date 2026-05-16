import Foundation
import Testing

@testable import IMsgCore

@Test
func attachmentsByMessageReportsConvertedMetadata() throws {
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("gif")
  try Data("gif".utf8).write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "png")
  try FileManager.default.createDirectory(
    at: converted.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("png".utf8).write(to: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let store = try TestDatabase.makeStore(
    attachmentFilename: source.path,
    attachmentTransferName: "animation.gif",
    attachmentUTI: "com.compuserve.gif",
    attachmentMimeType: "image/gif"
  )
  let attachments = try store.attachments(
    for: 2,
    options: AttachmentQueryOptions(convertUnsupported: true)
  )

  #expect(attachments.first?.originalPath == source.path)
  #expect(attachments.first?.convertedPath == converted.path)
  #expect(attachments.first?.convertedMimeType == "image/png")
}

@Test
func attachmentsByMessagesReportsConvertedMetadata() throws {
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("caf")
  try Data("caf".utf8).write(to: source)
  defer { try? FileManager.default.removeItem(at: source) }
  let converted = AttachmentResolver.convertedURL(for: source.path, targetExtension: "m4a")
  try FileManager.default.createDirectory(
    at: converted.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("m4a".utf8).write(to: converted)
  defer { try? FileManager.default.removeItem(at: converted) }

  let store = try TestDatabase.makeStore(
    attachmentFilename: source.path,
    attachmentTransferName: "voice.caf",
    attachmentUTI: "com.apple.coreaudio-format",
    attachmentMimeType: "audio/x-caf"
  )
  let attachmentsByMessageID = try store.attachments(
    for: [2],
    options: AttachmentQueryOptions(convertUnsupported: true)
  )

  #expect(attachmentsByMessageID[2]?.first?.originalPath == source.path)
  #expect(attachmentsByMessageID[2]?.first?.convertedPath == converted.path)
  #expect(attachmentsByMessageID[2]?.first?.convertedMimeType == "audio/mp4")
}
