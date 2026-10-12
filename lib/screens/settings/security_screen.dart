import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_ios/local_auth_ios.dart';
import '../../providers/settings_provider.dart';

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _canCheckBiometrics = false;
  bool _isBiometricAvailable = false;
  List<BiometricType> _availableBiometrics = [];
  final _passcodeController = TextEditingController();
  final _confirmPasscodeController = TextEditingController();

  final List<Map<String, dynamic>> _autoLockOptions = [
    {'label': '1 minute', 'value': 1},
    {'label': '5 minutes', 'value': 5},
    {'label': '10 minutes', 'value': 10},
  ];

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    _confirmPasscodeController.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _checkBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      List<BiometricType> availableBiometrics = [];

      if (canCheck) {
        availableBiometrics = await _localAuth.getAvailableBiometrics();
      }

      if (!mounted) return;
      setState(() {
        _canCheckBiometrics = canCheck;
        _isBiometricAvailable = availableBiometrics.isNotEmpty;
        _availableBiometrics = availableBiometrics;
      });
    } on PlatformException catch (e) {
      debugPrint('Biometric check error: $e');
      if (!mounted) return;
      setState(() {
        _canCheckBiometrics = false;
        _isBiometricAvailable = false;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    final settingsProvider =
        Provider.of<SettingsProvider>(context, listen: false);

    if (value) {
      if (!_isBiometricAvailable) {
        _toast(
          'No biometric credentials enrolled. Set up fingerprint or face ID in device settings first.',
          error: true,
        );
        return;
      }

      try {
        final didAuthenticate = await _localAuth.authenticate(
          localizedReason: 'Authenticate to enable biometric lock',
          authMessages: const [
            AndroidAuthMessages(
              signInTitle: 'Biometric Authentication',
              cancelButton: 'Cancel',
              biometricHint: 'Verify your identity',
              biometricNotRecognized: 'Not recognized, try again',
              biometricRequiredTitle: 'Biometric authentication required',
              biometricSuccess: 'Authentication successful',
              deviceCredentialsRequiredTitle: 'Device credentials required',
              deviceCredentialsSetupDescription:
                  'Please set up device credentials',
              goToSettingsButton: 'Go to Settings',
              goToSettingsDescription:
                  'Please set up biometric authentication in your device settings',
            ),
            IOSAuthMessages(
              cancelButton: 'Cancel',
              goToSettingsButton: 'Go to Settings',
              goToSettingsDescription:
                  'Please set up biometric authentication in your device settings',
              lockOut: 'Please re-enable biometric authentication',
            ),
          ],
          options: const AuthenticationOptions(
            biometricOnly: false,
            stickyAuth: true,
            sensitiveTransaction: true,
            useErrorDialogs: true,
          ),
        );

        if (didAuthenticate) {
          await settingsProvider.setBiometricLock(true);
          _toast('Biometric lock enabled');
        }
      } on PlatformException catch (e) {
        debugPrint('Biometric auth error: $e');
        String message = 'Biometric authentication failed';
        if (e.code == 'NotAvailable') {
          message = 'Biometric authentication is not available';
        } else if (e.code == 'NotEnrolled') {
          message =
              'No biometric credentials enrolled. Set up fingerprint or face ID first.';
        } else if (e.code == 'PasscodeNotSet') {
          message = 'Please set a device passcode first';
        } else if (e.code == 'no_fragment_activity') {
          message = 'App configuration issue. Please update the app.';
        }
        _toast(message, error: true);
      } catch (e) {
        debugPrint('Unexpected biometric error: $e');
        _toast('Biometric error: $e', error: true);
      }
    } else {
      await settingsProvider.setBiometricLock(false);
      _toast('Biometric lock disabled');
    }
  }

  void _showAutoLockPicker() {
    final theme = Theme.of(context);
    final settingsProvider =
        Provider.of<SettingsProvider>(context, listen: false);

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
                    'Auto-Lock Timer',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Lock app after being in background for:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
              ),
              ..._autoLockOptions.map((option) {
                final isSelected =
                    settingsProvider.autoLockTimeout == option['value'];
                return ListTile(
                  leading: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                  title: Text(
                    option['label'],
                    style: TextStyle(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  onTap: () {
                    settingsProvider.setAutoLockTimeout(option['value']);
                    Navigator.pop(ctx);
                    _toast('Auto-lock set to ${option['label']}');
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showPasscodeDialog() {
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set App Passcode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _passcodeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Enter 6-digit passcode',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmPasscodeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm passcode',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _passcodeController.clear();
              _confirmPasscodeController.clear();
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (_passcodeController.text.length != 6) {
                _toast('Passcode must be 6 digits', error: true);
                return;
              }
              if (_passcodeController.text !=
                  _confirmPasscodeController.text) {
                _toast('Passcodes do not match', error: true);
                return;
              }

              await Provider.of<SettingsProvider>(context, listen: false)
                  .setPasscode(_passcodeController.text);
              await Provider.of<SettingsProvider>(context, listen: false)
                  .setAppPasscode(true);

              _passcodeController.clear();
              _confirmPasscodeController.clear();

              if (!mounted) return;
              Navigator.pop(ctx);
              _toast('Passcode set successfully');
            },
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.primary,
            ),
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settingsProvider = Provider.of<SettingsProvider>(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Security'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionTitle(theme, 'AUTHENTICATION'),

          _toggleTile(
            theme,
            icon: Icons.verified_user_outlined,
            title: 'Two-Step Verification',
            subtitle: 'Add extra security to your account',
            value: settingsProvider.twoStepVerification,
            onChanged: (v) =>
                settingsProvider.setTwoStepVerification(v),
          ),

          _toggleTile(
            theme,
            icon: Icons.lock_outline,
            title: 'App Passcode',
            subtitle: settingsProvider.appPasscode
                ? 'Passcode is set'
                : 'Lock app with a 6-digit code',
            value: settingsProvider.appPasscode,
            onChanged: (v) {
              if (v) {
                _showPasscodeDialog();
              } else {
                settingsProvider.setAppPasscode(false);
                settingsProvider.setPasscode('');
              }
            },
          ),

          _actionTile(
            theme,
            icon: Icons.timer_outlined,
            title: 'Auto-Lock Timer',
            subtitle:
                '${settingsProvider.autoLockTimeout} minute${settingsProvider.autoLockTimeout != 1 ? 's' : ''}',
            onTap: _showAutoLockPicker,
          ),

          if (_canCheckBiometrics)
            _toggleTile(
              theme,
              icon: Icons.fingerprint,
              title: 'Biometric Lock',
              subtitle: _isBiometricAvailable
                  ? 'Use fingerprint or face ID'
                  : 'No biometric credentials enrolled',
              value: settingsProvider.biometricLock,
              onChanged: _isBiometricAvailable ? _toggleBiometric : null,
            ),

          if (!_canCheckBiometrics)
            ListTile(
              leading: Icon(
                Icons.fingerprint,
                color: theme.colorScheme.onSurface.withOpacity(0.35),
              ),
              title: Text(
                'Biometric Lock',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'Not available on this device',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withOpacity(0.35),
                ),
              ),
              enabled: false,
            ),

          Divider(height: 0.5, color: theme.dividerColor),

          _sectionTitle(theme, 'SECURITY INFO'),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withOpacity(0.03),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'About Security Features',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Two-Step Verification: Requires OTP every time you sign in on a new device.\n\n'
                    'App Passcode: Locks the app when you close it. You will need to enter the passcode to open it.\n\n'
                    'Auto-Lock: Automatically locks the app after being in the background for the selected time.\n\n'
                    'Biometric Lock: Uses your device fingerprint or face recognition to unlock the app.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Helpers ──
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
    required ValueChanged<bool>? onChanged,
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

  Widget _actionTile(
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
