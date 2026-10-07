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
    this.phoneLabels = const [],
    this.emails = const [],
  });

  /// The platform's local contact ID. Never sent anywhere.
  final String id;
  final String displayName;
  final List<String> phoneNumbers;

  /// The label of each of [phoneNumbers] in the same order ("Mobile", "Home", a custom label),
  /// or empty when unknown.
  final List<String> phoneLabels;
  final List<String> emails;

  /// The label saved for the phone number at [index], if any.
  String? phoneLabel(int index) =>
      index < phoneLabels.length && phoneLabels[index].trim().isNotEmpty ? phoneLabels[index] : null;

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
