import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../providers/settings_provider.dart';

class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  String _selectedRingtone = 'default';
  final AudioPlayer _previewPlayer = AudioPlayer();
  bool _isPlaying = false;

  // System notification sounds, loaded from device
  List<Map<String, String>> _systemSounds = [];
  bool _loadingSystemSounds = false;

  final List<Map<String, String>> _builtinRingtones = [
    {
      'id': 'default',
      'name': 'Luma Default',
      'file': 'assets/audio/ringtone_ambition.mp3'
    },
    {
      'id': 'phonk',
      'name': 'Phonk Vibes',
      'file': 'assets/audio/ringtone_phonk.mp3'
    },
    {
      'id': 'fadded',
      'name': 'Faded Phone',
      'file': 'assets/audio/ringtone_fadded.mp3'
    },
    {
      'id': 'pop',
      'name': 'Pop',
      'file': 'assets/audio/ringtone_pop.mp3'
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadRingtone();
  }

  Future<void> _loadRingtone() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _selectedRingtone = prefs.getString('call_ringtone') ?? 'default';
    });
  }

  Future<void> _setRingtone(String ringtoneId, {String? systemUri}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('call_ringtone', ringtoneId);
    if (systemUri != null) {
      await prefs.setString('call_ringtone_uri', systemUri);
    } else {
      await prefs.remove('call_ringtone_uri');
    }
    if (!mounted) return;
    setState(() => _selectedRingtone = ringtoneId);
  }

  Future<void> _previewRingtone(String filePath) async {
    if (_isPlaying) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    try {
      await _previewPlayer.setAudioSource(AudioSource.asset(filePath));
      await _previewPlayer.play();
      if (mounted) setState(() => _isPlaying = true);

      _previewPlayer.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _isPlaying = false);
        }
      });
    } catch (e) {
      debugPrint('Preview error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ringtone file not found.')),
      );
    }
  }

  Future<void> _requestNotificationPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      criticalAlert: true,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          settings.authorizationStatus == AuthorizationStatus.authorized
              ? 'Notifications enabled'
              : 'Notifications permission denied. Enable in settings.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settingsProvider = Provider.of<SettingsProvider>(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionTitle(theme, 'MESSAGE NOTIFICATIONS'),

          _toggleTile(
            theme,
            icon: Icons.message_outlined,
            title: 'Message Tones',
            subtitle: 'Play sound for new messages',
            value: settingsProvider.messageTones,
            onChanged: (v) => settingsProvider.setMessageTones(v),
          ),
          _toggleTile(
            theme,
            icon: Icons.group_outlined,
            title: 'Group Notifications',
            subtitle: 'Notifications for group messages',
            value: settingsProvider.groupNotifications,
            onChanged: (v) => settingsProvider.setGroupNotifications(v),
          ),
          _toggleTile(
            theme,
            icon: Icons.campaign_outlined,
            title: 'Channel Notifications',
            subtitle: 'Notifications for channel updates',
            value: settingsProvider.channelNotifications,
            onChanged: (v) =>
                settingsProvider.setChannelNotifications(v),
          ),

          Divider(height: 0.5, color: theme.dividerColor),

          _sectionTitle(theme, 'CALL NOTIFICATIONS'),
          _toggleTile(
            theme,
            icon: Icons.call_outlined,
            title: 'Voice & Video Calls',
            subtitle: 'Notifications for incoming calls',
            value: settingsProvider.voiceVideoCalls,
            onChanged: (v) => settingsProvider.setVoiceVideoCalls(v),
          ),
          _ringtoneTile(theme),

          Divider(height: 0.5, color: theme.dividerColor),

          _sectionTitle(theme, 'IN-APP NOTIFICATIONS'),
          _toggleTile(
            theme,
            icon: Icons.volume_up_outlined,
            title: 'In-App Sounds',
            subtitle: 'Play sounds while using the app',
            value: settingsProvider.inAppSounds,
            onChanged: (v) => settingsProvider.setInAppSounds(v),
          ),
          _toggleTile(
            theme,
            icon: Icons.vibration_outlined,
            title: 'In-App Vibrate',
            subtitle: 'Vibrate while using the app',
            value: settingsProvider.inAppVibrate,
            onChanged: (v) => settingsProvider.setInAppVibrate(v),
          ),
          _toggleTile(
            theme,
            icon: Icons.preview_outlined,
            title: 'Show Preview',
            subtitle: 'Show message preview in notifications',
            value: settingsProvider.showPreview,
            onChanged: (v) => settingsProvider.setShowPreview(v),
          ),

          Divider(height: 0.5, color: theme.dividerColor),

          ListTile(
            leading: Icon(
              Icons.settings_applications_outlined,
              color: theme.colorScheme.onSurface.withOpacity(0.75),
            ),
            title: const Text(
              'System Notification Settings',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              'Open device notification settings',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.55),
                fontSize: 13,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurface.withOpacity(0.35),
              size: 20,
            ),
            onTap: _requestNotificationPermission,
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RINGTONE TILE
  // ═══════════════════════════════════════════════════════════════════════
  Widget _ringtoneTile(ThemeData theme) {
    final selectedName = _builtinRingtones.firstWhere(
      (r) => r['id'] == _selectedRingtone,
      orElse: () => {'name': 'System Default'},
    )['name'];

    return ListTile(
      leading: Icon(
        Icons.music_note_outlined,
        color: theme.colorScheme.onSurface.withOpacity(0.75),
      ),
      title: const Text(
        'Call Ringtone',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        selectedName ?? 'System Default',
        style: TextStyle(
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withOpacity(0.35),
        size: 20,
      ),
      onTap: () => _showRingtonePicker(context, theme),
    );
  }

  void _showRingtonePicker(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(16),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    'Call Ringtone',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose a sound for incoming calls',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Luma built-in ringtones ──
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'LUMA SOUNDS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.55),
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                  ..._builtinRingtones.map((ringtone) {
                    final isSelected =
                        _selectedRingtone == ringtone['id'];
                    return _ringtoneOption(
                      theme,
                      ringtone,
                      isSelected,
                      () {
                        _setRingtone(ringtone['id']!);
                        setModalState(() {});
                      },
                    );
                  }),

                  const SizedBox(height: 12),

                  // ── System sounds section ──
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          'DEVICE SOUNDS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.55),
                            letterSpacing: 0.6,
                          ),
                        ),
                        const Spacer(),
                        if (_loadingSystemSounds)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                        else
                          TextButton(
                            onPressed: () => _loadSystemSounds(
                                setModalState),
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  theme.colorScheme.primary,
                              textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                            child: Text(
                              _systemSounds.isEmpty ? 'Load' : 'Reload',
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_systemSounds.isEmpty && !_loadingSystemSounds)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Tap "Load" to see your device\'s notification sounds.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5),
                        ),
                      ),
                    )
                  else
                    ..._systemSounds.map((sound) {
                      final isSelected =
                          _selectedRingtone == sound['id'];
                      return _ringtoneOption(
                        theme,
                        sound,
                        isSelected,
                        () {
                          _setRingtone(
                            sound['id']!,
                            systemUri: sound['uri'],
                          );
                          setModalState(() {});
                        },
                      );
                    }),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _ringtoneOption(
    ThemeData theme,
    Map<String, String> ringtone,
    bool isSelected,
    VoidCallback onSelect,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.primary.withOpacity(0.08)
            : theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary.withOpacity(0.3)
              : Colors.transparent,
        ),
      ),
      child: ListTile(
        leading: Icon(
          isSelected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withOpacity(0.4),
        ),
        title: Text(
          ringtone['name'] ?? 'Unknown',
          style: TextStyle(
            fontWeight:
                isSelected ? FontWeight.w600 : FontWeight.w400,
            fontSize: 15,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ringtone['file'] != null)
              IconButton(
                icon: Icon(
                  _isPlaying && isSelected
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  color: theme.colorScheme.onSurface.withOpacity(0.55),
                ),
                onPressed: () => _previewRingtone(ringtone['file']!),
              ),
            if (isSelected)
              Icon(Icons.check_circle,
                  color: theme.colorScheme.primary, size: 20),
          ],
        ),
        onTap: onSelect,
      ),
    );
  }

  // Placeholder for system sound loading.
  // In practice, add a package like `flutter_system_ringtones_advanced`
  // to fetch these. For now, we surface it as optional.
  Future<void> _loadSystemSounds(Function setModalState) async {
    // If you add flutter_system_ringtones_advanced to pubspec.yaml:
    //
    // import 'package:flutter_system_ringtones_advanced/flutter_system_ringtones_advanced.dart';
    //
    // final sounds = await FlutterSystemRingtones.getNotificationSounds();
    // setModalState(() {
    //   _systemSounds = sounds
    //       .map((s) => {'id': s.uri, 'name': s.title, 'uri': s.uri})
    //       .toList();
    // });

    // For now, show a helpful toast.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Add flutter_system_ringtones_advanced to load device sounds'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════════
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

  Widget _toggleTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(
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
      value: value,
      onChanged: onChanged,
      activeColor: theme.colorScheme.primary,
    );
  }
}
