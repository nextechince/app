import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/settings_provider.dart';

const _languages = <Map<String, String>>[
  {'code': 'en', 'name': 'English', 'flag': '🇺🇸'},
  {'code': 'es', 'name': 'Español', 'flag': '🇪🇸'},
  {'code': 'fr', 'name': 'Français', 'flag': '🇫🇷'},
  {'code': 'de', 'name': 'Deutsch', 'flag': '🇩🇪'},
  {'code': 'it', 'name': 'Italiano', 'flag': '🇮🇹'},
  {'code': 'pt', 'name': 'Português', 'flag': '🇵🇹'},
  {'code': 'ru', 'name': 'Русский', 'flag': '🇷🇺'},
  {'code': 'zh', 'name': '中文', 'flag': '🇨🇳'},
  {'code': 'ja', 'name': '日本語', 'flag': '🇯🇵'},
  {'code': 'ko', 'name': '한국어', 'flag': '🇰🇷'},
  {'code': 'ar', 'name': 'العربية', 'flag': '🇸🇦'},
  {'code': 'hi', 'name': 'हिन्दी', 'flag': '🇮🇳'},
  {'code': 'tr', 'name': 'Türkçe', 'flag': '🇹🇷'},
  {'code': 'pl', 'name': 'Polski', 'flag': '🇵🇱'},
  {'code': 'nl', 'name': 'Nederlands', 'flag': '🇳🇱'},
  {'code': 'sv', 'name': 'Svenska', 'flag': '🇸🇪'},
  {'code': 'id', 'name': 'Bahasa Indonesia', 'flag': '🇮🇩'},
  {'code': 'th', 'name': 'ไทย', 'flag': '🇹🇭'},
  {'code': 'vi', 'name': 'Tiếng Việt', 'flag': '🇻🇳'},
  {'code': 'sw', 'name': 'Kiswahili', 'flag': '🇰🇪'},
];

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settingsProvider = Provider.of<SettingsProvider>(context);
    final currentLang = settingsProvider.language;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Language'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _languages.length,
        itemBuilder: (context, index) {
          final lang = _languages[index];
          final isSelected = currentLang == lang['code'];

          return ListTile(
            leading: Text(
              lang['flag']!,
              style: const TextStyle(fontSize: 24),
            ),
            title: Text(
              lang['name']!,
              style: TextStyle(
                fontSize: 15,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
              ),
            ),
            subtitle: Text(
              lang['code']!.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                color:
                    theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            trailing: isSelected
                ? Icon(Icons.check_circle,
                    color: theme.colorScheme.primary)
                : null,
            onTap: () async {
              await settingsProvider.setLanguage(lang['code']!);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content:
                      Text('Language changed to ${lang['name']}'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
