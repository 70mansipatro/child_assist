/// The safe, public view of a user returned by the backend.
class User {
  const User({required this.id, required this.email, this.name});

  final String id;
  final String email;
  final String? name;

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      email: json['email'] as String,
      name: json['name'] as String?,
    );
  }

  /// Name to greet the user with; falls back to the email if no name is set.
  String get displayName => (name != null && name!.isNotEmpty) ? name! : email;
}
