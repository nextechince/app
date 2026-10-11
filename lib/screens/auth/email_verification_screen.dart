import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:emailjs/emailjs.dart' as emailjs;

import '../../services/emailjs_config.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final _emailController = TextEditingController();
  final List<TextEditingController> _codeControllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes =
      List.generate(6, (_) => FocusNode());

  bool _isLoading = false;
  String? _error;
  bool _codeSent = false;
  String? _sentEmail;
  int _resendTimer = 0;
  bool _resendLoading = false;

  @override
  void initState() {
    super.initState();
    _checkPendingFlow();
  }

  @override
  void dispose() {
    _emailController.dispose();
    for (var c in _codeControllers) c.dispose();
    for (var f in _focusNodes) f.dispose();
    super.dispose();
  }

  Future<void> _checkPendingFlow() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('pending_phone');
    if (phone == null && mounted) {
      Navigator.pushReplacementNamed(context, '/phone_entry');
    }
  }

  // ─── Generate 6-digit code ───
  String _generateCode() {
    final rand = Random();
    return (100000 + rand.nextInt(900000)).toString();
  }

  // ─── Send OTP ───
  Future<void> _sendCode() async {
    final email = _emailController.text.trim().toLowerCase();

    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final code = _generateCode();
      final expiresAt = DateTime.now().add(const Duration(minutes: 10));

      // 1. Save code to Firestore (using email as doc ID)
      await FirebaseFirestore.instance
          .collection('email_verifications')
          .doc(email)
          .set({
        'email': email,
        'code': code,
        'expires_at': Timestamp.fromDate(expiresAt),
        'created_at': FieldValue.serverTimestamp(),
        'verified': false,
      });

      // 2. Send email via EmailJS
      await emailjs.send(
        EmailJSConfig.serviceId,
        EmailJSConfig.templateId,
        {
          'to_email': email,
          'otp_code': code,
        },
        emailjs.Options(publicKey: EmailJSConfig.publicKey),
      );

      // 3. Save pending email
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_email', email);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _codeSent = true;
        _sentEmail = email;
      });
      _startResendTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to send code: $e';
      });
    }
  }

  // ─── Resend code ───
  Future<void> _resendCode() async {
    if (_resendTimer > 0 || _sentEmail == null) return;
    setState(() => _resendLoading = true);

    try {
      final code = _generateCode();
      final expiresAt = DateTime.now().add(const Duration(minutes: 10));

      await FirebaseFirestore.instance
          .collection('email_verifications')
          .doc(_sentEmail)
          .set({
        'email': _sentEmail,
        'code': code,
        'expires_at': Timestamp.fromDate(expiresAt),
        'created_at': FieldValue.serverTimestamp(),
        'verified': false,
      });

      await emailjs.send(
        EmailJSConfig.serviceId,
        EmailJSConfig.templateId,
        {'to_email': _sentEmail, 'otp_code': code},
        emailjs.Options(publicKey: EmailJSConfig.publicKey),
      );

      if (!mounted) return;
      setState(() => _resendLoading = false);
      _startResendTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New code sent!')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resendLoading = false;
        _error = 'Resend failed: $e';
      });
    }
  }

  void _startResendTimer() {
    if (_resendTimer > 0) return;
    setState(() => _resendTimer = 60);
    _tickTimer();
  }

  void _tickTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && _resendTimer > 0) {
        setState(() => _resendTimer--);
        _tickTimer();
      }
    });
  }

  // ─── Verify code ───
  Future<void> _verifyCode() async {
    final code = _codeControllers.map((c) => c.text).join();
    if (code.length != 6) {
      setState(() => _error = 'Enter all 6 digits');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final doc = await FirebaseFirestore.instance
          .collection('email_verifications')
          .doc(_sentEmail)
          .get();

      if (!doc.exists) {
        setState(() {
          _isLoading = false;
          _error = 'Code not found. Resend.';
        });
        return;
      }

      final data = doc.data()!;
      final storedCode = data['code'] as String?;
      final expiresAt = (data['expires_at'] as Timestamp).toDate();

      if (DateTime.now().isAfter(expiresAt)) {
        setState(() {
          _isLoading = false;
          _error = 'Code expired. Resend.';
        });
        return;
      }

      if (code != storedCode) {
        setState(() {
          _isLoading = false;
          _error = 'Invalid code';
        });
        for (final c in _codeControllers) c.clear();
        _focusNodes[0].requestFocus();
        return;
      }

      // Code is correct — mark verified
      await FirebaseFirestore.instance
          .collection('email_verifications')
          .doc(_sentEmail)
          .update({'verified': true});

      await _finishSignup();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Verification failed: $e';
      });
    }
  }

  Future<void> _finishSignup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final phone = prefs.getString('pending_phone') ?? '';

      // Sign in anonymously to Firebase (so we have a UID)
      // Then link the email via updateEmail later, or just create a doc with email as ID
      // Simpler: use email as UID reference in Firestore.
      // Actually — create a real Firebase account with a random password.
      // User won't need it since we can auto-sign-in later using a custom token.
      // 
      // EASIEST: Sign in anonymously, then save user doc.
      final cred = await FirebaseAuth.instance.signInAnonymously();
      final uid = cred.user!.uid;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'uid': uid,
        'email': _sentEmail,
        'phone': phone,
        'phone_verified': false,
        'email_verified': true,
        'created_at': FieldValue.serverTimestamp(),
      });

      await prefs.setString('mock_user_id', uid);
      await prefs.setString('mock_email', _sentEmail!);
      await prefs.remove('pending_phone');
      await prefs.remove('pending_email');

      // Cleanup verification doc
      await FirebaseFirestore.instance
          .collection('email_verifications')
          .doc(_sentEmail)
          .delete();

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/setup_profile');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Signup error: $e';
      });
    }
  }

  void _onCodeChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
    if (_codeControllers.every((c) => c.text.isNotEmpty)) {
      _verifyCode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),

                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Center(
                    child: Icon(Icons.chat_bubble_rounded,
                        color: Colors.white, size: 32),
                  ),
                ),

                const SizedBox(height: 32),

                Text(
                  _codeSent ? 'Verify your email' : 'Your email',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _codeSent
                      ? 'Enter the 6-digit code sent to $_sentEmail'
                      : "We'll send you a code to verify your email.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    height: 1.4,
                  ),
                ),

                const SizedBox(height: 40),

                if (!_codeSent)
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofocus: true,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      hintText: 'your@email.com',
                      prefixIcon: Icon(Icons.email_outlined,
                          color: theme.colorScheme.primary),
                    ),
                  ),

                if (_codeSent)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(6, (index) {
                      return Container(
                        width: 48,
                        height: 60,
                        decoration: BoxDecoration(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white.withOpacity(0.05)
                              : Colors.black.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _focusNodes[index].hasFocus
                                ? theme.colorScheme.primary
                                : theme.dividerColor,
                            width: _focusNodes[index].hasFocus ? 2 : 1,
                          ),
                        ),
                        child: TextField(
                          controller: _codeControllers[index],
                          focusNode: _focusNodes[index],
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(1),
                          ],
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                          decoration: const InputDecoration(
                            counterText: '',
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => _onCodeChanged(index, v),
                        ),
                      );
                    }),
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
                        : (_codeSent ? _verifyCode : _sendCode),
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(_codeSent ? 'Verify Code' : 'Send Code'),
                  ),
                ),

                if (_codeSent) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: _resendTimer > 0
                        ? Text(
                            'Resend in $_resendTimer s',
                            style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.4),
                              fontSize: 14,
                            ),
                          )
                        : _resendLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : TextButton(
                                onPressed: _resendCode,
                                child: const Text('Resend Code'),
                              ),
                  ),
                  Center(
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _codeSent = false;
                          _error = null;
                          _resendTimer = 0;
                          for (final c in _codeControllers) {
                            c.clear();
                          }
                        });
                      },
                      child: const Text('Use different email'),
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                Center(
                  child: Text(
                    'By continuing you agree to our Terms & Privacy Policy',
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
      ),
    );
  }
}
