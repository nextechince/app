import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../providers/settings_provider.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;

class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _loadedFromFirestore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFromFirestore());
  }

  /// Load privacy settings from Firestore on open, so changes made on
  /// other devices show up here.
  Future<void> _loadFromFirestore() async {
    if (_loadedFromFirestore) return;
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final userId = auth.user?.uid ?? auth.mockUserId;
    if (userId == null) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('user_settings')
          .doc(userId)
          .get();
      if (!doc.exists || !mounted) return;
      final d = doc.data()!;
      settings.applyPrivacySettings(d);
      _loadedFromFirestore = true;
    } catch (e) {
      debugPrint('Load privacy settings failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Privacy'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // ── Who can see my info ──
              _sectionTitle(theme, 'WHO CAN SEE MY INFO'),
              _toggleTile(
                theme,
                icon: Icons.phone_outlined,
                title: 'Phone Number',
                subtitle: 'Show my phone number to others',
                value: settings.phoneNumberVisible,
                onChanged: (v) {
                  settings.setPhoneNumberVisible(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.access_time_outlined,
                title: 'Last Seen',
                subtitle: 'Show when I was last online',
                value: settings.lastSeenVisible,
                onChanged: (v) {
                  settings.setLastSeenVisible(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.photo_outlined,
                title: 'Profile Photo',
                subtitle: 'Show my profile photo to others',
                value: settings.profilePhotoVisible,
                onChanged: (v) {
                  settings.setProfilePhotoVisible(v);
                  _syncToFirestore(settings);
                },
              ),

              Divider(height: 0.5, color: theme.dividerColor),

              // ── Messaging ──
              _sectionTitle(theme, 'MESSAGING'),
              _toggleTile(
                theme,
                icon: Icons.forward_to_inbox_outlined,
                title: 'Forwarded Messages',
                subtitle: 'Allow others to forward my messages',
                value: settings.forwardedMessages,
                onChanged: (v) {
                  settings.setForwardedMessages(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.group_add_outlined,
                title: 'Add to Groups',
                subtitle: 'Allow others to add me to groups',
                value: settings.addToGroups,
                onChanged: (v) {
                  settings.setAddToGroups(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.call_outlined,
                title: 'Voice & Video Calls',
                subtitle: 'Allow others to call me',
                value: settings.voiceVideoCallsVisible,
                onChanged: (v) {
                  settings.setVoiceVideoCallsVisible(v);
                  _syncToFirestore(settings);
                },
              ),

              Divider(height: 0.5, color: theme.dividerColor),

              // ── Find me ──
              _sectionTitle(theme, 'FIND ME'),
              _toggleTile(
                theme,
                icon: Icons.phone_android_outlined,
                title: 'Find by Phone Number',
                subtitle: 'People can find me using my phone',
                value: settings.findByPhone,
                onChanged: (v) {
                  settings.setFindByPhone(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.alternate_email_outlined,
                title: 'Find by Username',
                subtitle: 'People can find me using my username',
                value: settings.findByUsername,
                onChanged: (v) {
                  settings.setFindByUsername(v);
                  _syncToFirestore(settings);
                },
              ),

              Divider(height: 0.5, color: theme.dividerColor),

              // ── Security ──
              _sectionTitle(theme, 'SECURITY'),
              _toggleTile(
                theme,
                icon: Icons.fingerprint,
                title: 'Biometric Lock',
                subtitle: 'Lock app with fingerprint/face',
                value: settings.biometricLock,
                onChanged: (v) {
                  settings.setBiometricLock(v);
                  _syncToFirestore(settings);
                },
              ),
              _toggleTile(
                theme,
                icon: Icons.lock_outline,
                title: 'App Passcode',
                subtitle: 'Lock app with a PIN',
                value: settings.appPasscode,
                onChanged: (v) async {
                  if (v) {
                    // Require setting a passcode when enabling
                    final set = await _showPasscodeDialog(context, settings);
                    if (set != true && mounted) {
                      settings.setAppPasscode(false);
                      return;
                    }
                  } else {
                    settings.setAppPasscode(false);
                  }
                  _syncToFirestore(settings);
                },
              ),

              if (settings.appPasscode || settings.biometricLock)
                _actionTile(
                  theme,
                  icon: Icons.timer_outlined,
                  title: 'Auto-Lock Timeout',
                  subtitle:
                      '${settings.autoLockTimeout} minute${settings.autoLockTimeout == 1 ? '' : 's'}',
                  onTap: () => _showTimeoutPicker(context, settings),
                ),

              if (settings.appPasscode)
                _actionTile(
                  theme,
                  icon: Icons.pin_outlined,
                  title: 'Change Passcode',
                  subtitle: settings.passcode.isEmpty
                      ? 'No passcode set'
                      : 'Passcode is set',
                  onTap: () => _showPasscodeDialog(context, settings),
                ),

              if (settings.appPasscode || settings.biometricLock)
                _actionTile(
                  theme,
                  icon: Icons.lock_person_outlined,
                  title: 'Lock Now',
                  subtitle: 'Manually lock the app immediately',
                  onTap: () {
                    settings.lock();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('App locked'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),

              Divider(height: 0.5, color: theme.dividerColor),

              // ── Info card ──
              Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.15),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'These settings control your visibility and how others can interact with you. Changes sync to your account when online.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.65),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // FIRESTORE SYNC
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _syncToFirestore(SettingsProvider settings) async {
    final auth =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = auth.user?.uid ?? auth.mockUserId;
    if (userId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('user_settings')
          .doc(userId)
          .set({
        'phone_number_visible': settings.phoneNumberVisible,
        'last_seen_visible': settings.lastSeenVisible,
        'profile_photo_visible': settings.profilePhotoVisible,
        'forwarded_messages': settings.forwardedMessages,
        'add_to_groups': settings.addToGroups,
        'voice_video_calls_visible': settings.voiceVideoCallsVisible,
        'find_by_phone': settings.findByPhone,
        'find_by_username': settings.findByUsername,
        'biometric_lock': settings.biometricLock,
        'app_passcode': settings.appPasscode,
        'auto_lock_timeout': settings.autoLockTimeout,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Sync privacy settings failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to sync. Will retry when online.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AUTO-LOCK TIMEOUT PICKER
  // ═══════════════════════════════════════════════════════════════════════
  void _showTimeoutPicker(BuildContext context, SettingsProvider settings) {
    final theme = Theme.of(context);
    final options = [1, 5, 15, 30];

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Auto-Lock Timeout',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...options.map((minutes) {
                final isSelected = settings.autoLockTimeout == minutes;
                return ListTile(
                  leading: Icon(
                    Icons.timer_outlined,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                  title: Text(
                    '$minutes minute${minutes == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : null,
                  onTap: () {
                    settings.setAutoLockTimeout(minutes);
                    _syncToFirestore(settings);
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PASSCODE DIALOG (with old passcode validation)
  // ═══════════════════════════════════════════════════════════════════════
  Future<bool?> _showPasscodeDialog(
      BuildContext context, SettingsProvider settings) {
    // Steps: 0 = enter old, 1 = enter new, 2 = confirm new
    int step = settings.passcode.isEmpty ? 1 : 0;
    String oldEntered = '';
    String newEntered = '';
    String confirm = '';
    String? error;

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);

          String title() {
            switch (step) {
              case 0:
                return 'Enter Current Passcode';
              case 1:
                return 'Enter New Passcode';
              case 2:
                return 'Confirm New Passcode';
              default:
                return '';
            }
          }

          String subtitle() {
            switch (step) {
              case 0:
                return 'Verify your identity first';
              case 1:
                return 'Choose a 6-digit PIN';
              case 2:
                return 'Enter it again to confirm';
              default:
                return '';
            }
          }

          String current() {
            switch (step) {
              case 0:
                return oldEntered;
              case 1:
                return newEntered;
              case 2:
                return confirm;
              default:
                return '';
            }
          }

          void onDigit(String d) {
            setDialogState(() {
              error = null;
              switch (step) {
                case 0:
                  if (oldEntered.length < 6) oldEntered += d;
                  if (oldEntered.length == 6) {
                    if (oldEntered == settings.passcode) {
                      step = 1;
                      oldEntered = '';
                    } else {
                      oldEntered = '';
                      error = 'Incorrect passcode. Try again.';
                    }
                  }
                  break;
                case 1:
                  if (newEntered.length < 6) newEntered += d;
                  if (newEntered.length == 6) step = 2;
                  break;
                case 2:
                  if (confirm.length < 6) confirm += d;
                  if (confirm.length == 6) {
                    if (confirm == newEntered) {
                      settings.setPasscode(confirm);
                      settings.setAppPasscode(true);
                      Navigator.pop(ctx, true);
                    } else {
                      confirm = '';
                      error = 'Passcodes do not match. Try again.';
                    }
                  }
                  break;
              }
            });
          }

          void onBackspace() {
            setDialogState(() {
              error = null;
              switch (step) {
                case 0:
                  if (oldEntered.isNotEmpty) {
                    oldEntered = oldEntered
                        .substring(0, oldEntered.length - 1);
                  }
                  break;
                case 1:
                  if (newEntered.isNotEmpty) {
                    newEntered = newEntered
                        .substring(0, newEntered.length - 1);
                  }
                  break;
                case 2:
                  if (confirm.isNotEmpty) {
                    confirm =
                        confirm.substring(0, confirm.length - 1);
                  }
                  break;
              }
            });
          }

          return AlertDialog(
            title: Text(title()),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  subtitle(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 20),

                // Dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(6, (i) {
                    final c = current();
                    final filled = i < c.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface
                                .withOpacity(0.15),
                      ),
                    );
                  }),
                ),

                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(
                        color: theme.colorScheme.error, fontSize: 13),
                  ),
                ],

                const SizedBox(height: 20),

                // Number pad
                SizedBox(
                  width: 240,
                  child: GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 3,
                    childAspectRatio: 1.4,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (var i = 1; i <= 9; i++)
                        _digitBtn(theme, i.toString(),
                            () => onDigit(i.toString())),
                      const SizedBox.shrink(),
                      _digitBtn(theme, '0', () => onDigit('0')),
                      IconButton(
                        onPressed: onBackspace,
                        icon: Icon(
                          Icons.backspace_outlined,
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _digitBtn(ThemeData theme, String digit, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: Center(
        child: Text(
          digit,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w500,
          ),
        ),
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
      secondary: Icon(icon,
          color: theme.colorScheme.onSurface.withOpacity(0.75)),
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

  Widget _actionTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon,
          color: theme.colorScheme.onSurface.withOpacity(0.75)),
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
