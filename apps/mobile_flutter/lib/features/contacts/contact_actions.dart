import 'contact_models.dart';

/// Navigation actions owned by the signed-in AppHome and its canonical DM controller.
final class ContactActions {
  const ContactActions({this.onMessage, this.onVoice, this.onVideo});
  final Future<void> Function(ContactDetails)? onMessage;
  final Future<void> Function(ContactDetails)? onVoice;
  final Future<void> Function(ContactDetails)? onVideo;
}
