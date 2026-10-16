class UserProfile {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final String photoUrl;
  final DateTime? joinedAt;
  final String role;
  final String mode;
  final bool isAdmin;
  final String bio;
  final String gender;
  final double rating;
  final int followersCount;
  final int followingCount;

  UserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    this.photoUrl = '',
    this.joinedAt,
    this.role = 'student',
    this.mode = 'mostafhem',
    this.isAdmin = false,
    this.bio = '',
    this.gender = '',
    this.rating = 0,
    this.followersCount = 0,
    this.followingCount = 0,
  });

  bool get isMofahhem => mode == 'mofahhem';

  factory UserProfile.fromMap(String uid, Map<String, dynamic> map) {
    final rawMode = (map['mode'] ?? map['accountType'] ?? 'mostafhem').toString();
    return UserProfile(
      uid: uid,
      name: (map['name'] ?? map['fullName'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      phone: (map['phone'] ?? map['phoneNumber'] ?? '').toString(),
      photoUrl: (map['profilePictureUrl'] ?? map['photoUrl'] ?? map['imageUrl'] ?? '').toString(),
      joinedAt: map['joinedAt']?.toDate(),
      role: (map['role'] ?? 'student').toString(),
      mode: rawMode == 'mofahhem' ? 'mofahhem' : 'mostafhem',
      isAdmin: map['isAdmin'] == true || (map['role'] ?? '').toString() == 'admin',
      bio: (map['bio'] ?? '').toString(),
      gender: (map['gender'] ?? '').toString(),
      rating: (map['rating'] is num ? (map['rating'] as num).toDouble() : double.tryParse((map['rating'] ?? '0').toString()) ?? 0),
      followersCount: (map['followersCount'] is num ? (map['followersCount'] as num).toInt() : 0),
      followingCount: (map['followingCount'] is num ? (map['followingCount'] as num).toInt() : 0),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'email': email,
        'phone': phone,
        'photoUrl': photoUrl,
        'mode': mode,
      };
}
