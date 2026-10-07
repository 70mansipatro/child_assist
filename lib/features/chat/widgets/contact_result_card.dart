import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/widgets.dart';
import '../../contacts/models/contact_item.dart';
import '../../contacts/services/contact_service.dart';
import '../models/chat_message.dart';

/// The answer to "Mansi ka number do": the contact is searched on this phone and shown here.
/// Nothing found is sent to the server or the AI. Several matches are listed for the user to
/// pick from; Child Assist never guesses.
class ContactLookupCard extends StatefulWidget {
  const ContactLookupCard({
    super.key,
    required this.query,
    required this.contactService,
    required this.onOpenPermissions,
    required this.onOpenSettings,
  });

  final ChatLookupQuery query;
  final ContactService contactService;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenSettings;

  @override
  State<ContactLookupCard> createState() => _ContactLookupCardState();
}

class _ContactLookupCardState extends State<ContactLookupCard> {
  late Future<ContactSearchResult> _search = _run();
  ContactItem? _selected;
  bool _dismissed = false;

  String get _name => widget.query.name ?? '';

  Future<ContactSearchResult> _run() => widget.contactService.searchContacts(_name);

  void _retry() => setState(() {
    _selected = null;
    _search = _run();
  });

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const InfoBanner(icon: Icons.block_rounded, message: Text("Okay, I didn't search your contacts."));
    }
    return FutureBuilder<ContactSearchResult>(
      future: _search,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        }
        final result = snapshot.data ?? const ContactSearchResult(ContactSearchStatus.failed);
        switch (result.status) {
          case ContactSearchStatus.permissionDenied || ContactSearchStatus.permissionBlocked:
            return ContactsPermissionCard(
              blocked: result.status == ContactSearchStatus.permissionBlocked,
              onOpenPermissions: widget.onOpenPermissions,
              onOpenSettings: widget.onOpenSettings,
              onCancel: () => setState(() => _dismissed = true),
              onRetry: _retry,
            );
          case ContactSearchStatus.unavailable || ContactSearchStatus.failed:
            return InfoBanner(
              tone: BannerTone.warning,
              icon: Icons.contacts_outlined,
              message: const Text("I couldn't read the contacts on this phone."),
              actions: [OutlinedButton(onPressed: _retry, child: const Text('Try again'))],
            );
          case ContactSearchStatus.done:
            break;
        }

        final matches = result.matches;
        if (matches.isEmpty) {
          return InfoBanner(
            icon: Icons.person_search_rounded,
            message: Text('I couldn\'t find a contact named "$_name" in your phone contacts.'),
          );
        }
        final chosen = _selected ?? (matches.length == 1 ? matches.single : null);
        if (chosen == null) {
          return ContactChoiceList(
            name: _name,
            contacts: matches,
            field: widget.query.field,
            onSelected: (c) => setState(() => _selected = c),
          );
        }
        return ContactDetailsCard(contact: chosen, field: widget.query.field);
      },
    );
  }
}

/// Explains why contacts can't be searched, with the way to fix it. Chat never shows the system
/// permission dialog itself.
class ContactsPermissionCard extends StatelessWidget {
  const ContactsPermissionCard({
    super.key,
    required this.blocked,
    required this.onOpenPermissions,
    required this.onOpenSettings,
    required this.onCancel,
    this.onRetry,
  });

  final bool blocked;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenSettings;
  final VoidCallback onCancel;

  /// Checks again, e.g. after the user allowed it.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      tone: BannerTone.warning,
      icon: Icons.lock_outline_rounded,
      title: blocked
          ? 'Contacts permission is blocked. Please enable it in your phone settings.'
          : 'I need Contacts permission to search your phone contacts.',
      message: const Text('Your contacts are searched only on this phone and never uploaded.'),
      actions: [
        OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
        if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Check again')),
        FilledButton(
          onPressed: blocked ? onOpenSettings : onOpenPermissions,
          child: Text(blocked ? 'Open Settings' : 'Open Permissions'),
        ),
      ],
    );
  }
}

/// "I found 2 contacts named Rahul. Which one do you mean?"
class ContactChoiceList extends StatelessWidget {
  const ContactChoiceList({
    super.key,
    required this.name,
    required this.contacts,
    required this.field,
    required this.onSelected,
  });

  final String name;
  final List<ContactItem> contacts;
  final ContactField field;
  final ValueChanged<ContactItem> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('I found ${contacts.length} contacts named $name.', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text('Which one do you mean?', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          for (final (i, contact) in contacts.indexed)
            ListTile(
              key: ValueKey('contact-choice-${contact.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(radius: 16, child: Text('${i + 1}')),
              title: Text(contact.displayName),
              subtitle: _hint(contact) == null ? null : Text(_hint(contact)!),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onSelected(contact),
            ),
        ],
      ),
    );
  }

  /// The detail that tells same-named contacts apart, as asked for.
  String? _hint(ContactItem c) => switch (field) {
    ContactField.email => c.emails.firstOrNull ?? c.phoneNumbers.firstOrNull,
    _ => c.phoneNumbers.firstOrNull ?? c.emails.firstOrNull,
  };
}

/// 👤 Mansi Patro / 📞 98XXXXXXXX / ✉️ mansi@example.com: only the details asked for, and a plain
/// "not saved" when the contact doesn't have them. Nothing is ever made up.
class ContactDetailsCard extends StatelessWidget {
  const ContactDetailsCard({super.key, required this.contact, required this.field});

  final ContactItem contact;
  final ContactField field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = contact.displayName;
    final showPhones = field != ContactField.email;
    final showEmails = field != ContactField.phone;
    final missing = <String>[
      if (field == ContactField.phone && !contact.hasPhone) "$name doesn't have a phone number saved in your contacts.",
      if (field == ContactField.email && !contact.hasEmail) "$name doesn't have an email address saved in your contacts.",
      if (field == ContactField.any && !contact.hasPhone && !contact.hasEmail)
        "$name doesn't have a phone number or email address saved in your contacts.",
    ];

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconBadge(icon: Icons.person_rounded, size: 34, iconSize: 18),
              const SizedBox(width: 12),
              Expanded(child: Text(name, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 6),
          if (showPhones)
            for (final phone in contact.phoneNumbers) _DetailRow(icon: Icons.phone_rounded, value: phone, label: 'number'),
          if (showEmails)
            for (final email in contact.emails) _DetailRow(icon: Icons.email_outlined, value: email, label: 'email'),
          for (final line in missing)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 8, 6),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: SelectableText(value, style: theme.textTheme.bodyLarge)),
        IconButton(
          tooltip: 'Copy $label',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.copy_rounded),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $label')));
            }
          },
        ),
      ],
    );
  }
}
