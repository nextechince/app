import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../utils/verified_badge.dart';

// ─── CLOUDINARY CONFIG ───
const String _cloudName = 'dn2mwp1lc';
const String _uploadPreset = 'aura_chat';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _isEditing = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authProvider = Provider.of<LumaAuthProvider>(context);
    if (!_isEditing && !_isLoading) {
      _nameController.text = authProvider.userName ?? '';
      _bioController.text = authProvider.userBio ?? '';
    }
  }

  void _loadUserData() {
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    _nameController.text = authProvider.userName ?? '';
    _bioController.text = authProvider.userBio ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
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

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;

      final fileBytes = await pickedFile.readAsBytes();
      final fileName =
          'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/$_cloudName/image/upload',
      );

      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _uploadPreset
        ..fields['public_id'] = 'luma_profiles/$userId/$fileName'
        ..files.add(
          http.MultipartFile.fromBytes('file', fileBytes,
              filename: fileName),
        );

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonData = jsonDecode(responseData);

      if (response.statusCode != 200) {
        throw Exception(
            'Cloudinary error: ${jsonData['error']?['message'] ?? responseData}');
      }

      final imageUrl = jsonData['secure_url'] as String;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({
        'avatar_url': imageUrl,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await authProvider.updateProfile(photoUrl: imageUrl);

      _toast('Profile photo updated');
    } catch (e) {
      _toast('Error: $e', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveProfile() async {
    setState(() => _isLoading = true);

    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final success = await authProvider.updateProfile(
      username: _nameController.text.trim(),
      bio: _bioController.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isEditing = false;
    });

    _toast(success
        ? 'Profile updated'
        : 'Update failed: ${authProvider.error}',
        error: !success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<LumaAuthProvider>(
      builder: (context, authProvider, child) {
        final email = authProvider.email ?? '';
        final userVerified = isVerified(email);

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text('Profile'),
            backgroundColor: theme.scaffoldBackgroundColor,
            elevation: 0,
            actions: [
              if (!_isEditing)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => setState(() => _isEditing = true),
                )
              else
                IconButton(
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  onPressed: _isLoading ? null : _saveProfile,
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header: Avatar + name + email ──
                Center(
                  child: Column(
                    children: [
                      Stack(
                        children: [
                          _buildAvatar(theme, authProvider.userPhotoUrl),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: GestureDetector(
                              onTap: _isLoading ? null : _pickImage,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: theme.scaffoldBackgroundColor,
                                    width: 2,
                                  ),
                                ),
                                child: _isLoading
                                    ? SizedBox(
                                        width: 14,
                                        height: 14,
                                        child:
                                            CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: theme
                                              .scaffoldBackgroundColor,
                                        ),
                                      )
                                    : const Icon(Icons.camera_alt,
                                        color: Colors.white, size: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: VerifiedUsername(
                          username: authProvider.userName?.isNotEmpty == true
                              ? authProvider.userName!
                              : 'Your Name',
                          email: email,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          badgeSize: 18,
                          spacing: 8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        email,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.55),
                          fontSize: 13,
                        ),
                      ),
                      if (userVerified)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3390EC)
                                  .withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF3390EC)
                                    .withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const VerifiedBadge(
                                    size: 12, showTooltip: false),
                                const SizedBox(width: 6),
                                Text(
                                  'Verified Account',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: const Color(0xFF3390EC),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // ── Info cards ──
                _sectionTitle(theme, 'ACCOUNT'),
                const SizedBox(height: 8),
                _infoTile(
                  theme,
                  icon: Icons.person_outline,
                  label: 'Display Name',
                  value:
                      authProvider.userName?.isNotEmpty == true
                          ? authProvider.userName!
                          : 'Not set',
                  editing: _isEditing,
                  controller: _nameController,
                  hint: 'Enter your name',
                ),
                const SizedBox(height: 8),
                _infoTile(
                  theme,
                  icon: Icons.info_outline,
                  label: 'Bio',
                  value:
                      authProvider.userBio?.isNotEmpty == true
                          ? authProvider.userBio!
                          : 'No bio yet',
                  editing: _isEditing,
                  controller: _bioController,
                  hint: 'Tell people about you',
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                _readonlyTile(
                  theme,
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: email.isNotEmpty ? email : 'Not set',
                ),

                const SizedBox(height: 24),

                // ── Settings ──
                _sectionTitle(theme, 'SETTINGS'),
                const SizedBox(height: 8),
                _settingsTile(
                  theme,
                  icon: Icons.privacy_tip_outlined,
                  title: 'Privacy',
                  subtitle: 'Control who can see your info',
                  onTap: () =>
                      Navigator.pushNamed(context, '/privacy_settings'),
                ),
                _settingsTile(
                  theme,
                  icon: Icons.security_outlined,
                  title: 'Security',
                  subtitle: 'Passcode and biometric lock',
                  onTap: () => Navigator.pushNamed(context, '/security'),
                ),
                _settingsTile(
                  theme,
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  subtitle: 'Message tones and alerts',
                  onTap: () => Navigator.pushNamed(
                      context, '/notifications_settings'),
                ),

                const SizedBox(height: 24),

                // ── Danger zone ──
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    'DANGER ZONE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error.withOpacity(0.8),
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _dangerTile(
                  theme,
                  icon: Icons.delete_outline,
                  title: 'Delete Account',
                  subtitle:
                      'Permanently delete your account and all your data',
                  onTap: () => _showDeleteAccountDialog(context),
                ),
                _dangerTile(
                  theme,
                  icon: Icons.logout,
                  title: 'Sign Out',
                  onTap: () => _showSignOutDialog(context),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Section title ──
  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
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

  // ── Info tile (editable or read-only) ──
  Widget _infoTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required bool editing,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: editing
          ? Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              child: TextField(
                controller: controller,
                maxLines: maxLines,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 16,
                ),
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  prefixIcon: Icon(icon,
                      color: theme.colorScheme.primary),
                  border: InputBorder.none,
                ),
              ),
            )
          : ListTile(
              leading: Icon(icon, color: theme.colorScheme.primary),
              title: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.55),
                  fontSize: 12,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  value,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
    );
  }

  // ── Read-only tile (email) ──
  Widget _readonlyTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon,
            color: theme.colorScheme.onSurface.withOpacity(0.55)),
        title: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withOpacity(0.55),
            fontSize: 12,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 15,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon,
          color: theme.colorScheme.onSurface.withOpacity(0.75)),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withOpacity(0.5),
          fontSize: 12,
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

  Widget _dangerTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: theme.colorScheme.error),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: 12,
              ),
            )
          : null,
      onTap: onTap,
    );
  }

  Widget _buildAvatar(ThemeData theme, String? photoUrl) {
    const size = 100.0;
    if (photoUrl == null || photoUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.primary.withOpacity(0.15),
        ),
        child: Icon(Icons.person,
            size: 48, color: theme.colorScheme.primary),
      );
    }

    return ClipOval(
      child: Image.network(
        photoUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            width: size,
            height: size,
            color: theme.colorScheme.primary.withOpacity(0.1),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          debugPrint('Avatar load error: $error');
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withOpacity(0.15),
            ),
            child: Icon(Icons.person,
                size: 48, color: theme.colorScheme.primary),
          );
        },
      ),
    );
  }

  void _showSignOutDialog(BuildContext context) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out?'),
        content: const Text('You will need to sign in again.'),
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
              await authProvider.signOut();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                    context, '/', (route) => false);
              }
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

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
          'This will permanently delete your account and all your data. This action cannot be undone.',
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
                          authProvider.error ?? 'Deletion failed')),
                );
              }
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
