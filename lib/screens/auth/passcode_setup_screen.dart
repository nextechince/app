import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PasscodeSetupScreen extends StatefulWidget {
  const PasscodeSetupScreen({super.key});

  @override
  State<PasscodeSetupScreen> createState() => _PasscodeSetupScreenState();
}

class _PasscodeSetupScreenState extends State<PasscodeSetupScreen> {
  final _passcodeController = TextEditingController();
  final _confirmController = TextEditingController();
  final _passcodeFocus = FocusNode();
  final _confirmFocus = FocusNode();

  bool _isLoading = false;
  String? _error;
  int _step = 0; // 0 = enter, 1 = confirm

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _passcodeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    _confirmController.dispose();
    _passcodeFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  int get _passcodeLength => _passcodeController.text.length;
  bool get _passcodeValid => _passcodeLength >= 4 && _passcodeLength <= 6;

  void _nextStep() {
    if (!_passcodeValid) {
      setState(() => _error = 'Passcode must be 4-6 digits');
      return;
    }
    setState(() {
      _step = 1;
      _error = null;
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _confirmFocus.requestFocus();
    });
  }

  Future<void> _createAccount() async {
    final passcode = _passcodeController.text;
    final confirm = _confirmController.text;

    if (passcode != confirm) {
      setState(() => _error = "Passcodes don't match");
      _confirmController.clear();
      _confirmFocus.requestFocus();
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('pending_email');
      final phone = prefs.getString('pending_phone');

      if (email == null || email.isEmpty) {
        throw Exception('Email missing. Please start over.');
      }

      // Create Firebase account — user signed in immediately
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
        email: email,
        password: passcode,
      );

      final uid = cred.user!.uid;

      // Save user doc
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'uid': uid,
        'email': email,
        'phone': phone ?? '',
        'phone_verified': false,
        'email_verified': false,
        'created_at': FieldValue.serverTimestamp(),
      });

      // Save local session
      await prefs.setString('mock_user_id', uid);
      await prefs.setString('mock_email', email);
      await prefs.setString('mock_phone', phone ?? '');

      if (!mounted) return;
      setState(() => _isLoading = false);

      // Go to profile setup
      Navigator.pushReplacementNamed(context, '/setup_profile');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _friendlyError(e.code);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Error: $e';
      });
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'That email is already registered. Try signing in instead.';
      case 'weak-password':
        return 'Passcode must be at least 4 digits.';
      case 'invalid-email':
        return 'That email is not valid.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return 'Error: $code';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // Back arrow on step 2
              if (_step == 1)
                IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: theme.colorScheme.onSurface,
                  ),
                  onPressed: () => setState(() {
                    _step = 0;
                    _confirmController.clear();
                    _error = null;
                    _passcodeFocus.requestFocus();
                  }),
                )
              else
                const SizedBox(height: 48),

              const SizedBox(height: 8),

              // ── App logo ──
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: theme.colorScheme.primary,
                      child: const Center(
                        child: Icon(
                          Icons.lock_outline,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              Text(
                _step == 0 ? 'Set your passcode' : 'Confirm passcode',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _step == 0
                    ? 'Choose a 4-6 digit code to secure your account.'
                    : 'Enter it again to confirm.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  height: 1.4,
                ),
              ),

              const SizedBox(height: 40),

              // ── Passcode boxes ──
              _PasscodeBoxes(
                controller:
                    _step == 0 ? _passcodeController : _confirmController,
                focusNode: _step == 0 ? _passcodeFocus : _confirmFocus,
                onChanged: (_) => setState(() => _error = null),
              ),

              const SizedBox(height: 16),

              Text(
                _step == 0
                    ? '$_passcodeLength/6 digits'
                    : '${_confirmController.text.length}/6 digits',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const Spacer(),

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading
                      ? null
                      : (_step == 0 ? _nextStep : _createAccount),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(_step == 0 ? 'Continue' : 'Create Account'),
                ),
              ),

              const SizedBox(height: 16),

              Center(
                child: Text(
                  'You\'ll use this passcode to sign in on new devices.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// PASSCODE BOXES — 6 boxes with hidden input
// ═════════════════════════════════════════════════════════════════════════════
class _PasscodeBoxes extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  const _PasscodeBoxes({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = controller.text.length;

    return Stack(
      alignment: Alignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (i) {
            final filled = i < length;
            final isActive = i == length && focusNode.hasFocus;

            return Container(
              width: 48,
              height: 60,
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.white.withOpacity(0.05)
                    : Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.dividerColor,
                  width: isActive ? 2 : 1,
                ),
              ),
              child: Center(
                child: filled
                    ? Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
              ),
            );
          }),
        ),
        // Hidden TextField captures the input
        Opacity(
          opacity: 0,
          child: SizedBox(
            height: 60,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
