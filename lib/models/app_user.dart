class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.qq,
    required this.sign,
    required this.level,
    this.passwordMarker,
  });

  const AppUser.guest()
    : id = 0,
      name = '点击登录',
      qq = '',
      sign = '',
      level = 0,
      passwordMarker = null;

  factory AppUser.fromJson(
    Map<String, dynamic> json, {
    String? retainedPasswordMarker,
  }) => AppUser(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    qq: json['qq'] as String? ?? '',
    sign: json['sign'] as String? ?? '',
    level: (json['level'] as num).toInt(),
    passwordMarker: json['pwd'] as String? ?? retainedPasswordMarker,
  );

  final int id;
  final String name;
  final String qq;
  final String sign;
  final int level;
  final String? passwordMarker;

  bool get isLoggedIn => id != 0;
  bool get hasPassword => passwordMarker != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'qq': qq,
    'sign': sign,
    'level': level,
    if (passwordMarker != null) 'pwd': passwordMarker,
  };
}
