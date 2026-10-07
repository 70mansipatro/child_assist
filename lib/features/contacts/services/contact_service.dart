import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' show ContactProperty, FlutterContacts;

import '../models/contact_item.dart';
import 'contact_permission_service.dart';

/// Reads the phone's address book. Swappable so tests never touch real contacts.
abstract class ContactsSource {
  /// Every contact's name, numbers and emails, read now. Nothing else is fetched.
  Future<List<ContactItem>> readAll();
}

/// The phone's own contacts, through flutter_contacts (Android and iOS).
class DeviceContactsSource implements ContactsSource {
  const DeviceContactsSource();

  @override
  Future<List<ContactItem>> readAll() async {
    // Only phones and emails are requested; the display name and ID always come with them.
    final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone, ContactProperty.email});
    return [
      for (final c in contacts)
        if (c.id != null && (c.displayName?.trim().isNotEmpty ?? false))
          ContactItem(
            id: c.id!,
            displayName: c.displayName!.trim(),
            phoneNumbers: _unique([for (final p in c.phones) p.number], (n) => n.replaceAll(RegExp(r'[^\d+]'), '')),
            emails: _unique([for (final e in c.emails) e.address], (e) => e.toLowerCase()),
          ),
    ];
  }

  static List<String> _unique(List<String> values, String Function(String) key) {
    final seen = <String>{};
    return [
      for (final v in values.map((v) => v.trim()))
        if (v.isNotEmpty && seen.add(key(v))) v,
    ];
  }
}

enum ContactSearchStatus {
  /// The search ran; [ContactSearchResult.matches] may be empty.
  done,

  /// Contacts permission is not allowed; nothing was read.
  permissionDenied,

  /// Contacts permission is blocked; only the phone's Settings can change it.
  permissionBlocked,

  /// This device cannot provide contacts.
  unavailable,

  /// Reading the contacts failed.
  failed,
}

class ContactSearchResult {
  const ContactSearchResult(this.status, [this.matches = const []]);

  final ContactSearchStatus status;
  final List<ContactItem> matches;
}

/// Finds the user's contacts by name, entirely on the phone.
///
/// The OS Contacts permission is checked before every search and nothing is read without it.
/// Contacts are read on demand and not kept: there is no cache, sync or background scan, and
/// nothing about the address book is uploaded. Only the matches are returned to the caller.
class ContactService {
  ContactService({required ContactPermissionService permission, ContactsSource? source})
    : _permission = permission,
      _source = source ?? const DeviceContactsSource();

  final ContactPermissionService _permission;
  final ContactsSource _source;

  /// The most matches a search returns; more means the name is too vague to list usefully.
  static const maxMatches = 10;

  ContactPermissionService get permission => _permission;

  Future<ContactSearchResult> searchContacts(String query) async {
    final access = await _permission.check();
    switch (access) {
      case ContactAccess.denied:
        return const ContactSearchResult(ContactSearchStatus.permissionDenied);
      case ContactAccess.blocked:
        return const ContactSearchResult(ContactSearchStatus.permissionBlocked);
      case ContactAccess.unavailable:
        return const ContactSearchResult(ContactSearchStatus.unavailable);
      case ContactAccess.granted:
        break;
    }
    try {
      return ContactSearchResult(ContactSearchStatus.done, matchContacts(await _source.readAll(), query));
    } catch (e) {
      // Never the contact data itself, only that it failed.
      debugPrint('Contact search failed: ${e.runtimeType}');
      return const ContactSearchResult(ContactSearchStatus.failed);
    }
  }
}

/// The contacts whose name matches [query], best matches only, sorted by name.
///
/// Case, punctuation and spacing do not matter, and any script works. Matches come in tiers and
/// only the best non-empty tier is returned, so "Papa" finds the contact named exactly "Papa"
/// rather than also "Papaji":
///  1. the whole name ("mansi patro", or "MansiPatro" for "Mansi Patro");
///  2. every word of the query starts a word of the name ("Rah" → "Rahul Sharma");
///  3. the name contains the query ignoring spaces.
/// Several matches in the best tier are all returned: the caller must let the user choose.
List<ContactItem> matchContacts(List<ContactItem> contacts, String query) {
  // "Mansi's" → "Mansi".
  final q = normalizeContactName(query.replaceAll(RegExp(r"['’]s\b"), ''));
  if (q.isEmpty) return const [];
  final qWords = q.split(' ');
  final qCompact = q.replaceAll(' ', '');

  final tiers = <List<ContactItem>>[[], [], []];
  for (final contact in contacts) {
    final name = contact.normalizedName;
    if (name.isEmpty) continue;
    final compact = name.replaceAll(' ', '');
    if (name == q || compact == qCompact) {
      tiers[0].add(contact);
    } else if (_wordsPrefix(name.split(' '), qWords)) {
      tiers[1].add(contact);
    } else if (compact.contains(qCompact)) {
      tiers[2].add(contact);
    }
  }
  final best = tiers.firstWhere((t) => t.isNotEmpty, orElse: () => const []);
  final seen = <String>{};
  final unique = [
    for (final c in best)
      if (seen.add(c.id)) c,
  ]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  return unique.take(ContactService.maxMatches).toList();
}

/// Whether each query word starts a different word of the name, in any order.
bool _wordsPrefix(List<String> nameWords, List<String> queryWords) {
  final available = [...nameWords];
  for (final word in queryWords) {
    final index = available.indexWhere((n) => n.startsWith(word));
    if (index < 0) return false;
    available.removeAt(index);
  }
  return true;
}
