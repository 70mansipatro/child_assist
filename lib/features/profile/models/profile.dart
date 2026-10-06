import '../../auth/models/user.dart';

/// The signed-in user's profile as returned by GET/PATCH /api/profile.
class Profile {
  const Profile({required this.id, required this.email, this.name, this.profileImageUrl});

  final String id;
  final String email;
  final String? name;

  /// Link to an externally hosted image, or null to show a placeholder.
  final String? profileImageUrl;

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      email: json['email'] as String,
      name: json['name'] as String?,
      profileImageUrl: json['profileImageUrl'] as String?,
    );
  }

  /// Name to show; falls back to the email if no name is set.
  String get displayName => (name != null && name!.isNotEmpty) ? name! : email;

  User toUser() => User(id: id, email: email, name: name);
}
