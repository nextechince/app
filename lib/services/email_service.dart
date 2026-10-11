import 'dart:convert';
import 'package:http/http.dart' as http;
import 'emailjs_config.dart';

class EmailService {
  /// Sends an email via EmailJS.
  /// [templateParams] keys must match your EmailJS template variables,
  /// e.g. {'to_name': 'John', 'to_email': 'john@x.com', 'message': 'Hi'}
  static Future<bool> send({
    required Map<String, dynamic> templateParams,
  }) async {
    try {
      final res = await http.post(
        Uri.parse(EmailJSConfig.apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'service_id':  EmailJSConfig.serviceId,
          'template_id': EmailJSConfig.templateId,
          'user_id':     EmailJSConfig.publicKey,
          'template_params': templateParams,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
