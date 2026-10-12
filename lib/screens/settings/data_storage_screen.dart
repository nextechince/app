import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/settings_provider.dart';

class DataStorageScreen extends StatelessWidget {
  const DataStorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settingsProvider = Provider.of<SettingsProvider>(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Storage and Data'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionTitle(theme, 'MEDIA AUTO-DOWNLOAD'),
          _switchTile(
            theme,
            title: 'Photos',
            subtitle: 'Auto-download photos',
            value: settingsProvider.autoDownloadMedia,
            onChanged: (v) =>
                settingsProvider.setAutoDownloadMedia(v),
          ),
          _switchTile(
            theme,
            title: 'Documents',
            subtitle: 'Auto-download documents',
            value: settingsProvider.autoDownloadDocuments,
            onChanged: (v) =>
                settingsProvider.setAutoDownloadDocuments(v),
          ),

          Divider(height: 0.5, color: theme.dividerColor),

          _sectionTitle(theme, 'STORAGE USAGE'),
          _listTile(
            theme,
            icon: Icons.folder_outlined,
            title: 'Manage Storage',
            subtitle: 'View and free up space',
            onTap: () {},
          ),

          Divider(height: 0.5, color: theme.dividerColor),

          _sectionTitle(theme, 'GALLERY'),
          _switchTile(
            theme,
            title: 'Save to Gallery',
            subtitle: 'Save media to device gallery',
            value: settingsProvider.saveToGallery,
            onChanged: (v) => settingsProvider.setSaveToGallery(v),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _switchTile(
    ThemeData theme, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurface.withOpacity(0.55),
        ),
      ),
      value: value,
      onChanged: onChanged,
      activeColor: theme.colorScheme.primary,
    );
  }

  Widget _listTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: theme.colorScheme.onSurface.withOpacity(0.75),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurface.withOpacity(0.55),
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withOpacity(0.35),
        size: 20,
      ),
      onTap: onTap,
    );
  }
}
