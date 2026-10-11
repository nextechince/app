import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final _emailController = TextEditingController();

  bool _isLoading = false;
  String? _error;
  bool _linkSent = false;
  String? _sentEmail;

  @override
  void initState() {
    super.initState();
    _checkPendingFlow();
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _checkPendingFlow() async {
    final prefs = await SharedPreferences.getInstance();

    final phone = prefs.getString('pending_phone');
    if (phone == null && mounted) {
      Navigator.pushReplacementNamed(context, '/phone_entry');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.email != null) {
      await _finishSignup(user);
    }
  }

  Future<void> _sendMagicLink() async {
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
      final acs = ActionCodeSettings(
        url: 'https://lumachat.firebaseapp.com/__/auth/action'
            '?email=${Uri.encodeComponent(email)}',
        handleCodeInApp: true,
        androidPackageName: 'com.lumachat.app',
        androidInstallApp: true,
        androidMinimumVersion: '1',
        iOSBundleId: 'com.lumachat.app',
      );

      await FirebaseAuth.instance.sendSignInLinkToEmail(
        email: email,
        actionCodeSettings: acs,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emailForSignIn', email);
      await prefs.setString('pending_email', email);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _linkSent = true;
        _sentEmail = email;
      });
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

  Future<void> _manualCheck() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _finishSignup(user);
    } else {
      setState(() =>
          _error = 'Open the email link on this device to continue.');
    }
  }

  Future<void> _finishSignup(User user) async {
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final phone = prefs.getString('pending_phone') ?? '';

      final docRef =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      final snapshot = await docRef.get();

      if (!snapshot.exists) {
        await docRef.set({
          'uid': user.uid,
          'email': user.email,
          'phone': phone,
          'phone_verified': false,
          'email_verified': true,
          'created_at': FieldValue.serverTimestamp(),
        });
      } else {
        await docRef.set({
          'phone': phone,
          'email_verified': true,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      await prefs.remove('pending_phone');
      await prefs.remove('pending_email');
      await prefs.remove('emailForSignIn');

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/setup_profile');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Setup error: $e';
      });
    }
  }

  Future<void> _goBack() async {
    await FirebaseAuth.instance.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('emailForSignIn');
    await prefs.remove('pending_email');

    if (!mounted) return;
    setState(() {
      _linkSent = false;
      _sentEmail = null;
      _error = null;
    });
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'invalid-email':
        return 'That email is not valid.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a bit and try again.';
      case 'unauthorized-continue-uri':
      case 'invalid-continue-uri':
        return 'Firebase needs the domain whitelisted.';
      default:
        return 'Error: $code';
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

                // Logo — same blue rounded square as phone entry
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.chat_bubble_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                Text(
                  _linkSent ? 'Check your email' : 'Your email',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _linkSent
                      ? 'We sent a verification link to $_sentEmail. Tap it on this device.'
                      : "We'll send you a verification link",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    height: 1.4,
                  ),
                ),

                const SizedBox(height: 40),

                if (!_linkSent)
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
                      prefixIcon: Icon(
                        Icons.email_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),

                if (_linkSent)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.mark_email_unread_outlined,
                          color: theme.colorScheme.primary,
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Verification link sent',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Tap the link in the email. Will be detected automatically.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                              color: Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const Spacer(),

                // Main button — same style as phone entry
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading
                        ? null
                        : (_linkSent ? _manualCheck : _sendMagicLink),
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _linkSent
                                ? "I've tapped the link"
                                : 'Send verification link',
                          ),
                  ),
                ),

                if (_linkSent) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: _goBack,
                      child: Text(
                        'Use different email',
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // Same terms footer as phone entry
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
