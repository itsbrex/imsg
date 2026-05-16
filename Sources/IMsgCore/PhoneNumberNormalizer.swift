import Foundation
import PhoneNumberKit

final class PhoneNumberNormalizer: @unchecked Sendable {
  // PhoneNumberUtility is not Sendable upstream, but parse/format are
  // documented as thread-safe and we hold an immutable reference here.
  private let phoneNumberUtility = PhoneNumberUtility()

  func normalize(_ input: String, region: String) -> String {
    do {
      let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
      return phoneNumberUtility.format(number, toType: .e164)
    } catch {
      return input
    }
  }
}
