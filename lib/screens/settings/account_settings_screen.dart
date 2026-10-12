import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  bool _isLoading = false;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Account'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView(
        children: [
          _sectionTitle(theme, 'ACCOUNT SETTINGS'),

          _tile(
            theme,
            icon: Icons.security_outlined,
            title: 'Security',
            subtitle: 'Two-step verification, passcode',
            onTap: () => Navigator.pushNamed(context, '/security'),
          ),
          _tile(
            theme,
            icon: Icons.phone_outlined,
            title: 'Change Number',
            subtitle: authProvider.phoneNumber ?? 'Not set',
            onTap: () => _showChangeNumberDialog(context),
          ),
          _tile(
            theme,
            icon: Icons.email_outlined,
            title: 'Change Email',
            subtitle: authProvider.email ?? 'Not set',
            onTap: () => _showChangeEmailDialog(context),
          ),

          Divider(height: 0.5, color: theme.dividerColor),

          _dangerTile(
            theme,
            icon: Icons.delete_outline,
            title: 'Delete Account',
            subtitle: 'Permanently delete your account',
            onTap: () => _showDeleteAccountDialog(context),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHANGE NUMBER
  // ═══════════════════════════════════════════════════════════════════════
  void _showChangeNumberDialog(BuildContext context) {
    final controller = TextEditingController();
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Phone Number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Current: ${authProvider.phoneNumber ?? "Not set"}',
                style: TextStyle(
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'New phone number',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final newPhone = controller.text.trim();
              if (newPhone.isEmpty) return;

              Navigator.pop(ctx);
              setState(() => _isLoading = true);

              final success =
                  await authProvider.changePhoneNumber(newPhone);
              if (!mounted) return;
              setState(() => _isLoading = false);

              _toast(
                success
                    ? 'Phone number updated'
                    : (authProvider.error ?? 'Failed'),
                error: !success,
              );
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHANGE EMAIL
  // ═══════════════════════════════════════════════════════════════════════
  void _showChangeEmailDialog(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final currentEmail = authProvider.email;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Email'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current: ${currentEmail ?? "Not set"}',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'To change your email, you must verify your current email first.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showVerifyOldEmailDialog(context);
                },
                child: const Text('Verify Current Email'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showLostEmailDialog(context);
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE0954A),
              ),
              child: const Text(
                'Lost access to email?',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VERIFY OLD EMAIL
  // ═══════════════════════════════════════════════════════════════════════
  void _showVerifyOldEmailDialog(BuildContext context) {
    final theme = Theme.of(context);
    final codeController = TextEditingController();
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final email = authProvider.email;

    if (email == null || email.isEmpty) {
      _toast('No email on file', error: true);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Email'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter OTP sent to $email',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: codeController,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '6-digit code',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // TODO: verify OTP with backend
              Navigator.pop(ctx);
              _showEnterNewEmailDialog(context);
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ENTER NEW EMAIL
  // ═══════════════════════════════════════════════════════════════════════
  void _showEnterNewEmailDialog(BuildContext context) {
    final controller = TextEditingController();
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Email'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'new@email.com',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final newEmail = controller.text.trim();
              if (newEmail.isEmpty || !newEmail.contains('@')) return;

              Navigator.pop(ctx);
              setState(() => _isLoading = true);

              final success = await authProvider.changeEmail(newEmail);
              if (!mounted) return;
              setState(() => _isLoading = false);

              _toast(
                success ? 'Email updated' : (authProvider.error ?? 'Failed'),
                error: !success,
              );
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOST EMAIL REPORT
  // ═══════════════════════════════════════════════════════════════════════
  void _showLostEmailDialog(BuildContext context) {
    final theme = Theme.of(context);
    final reasonController = TextEditingController();
    final phoneController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Lost Email Access',
          style: TextStyle(color: Color(0xFFE0954A)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Report to Luma Support',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Send a report to supportlumachat@gmail.com. Include your phone number and reason.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.6),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: 'Your phone number',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Why do you need to change email?',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final phone = phoneController.text.trim();
              final reason = reasonController.text.trim();

              if (phone.isEmpty || reason.isEmpty) {
                _toast('Fill all fields', error: true);
                return;
              }

              // TODO: send report to backend/support email
              Navigator.pop(ctx);
              _toast(
                'Report sent to support. We will review and contact you.',
              );
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE0954A),
            ),
            child: const Text('Send Report'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // DELETE ACCOUNT
  // ═══════════════════════════════════════════════════════════════════════
  void _showDeleteAccountDialog(BuildContext context) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Delete Account?',
          style: TextStyle(color: theme.colorScheme.error),
        ),
        content: const Text(
          'This will permanently delete your account and all data. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final authProvider =
                  Provider.of<LumaAuthProvider>(context, listen: false);
              final success = await authProvider.deleteAccount();
              if (!context.mounted) return;
              if (success) {
                Navigator.pushNamedAndRemoveUntil(
                    context, '/', (route) => false);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        authProvider.error ?? 'Deletion failed'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
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

  Widget _tile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon,
          color: theme.colorScheme.onSurface.withOpacity(0.75)),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.55),
                fontSize: 13,
              ),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withOpacity(0.35),
        size: 20,
      ),
      onTap: onTap,
    );
  }

  Widget _dangerTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.error),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.error,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.55),
                fontSize: 13,
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}
