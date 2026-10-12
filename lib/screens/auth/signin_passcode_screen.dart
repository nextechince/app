import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SigninPasscodeScreen extends StatefulWidget {
  const SigninPasscodeScreen({super.key});

  @override
  State<SigninPasscodeScreen> createState() => _SigninPasscodeScreenState();
}

class _SigninPasscodeScreenState extends State<SigninPasscodeScreen> {
  final _passcodeController = TextEditingController();
  final _focusNode = FocusNode();

  bool _isLoading = false;
  String? _error;
  String? _email;
  String? _phone;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _email = prefs.getString('signin_email');
      _phone = prefs.getString('pending_phone');
    });
  }

  Future<void> _signIn() async {
    final passcode = _passcodeController.text;
    if (passcode.length < 4) {
      setState(() => _error = 'Enter your passcode');
      return;
    }

    if (_email == null || _email!.isEmpty) {
      setState(() => _error = 'Email missing. Please start over.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email!,
        password: passcode,
      );

      final uid = cred.user!.uid;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mock_user_id', uid);
      await prefs.setString('mock_email', _email!);
      await prefs.setString('mock_phone', _phone ?? '');

      if (!mounted) return;
      setState(() => _isLoading = false);

      // Check if profile is complete
      Navigator.pushReplacementNamed(context, '/main');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _friendlyError(e.code);
      });
      _passcodeController.clear();
      _focusNode.requestFocus();
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
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect passcode. Try again.';
      case 'user-not-found':
        return 'Account not found.';
      case 'too-many-requests':
        return 'Too many attempts. Try again in a minute.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return 'Error: $code';
    }
  }

  Future<void> _forgotPasscode() async {
    if (_email == null || _email!.isEmpty) return;

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _email!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reset link sent to $_email'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not send reset link: $e');
    }
  }

  Future<void> _goBack() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('signin_email');
    await prefs.remove('signin_uid');

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/phone_entry');
  }

  int get _passcodeLength => _passcodeController.text.length;

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
                        child: Icon(Icons.lock_outline,
                            color: Colors.white, size: 36),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              Text(
                'Welcome back',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your passcode to sign in as ${_phone ?? "your account"}.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  height: 1.4,
                ),
              ),

              const SizedBox(height: 40),

              // ── Passcode boxes ──
              _PasscodeBoxes(
                controller: _passcodeController,
                focusNode: _focusNode,
                onChanged: (_) => setState(() => _error = null),
              ),

              const SizedBox(height: 16),

              Text(
                '$_passcodeLength/6 digits',
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
                  onPressed: _isLoading ? null : _signIn,
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Sign in'),
                ),
              ),

              const SizedBox(height: 16),

              Center(
                child: TextButton(
                  onPressed: _forgotPasscode,
                  child: const Text('Forgot passcode?'),
                ),
              ),

              Center(
                child: TextButton(
                  onPressed: _goBack,
                  child: const Text('Use different number'),
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
        Opacity(
          opacity: 0,
          child: SizedBox(
            height: 60,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
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
