import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What happened when the app tried to open WhatsApp or the share sheet.
enum HandoffResult {
  /// The other app opened with the message ready. Nothing is sent until the user sends it there.
  opened,

  /// WhatsApp (or sharing) isn't available on this device.
  unavailable,
}

/// Opens a confirmed message in WhatsApp, or the system share sheet, with the text prefilled.
///
/// This never sends anything: the user always taps Send in WhatsApp (or the app they pick), so
/// Child Assist can only ever say it was *opened*, never that it was sent. There is no WhatsApp
/// API key and no background sending.
abstract class MessageHandoff {
  Future<HandoffResult> openWhatsApp({required String phone, required String text});

  Future<HandoffResult> shareText(String text);

  /// Shares one document the user added ([reference] is its private platform reference), straight
  /// to the contact's WhatsApp chat when [toWhatsApp], otherwise through the share sheet.
  Future<HandoffResult> shareDocument({
    required String reference,
    required String mimeType,
    String? text,
    String? phone,
    bool toWhatsApp = false,
  });
}

/// The phone's WhatsApp and share sheet (Android). Other platforms report [HandoffResult.unavailable].
class NativeMessageHandoff implements MessageHandoff {
  const NativeMessageHandoff();

  static const _channel = MethodChannel('child_assist/share');

  @override
  Future<HandoffResult> openWhatsApp({required String phone, required String text}) =>
      _call('openWhatsApp', {'phone': phone, 'text': text});

  @override
  Future<HandoffResult> shareText(String text) => _call('shareText', {'text': text});

  @override
  Future<HandoffResult> shareDocument({
    required String reference,
    required String mimeType,
    String? text,
    String? phone,
    bool toWhatsApp = false,
  }) => _call('shareDocument', {
    'uri': reference,
    'mimeType': mimeType,
    'text': ?text,
    'phone': ?phone,
    'whatsApp': toWhatsApp,
  });

  Future<HandoffResult> _call(String method, Map<String, Object?> arguments) async {
    try {
      final result = await _channel.invokeMethod<String>(method, arguments);
      return result == 'opened' ? HandoffResult.opened : HandoffResult.unavailable;
    } on MissingPluginException {
      return HandoffResult.unavailable;
    } on PlatformException catch (e) {
      // Only the code: the message could contain a file name.
      debugPrint('Message handoff failed: ${e.code}');
      return HandoffResult.unavailable;
    }
  }
}
