/// One phone contact, with only what chat needs: a name, numbers and email addresses.
///
/// Read from the phone's address book on demand, kept in memory only for the current search,
/// and never stored or uploaded. At most the one address the user picks for an email or WhatsApp
/// message ever leaves the device.
class ContactItem {
  const ContactItem({
    required this.id,
    required this.displayName,
    this.phoneNumbers = const [],
    this.emails = const [],
  });

  /// The platform's local contact ID. Never sent anywhere.
  final String id;
  final String displayName;
  final List<String> phoneNumbers;
  final List<String> emails;

  /// [displayName] for matching: lower case, punctuation removed, single spaces.
  String get normalizedName => normalizeContactName(displayName);

  bool get hasPhone => phoneNumbers.isNotEmpty;
  bool get hasEmail => emails.isNotEmpty;
}

/// Lower case, letters and digits only (any script), words separated by single spaces.
String normalizeContactName(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
    .trim();
