import 'contact_models.dart';

final class ContactTagSummary {
  const ContactTagSummary(
      {required this.id, required this.name, this.friendCount = 0});
  factory ContactTagSummary.fromJson(Map<String, dynamic> json) =>
      ContactTagSummary(
          id: json['id'].toString(),
          name: json['name'].toString(),
          friendCount: (json['friend_count'] as num?)?.toInt() ?? 0);
  final String id;
  final String name;
  final int friendCount;
}

List<ContactTagSummary> sortContactTags(Iterable<ContactTagSummary> tags) =>
    tags.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
List<ContactSummary> contactsForTag(
        Iterable<ContactSummary> contacts, String tag) =>
    contacts.where((contact) => contact.tags.contains(tag)).toList()
      ..sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
List<String> mergeTag(List<String> tags, String tag) =>
    {...tags, tag}.toList()..sort();
List<String> removeTag(List<String> tags, String tag) =>
    tags.where((value) => value != tag).toList();
