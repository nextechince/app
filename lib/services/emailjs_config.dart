// lib/services/emailjs_config.dart
//
// EmailJS configuration.
// Get these values from https://dashboard.emailjs.com
//   - Service ID   → Email Services
//   - Template ID  → Email Templates
//   - Public Key   → Account → General
//
// ⚠️ Do NOT commit real keys to a public repo.
//    For production, load them from --dart-define or a .env file.

class EmailJSConfig {
  // ---- Replace these with your real values ----
  static const String serviceId  = 'service_omvsxhi';
  static const String templateId = 'template_pt0fc5c';
  static const String publicKey  = 'Z1wn-QOuVqPH8f8Ce';

  // EmailJS REST endpoint (you don't need to change this)
  static const String apiUrl =
      'https://api.emailjs.com/api/v1.0/email/send';
}
