import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../contacts/models/contact_item.dart';
import '../../contacts/services/contact_service.dart';
import '../models/chat_message.dart';
import 'contact_result_card.dart';
import 'tool_result_cards.dart';

/// Asks before anything leaves the app: an email, or a WhatsApp message.
///
/// People named in the request are found on this phone first and the user picks the right
/// contact and number (only those are sent to the server). For "send A's number to B" that is
/// done twice, separately: first A, the contact whose number is shared, then B, the recipient.
/// The card then shows exactly what will be sent, as the server stored it: recipient, subject, any
/// sensitive data and the message. Nothing is sent unless the user taps Confirm, and a WhatsApp
/// message is only ever opened in WhatsApp for the user to send.
class ActionConfirmationCard extends StatefulWidget {
  const ActionConfirmationCard({super.key, required this.action, required this.results});

  final PendingAction action;
  final ChatResultContext results;

  @override
  State<ActionConfirmationCard> createState() => _ActionConfirmationCardState();
}

class _ActionConfirmationCardState extends State<ActionConfirmationCard> {
  bool _showFullMessage = false;

  PendingAction get _action => widget.action;

  void _cancel() => widget.results.onCancelAction(_action.id);

  @override
  Widget build(BuildContext context) {
    final action = _action;
    switch (action.state) {
      case PendingActionState.done:
        return _outcome(BannerTone.success, Icons.check_circle_outline_rounded);
      case PendingActionState.failed:
        return _outcome(BannerTone.danger, Icons.error_outline_rounded);
      case PendingActionState.cancelled:
        return _outcome(BannerTone.info, Icons.block_rounded);
      case PendingActionState.whatsAppUnavailable:
        return InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.chat_bubble_outline_rounded,
          title: "WhatsApp isn't available on this device.",
          message: Text(
            action.isDocumentShare
                ? 'You can share the document another way instead. Nothing has been shared.'
                : 'You can share the message another way instead. Nothing has been sent.',
          ),
          actions: [
            OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
            FilledButton(onPressed: () => widget.results.onShareInstead(action.id), child: const Text('Share instead')),
          ],
        );
      case PendingActionState.awaiting ||
          PendingActionState.confirming ||
          PendingActionState.handingOff ||
          PendingActionState.cancelling:
        break;
    }

    final theme = Theme.of(context);
    return AppCard(
      key: ValueKey('action-${action.id}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: AppColors.warning.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBadge(
                icon: action.isWhatsApp ? Icons.chat_rounded : Icons.outgoing_mail,
                gradient: action.isWhatsApp ? AppGradients.location : AppGradients.brand,
                size: 34,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(action.summary, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 10),
          ..._body(context),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final action = _action;
    final theme = Theme.of(context);
    // A document share: first the document, among the user's own documents on this phone.
    if (action.isOpen && action.needsDocument) {
      return [
        Text('Document', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        ActionDocumentPicker(
          key: ValueKey('document-${action.id}'),
          query: action.documentQuery,
          results: widget.results,
          onCancel: _cancel,
          onPick: (document) => widget.results.onChooseDocument(action.id, document),
        ),
      ];
    }
    if (action.isOpen && action.needsSharedContact) {
      final query = action.sharedContactQuery ?? '';
      return [
        Text('Whose number to share', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        ContactAddressPicker(
          key: ValueKey('shared-${action.id}'),
          query: query,
          field: ContactField.phone,
          results: widget.results,
          onCancel: _cancel,
          missingMessage: (c) => "${c.displayName} doesn't have a phone number saved in your contacts.",
          onPick: (phone, name) => widget.results.onChooseSharedContact(action.id, name: name, phone: phone),
        ),
      ];
    }
    if (action.isOpen && action.needsRecipient && action.contactQuery != null) {
      final email = action.recipientField == ContactField.email;
      return [
        if (action.isDocumentShare) ...[
          _Field(label: 'Document', value: _documentLabel(action)),
          Text('Recipient', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
        ],
        if (action.isContactShare) ...[
          Text('Send to', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
        ],
        ContactAddressPicker(
          key: ValueKey('recipient-${action.id}'),
          query: action.contactQuery!,
          field: action.recipientField,
          results: widget.results,
          onCancel: _cancel,
          allowManualEmail: email,
          missingMessage: (c) => email
              ? '${c.displayName} ke contact me email saved nahi hai. Kis email address par bheju?'
              : "This contact doesn't have a phone number saved.",
          onPick: (address, name) => widget.results.onChooseRecipient(action.id, address: address, name: name),
        ),
      ];
    }
    if (action.isOpen && action.needsRecipient) {
      return [
        ManualEmailEntry(
          prompt: 'Kis email address par bheju?',
          onCancel: _cancel,
          onSubmit: (address) => widget.results.onChooseRecipient(action.id, address: address),
        ),
      ];
    }
    return _details(context);
  }

  Widget _outcome(BannerTone tone, IconData icon) => InfoBanner(
    tone: tone,
    icon: icon,
    title: _action.summary,
    message: Text(_action.resultMessage ?? ''),
  );

  // -------------------------------------------------------------------------------------------
  // Exactly what will be sent, then Cancel / Confirm.

  List<Widget> _details(BuildContext context) {
    final theme = Theme.of(context);
    final action = _action;
    final busy = !action.isOpen;
    final name = action.recipientName;
    final address = action.recipientAddress ?? '';
    final to = name == null || name == address
        ? address
        : action.isWhatsApp
            ? '$name\n$address'
            : '$name <$address>';
    final message = action.message;
    final long = message != null && (message.length > 400 || '\n'.allMatches(message).length > 8);

    final document = action.isDocumentShare;
    return [
      if (document) ...[
        _Field(label: 'Document', value: _documentLabel(action), highlight: true),
        _Field(label: 'Recipient', value: to),
        const _Field(label: 'Method', value: 'WhatsApp'),
      ] else
        _Field(label: 'To', value: to),
      if (action.subject != null) _Field(label: 'Subject', value: action.subject!),
      if (action.dataSummary != null && !document)
        _Field(label: action.isWhatsApp ? 'Information' : 'Data', value: action.dataSummary!, highlight: true),
      if (message != null && message.isNotEmpty) ...[
        _Field(label: 'Message', value: message, maxLines: long && !_showFullMessage ? 8 : null),
        if (long)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showFullMessage = !_showFullMessage),
              child: Text(_showFullMessage ? 'Show less' : 'Show the whole message'),
            ),
          ),
      ],
      const SizedBox(height: 4),
      Text(
        switch (action.state) {
          PendingActionState.confirming => action.isWhatsApp ? 'Getting WhatsApp ready...' : 'Sending...',
          PendingActionState.handingOff => 'Opening WhatsApp...',
          PendingActionState.cancelling => 'Cancelling...',
          _ when document => 'WhatsApp will open with this document ready. You tap Send in WhatsApp.',
          _ =>
            action.isWhatsApp
                ? 'WhatsApp will open with this ready. You send it from WhatsApp.'
                : 'Nothing is sent until you confirm.',
        },
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 10),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(onPressed: busy ? null : _cancel, child: const Text('Cancel')),
          FilledButton(
            onPressed: busy ? null : () => widget.results.onConfirmAction(action.id),
            child: action.state == PendingActionState.confirming || action.state == PendingActionState.handingOff
                ? ButtonSpinner(size: 16, color: theme.colorScheme.onPrimary)
                : Text(document ? 'Confirm' : action.isWhatsApp ? 'Continue to WhatsApp' : 'Confirm & Send'),
          ),
        ],
      ),
    ];
  }

  /// "Python_Project.pdf (PDF)", as the server recorded the document the user picked.
  static String _documentLabel(PendingAction action) {
    final name = action.documentName ?? action.documentQuery ?? 'Document';
    return action.documentType == null ? name : '$name (${action.documentType})';
  }
}

/// Finds a contact named [query] on this phone and lets the user pick it and one of its phone
/// numbers or emails. Several contacts or several numbers are always listed for the user to
/// choose; only a single contact with a single address is taken without asking (the user still
/// confirms the result). [onPick] receives the picked address and the contact's name, and returns
/// an error to show, or null on success. Nothing is guessed and nothing else leaves the phone.
class ContactAddressPicker extends StatefulWidget {
  const ContactAddressPicker({
    super.key,
    required this.query,
    required this.field,
    required this.results,
    required this.onPick,
    required this.onCancel,
    required this.missingMessage,
    this.allowManualEmail = false,
  });

  final String query;

  /// Pick a phone number, or an email address.
  final ContactField field;
  final ChatResultContext results;
  final Future<String?> Function(String address, String name) onPick;
  final VoidCallback onCancel;

  /// What to say when the picked contact has no address of [field].
  final String Function(ContactItem contact) missingMessage;

  /// Lets the user type an email address when the contact has none (or isn't found).
  final bool allowManualEmail;

  @override
  State<ContactAddressPicker> createState() => _ContactAddressPickerState();
}

class _ContactAddressPickerState extends State<ContactAddressPicker> {
  late Future<ContactSearchResult> _search = _run();
  ContactItem? _contact;
  bool _autoPicked = false;
  bool _submitting = false;
  String? _error;

  bool get _email => widget.field == ContactField.email;

  Future<ContactSearchResult> _run() => widget.results.contactService.searchContacts(widget.query);

  void _searchAgain() => setState(() {
    _contact = null;
    _autoPicked = false;
    _search = _run();
  });

  Future<void> _pick(String address, String name) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onPick(address.trim(), name);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ContactSearchResult>(
      future: _search,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator());
        }
        final result = snapshot.data ?? const ContactSearchResult(ContactSearchStatus.failed);
        switch (result.status) {
          case ContactSearchStatus.permissionDenied || ContactSearchStatus.permissionBlocked:
            return ContactsPermissionCard(
              blocked: result.status == ContactSearchStatus.permissionBlocked,
              onOpenPermissions: widget.results.onOpenPermissions,
              onOpenSettings: widget.results.onOpenSettings,
              onCancel: widget.onCancel,
              onRetry: _searchAgain,
            );
          case ContactSearchStatus.unavailable || ContactSearchStatus.failed:
            return _notFound(context, "I couldn't read the contacts on this phone.");
          case ContactSearchStatus.done:
            break;
        }

        final matches = result.matches;
        if (matches.isEmpty) return _notFound(context, 'I couldn\'t find "${widget.query}" in your contacts.');
        final contact = _contact ?? (matches.length == 1 ? matches.single : null);
        if (contact == null) {
          return ContactChoiceList(
            name: widget.query,
            contacts: matches,
            field: widget.field,
            onSelected: (c) => setState(() => _contact = c),
          );
        }
        return _addresses(context, contact);
      },
    );
  }

  Widget _addresses(BuildContext context, ContactItem contact) {
    final theme = Theme.of(context);
    final addresses = _email ? contact.emails : contact.phoneNumbers;
    if (addresses.isEmpty) {
      return widget.allowManualEmail
          ? ManualEmailEntry(
              prompt: widget.missingMessage(contact),
              onCancel: widget.onCancel,
              onSubmit: (address) => widget.onPick(address, contact.displayName),
            )
          : _cancelOnly(context, widget.missingMessage(contact));
    }
    if (addresses.length == 1) {
      // One contact with one address: nothing to choose. The user still confirms it next.
      if (!_autoPicked) {
        _autoPicked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pick(addresses.single, contact.displayName);
        });
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error == null) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          ..._errorAndCancel(context),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _email ? 'Which email address for ${contact.displayName}?' : 'Select phone number for ${contact.displayName}',
          style: theme.textTheme.bodyMedium,
        ),
        for (final (i, address) in addresses.indexed)
          ListTile(
            key: ValueKey('address-${contact.id}-$i'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(_email ? Icons.email_outlined : Icons.phone_rounded),
            title: Text(address),
            subtitle: _email || contact.phoneLabel(i) == null ? null : Text(contact.phoneLabel(i)!),
            enabled: !_submitting,
            onTap: () => _pick(address, contact.displayName),
          ),
        ..._errorAndCancel(context),
      ],
    );
  }

  Widget _notFound(BuildContext context, String message) {
    if (widget.allowManualEmail) {
      return ManualEmailEntry(
        prompt: '$message Kis email address par bheju?',
        onCancel: widget.onCancel,
        onSubmit: (address) => widget.onPick(address, widget.query),
      );
    }
    return _cancelOnly(context, message);
  }

  Widget _cancelOnly(BuildContext context, String message) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(message, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(onPressed: widget.onCancel, child: const Text('Cancel')),
      ),
    ],
  );

  List<Widget> _errorAndCancel(BuildContext context) => [
    if (_error != null) ...[
      Text(_error!, style: TextStyle(color: AppColors.danger)),
      const SizedBox(height: 6),
    ],
    Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton(onPressed: _submitting ? null : widget.onCancel, child: const Text('Cancel')),
    ),
  ];
}

/// Asks for an email address. Exactly what the user types is used (the server checks it); it is
/// then shown for confirmation like any other recipient.
class ManualEmailEntry extends StatefulWidget {
  const ManualEmailEntry({super.key, required this.prompt, required this.onSubmit, required this.onCancel});

  final String prompt;

  /// Returns an error to show, or null on success.
  final Future<String?> Function(String address) onSubmit;
  final VoidCallback onCancel;

  @override
  State<ManualEmailEntry> createState() => _ManualEmailEntryState();
}

class _ManualEmailEntryState extends State<ManualEmailEntry> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final address = _controller.text.trim();
    if (address.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onSubmit(address);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.prompt, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          enabled: !_submitting,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Email address', prefixIcon: Icon(Icons.alternate_email)),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: TextStyle(color: AppColors.danger)),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(onPressed: _submitting ? null : widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => FilledButton(
                onPressed: _submitting || _controller.text.trim().isEmpty ? null : _submit,
                child: const Text('Use this address'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.highlight = false, this.maxLines});

  final String label;
  final String value;
  final bool highlight;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      value,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.fade,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: highlight ? FontWeight.w600 : null),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 2),
          if (highlight)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: text,
            )
          else
            text,
        ],
      ),
    );
  }
}
