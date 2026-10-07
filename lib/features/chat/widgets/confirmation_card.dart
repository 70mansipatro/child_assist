import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../contacts/models/contact_item.dart';
import '../../contacts/services/contact_service.dart';
import '../../documents/services/document_service.dart';
import '../models/chat_message.dart';
import 'contact_result_card.dart';
import 'tool_result_cards.dart';

/// Asks before anything leaves the app: an email, or a WhatsApp message.
///
/// When the recipient was given by name, the contact is found on this phone first and the user
/// picks the right one (only that one address is sent to the server). The card then shows exactly
/// what will be sent: recipient, subject, any sensitive data and the message, all as the server
/// stored it. Nothing is sent unless the user taps Confirm, and a WhatsApp message is only ever
/// opened in WhatsApp for the user to send.
class ActionConfirmationCard extends StatefulWidget {
  const ActionConfirmationCard({super.key, required this.action, required this.results});

  final PendingAction action;
  final ChatResultContext results;

  @override
  State<ActionConfirmationCard> createState() => _ActionConfirmationCardState();
}

class _ActionConfirmationCardState extends State<ActionConfirmationCard> {
  Future<ContactSearchResult>? _contacts;
  ContactItem? _contact;
  bool _autoChosen = false;
  bool _submitting = false;
  String? _error;
  final _manual = TextEditingController();

  Future<List<DocumentItem>>? _documents;
  DocumentItem? _document;
  bool _showFullMessage = false;

  PendingAction get _action => widget.action;
  String get _who => _action.contactQuery ?? _action.recipientName ?? 'this contact';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  void _prepare() {
    if (_action.isOpen && _action.needsRecipient && _action.contactQuery != null) {
      _contacts = widget.results.contactService.searchContacts(_action.contactQuery!);
    }
    if (_action.isOpen && _action.isDocumentShare) {
      _documents = widget.results.documentService.list().then(
        (all) => matchDocuments(all, text: _action.documentQuery, limit: 5),
      );
    }
  }

  void _searchAgain() => setState(() {
    _contact = null;
    _autoChosen = false;
    _contacts = widget.results.contactService.searchContacts(_action.contactQuery ?? '');
  });

  Future<void> _choose(String address, String? name) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.results.onChooseRecipient(_action.id, address: address.trim(), name: name);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

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
          message: const Text('You can share the message another way instead. Nothing has been sent.'),
          actions: [
            OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
            FilledButton(onPressed: () => widget.results.onShareInstead(action.id), child: const Text('Share instead')),
          ],
        );
      case PendingActionState.awaiting ||
          PendingActionState.confirming ||
          PendingActionState.cancelling ||
          PendingActionState.handingOff:
        break;
    }

    final theme = Theme.of(context);
    final resolving = action.isOpen && action.needsRecipient;
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
          if (resolving) _recipientStep(context) else ..._details(context),
        ],
      ),
    );
  }

  Widget _outcome(BannerTone tone, IconData icon) => InfoBanner(
    tone: tone,
    icon: icon,
    title: _action.summary,
    message: Text(_action.resultMessage ?? ''),
  );

  // -------------------------------------------------------------------------------------------
  // Step 1: find the contact on this phone and pick the address.

  Widget _recipientStep(BuildContext context) {
    final search = _contacts;
    if (search == null) return _manualEntry(context, prompt: 'Kis email address par bheju?');
    return FutureBuilder<ContactSearchResult>(
      future: search,
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
              onCancel: _cancel,
              onRetry: _searchAgain,
            );
          case ContactSearchStatus.unavailable || ContactSearchStatus.failed:
            return _notFound(context, "I couldn't read the contacts on this phone.");
          case ContactSearchStatus.done:
            break;
        }

        final matches = result.matches;
        if (matches.isEmpty) return _notFound(context, 'I couldn\'t find "$_who" in your contacts.');
        final contact = _contact ?? (matches.length == 1 ? matches.single : null);
        if (contact == null) {
          return ContactChoiceList(
            name: _who,
            contacts: matches,
            field: _action.recipientField,
            onSelected: (c) => setState(() => _contact = c),
          );
        }
        return _addressStep(context, contact);
      },
    );
  }

  Widget _addressStep(BuildContext context, ContactItem contact) {
    final theme = Theme.of(context);
    final email = _action.recipientField == ContactField.email;
    final addresses = email ? contact.emails : contact.phoneNumbers;
    if (addresses.isEmpty) {
      return email
          ? _manualEntry(
              context,
              prompt: '${contact.displayName} ke contact me email saved nahi hai. Kis email address par bheju?',
              name: contact.displayName,
            )
          : _cancelOnly(context, "This contact doesn't have a phone number saved.");
    }
    if (addresses.length == 1) {
      // One contact with one address: nothing to choose. The user still confirms it next.
      if (!_autoChosen) {
        _autoChosen = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _choose(addresses.single, contact.displayName);
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
          email ? 'Which email address for ${contact.displayName}?' : 'Which number for ${contact.displayName}?',
          style: theme.textTheme.bodyMedium,
        ),
        for (final address in addresses)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(email ? Icons.email_outlined : Icons.phone_rounded),
            title: Text(address),
            enabled: !_submitting,
            onTap: () => _choose(address, contact.displayName),
          ),
        ..._errorAndCancel(context),
      ],
    );
  }

  Widget _notFound(BuildContext context, String message) {
    if (_action.recipientField == ContactField.email) {
      return _manualEntry(context, prompt: '$message Kis email address par bheju?');
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
        child: OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
      ),
    ],
  );

  /// Asks for an email address. Exactly what the user types is used (the server checks it); it
  /// is then shown for confirmation like any other recipient.
  Widget _manualEntry(BuildContext context, {required String prompt, String? name}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(prompt, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _manual,
          enabled: !_submitting,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Email address', prefixIcon: Icon(Icons.alternate_email)),
          onSubmitted: (value) => value.trim().isEmpty ? null : _choose(value, name ?? _action.contactQuery),
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
            OutlinedButton(onPressed: _submitting ? null : _cancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: _manual,
              builder: (context, _) => FilledButton(
                onPressed: _submitting || _manual.text.trim().isEmpty
                    ? null
                    : () => _choose(_manual.text, name ?? _action.contactQuery),
                child: const Text('Use this address'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _errorAndCancel(BuildContext context) => [
    if (_error != null) ...[
      Text(_error!, style: TextStyle(color: AppColors.danger)),
      const SizedBox(height: 6),
    ],
    Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton(onPressed: _submitting ? null : _cancel, child: const Text('Cancel')),
    ),
  ];

  // -------------------------------------------------------------------------------------------
  // Step 2: exactly what will be sent, then Cancel / Confirm.

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

    return [
      _Field(label: 'To', value: to),
      if (action.subject != null) _Field(label: 'Subject', value: action.subject!),
      if (action.dataSummary != null && !action.isDocumentShare)
        _Field(label: action.isWhatsApp ? 'Information' : 'Data', value: action.dataSummary!, highlight: true),
      if (action.isDocumentShare) _documentField(context),
      if (message != null && message.isNotEmpty) ...[
        _Field(
          label: 'Message',
          value: message,
          maxLines: long && !_showFullMessage ? 8 : null,
        ),
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
            onPressed: busy || (action.isDocumentShare && _document == null)
                ? null
                : () => widget.results.onConfirmAction(action.id, _document),
            child: action.state == PendingActionState.confirming || action.state == PendingActionState.handingOff
                ? ButtonSpinner(size: 16, color: theme.colorScheme.onPrimary)
                : Text(action.isWhatsApp ? 'Continue to WhatsApp' : 'Confirm & Send'),
          ),
        ],
      ),
    ];
  }

  /// The document to share, found among the documents the user added on this phone.
  Widget _documentField(BuildContext context) {
    final documents = _documents;
    if (documents == null) return _Field(label: 'Document', value: _action.documentQuery ?? 'Document');
    return FutureBuilder<List<DocumentItem>>(
      future: documents,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
        final matches = snapshot.data ?? const <DocumentItem>[];
        if (matches.isEmpty) {
          return _Field(
            label: 'Document',
            value: 'No document matching "${_action.documentQuery}" on this phone. Add it in Documents first.',
          );
        }
        if (matches.length == 1 && _document == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _document == null) setState(() => _document = matches.single);
          });
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Document', style: Theme.of(context).textTheme.labelMedium),
            RadioGroup<String>(
              groupValue: _document?.id,
              onChanged: _action.isOpen
                  ? (id) => setState(() => _document = matches.firstWhere((d) => d.id == id))
                  : (_) {},
              child: Column(
                children: [
                  for (final doc in matches)
                    RadioListTile<String>(
                      value: doc.id,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(doc.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(doc.type.label),
                    ),
                ],
              ),
            ),
          ],
        );
      },
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
