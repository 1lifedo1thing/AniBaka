import 'dart:convert';
import 'package:baka/models/token_response.dart';
import 'package:http/http.dart' as http;

class AuthApi {
  AuthApi(this.client, this.baseUrl);
  final http.Client client;
  final String Function() baseUrl;
  Future<TokenResponse?> refresh(String token) async {
    final response = await client
        .post(
          Uri.parse('${baseUrl()}/user/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': token}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['code'] == 200 ? TokenResponse.fromJson(data) : null;
  }
}
