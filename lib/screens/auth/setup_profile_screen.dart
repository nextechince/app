import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/app_localizations.dart';
import '../../services/cloudinary_service.dart';

class SetupProfileScreen extends StatefulWidget {
  const SetupProfileScreen({super.key});

  @override
  State<SetupProfileScreen> createState() => _SetupProfileScreenState();
}

class _SetupProfileScreenState extends State<SetupProfileScreen> {
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _isLoading = false;
  String? _usernameError;
  File? _profileImage;
  final ImagePicker _picker = ImagePicker();

  String? _existingUsername;
  bool _isExistingUser = false;
  bool _hasCompleteProfile = false;
  String? _existingAvatarUrl;

  @override
  void initState() {
    super.initState();
    _loadExistingProfile();
  }

  // FIX: read from FirebaseAuth directly, not provider
  String? get _userId => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _loadExistingProfile() async {
    final userId = _userId;
    if (userId == null) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (doc.exists && mounted) {
        final data = doc.data()!;
        final username = data['username'] as String?;
        final displayName = data['display_name'] as String?;
        final bio = data['bio'] as String?;
        final avatarUrl = data['avatar_url'] as String?;

        setState(() {
          _isExistingUser = true;
          _hasCompleteProfile = username != null &&
              username.isNotEmpty &&
              displayName != null &&
              displayName.isNotEmpty;
          _existingUsername = username;
          _existingAvatarUrl = avatarUrl;
          _nameController.text = displayName ?? '';
          _usernameController.text = username ?? '';
          _bioController.text = bio ?? '';
        });
      }
    } catch (e) {
      debugPrint('Load existing profile error: $e');
    }
  }

  void _proceedToApp() {
    if (mounted) Navigator.pushReplacementNamed(context, '/main');
  }

  void _validateUsername(String value) {
    if (value.isEmpty) {
      setState(() => _usernameError = null);
      return;
    }
    if (value.length < 3) {
      setState(() => _usernameError = 'Username too short');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
      setState(() => _usernameError = 'Only letters, numbers, _');
      return;
    }
    setState(() => _usernameError = null);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (pickedFile != null && mounted) {
        setState(() => _profileImage = File(pickedFile.path));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  void _showImagePickerOptions() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
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
              ListTile(
                leading: Icon(Icons.camera_alt_outlined,
                    color: theme.colorScheme.primary),
                title: const Text('Take photo'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library_outlined,
                    color: theme.colorScheme.primary),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
              if (_profileImage != null)
                ListTile(
                  leading: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error),
                  title: Text(
                    'Remove photo',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _profileImage = null);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _uploadProfileImage(String userId) async {
    if (_profileImage == null) return null;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final currentAvatarUrl = userDoc.data()?['avatar_url'] as String?;

      if (currentAvatarUrl != null && currentAvatarUrl.isNotEmpty) {
        await CloudinaryService.deleteFile(currentAvatarUrl);
      }

      final imageUrl = await CloudinaryService.uploadImage(
        _profileImage!,
        'luma/profiles/$userId',
      );

      if (imageUrl == null) throw Exception('Failed to upload image');

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({
        'avatar_url': imageUrl,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return imageUrl;
    } catch (e) {
      debugPrint('Error uploading profile image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload: $e')),
        );
      }
      return null;
    }
  }

  Future<bool> _isUsernameTaken(String username) async {
    if (_isExistingUser &&
        _existingUsername != null &&
        _existingUsername == username) {
      return false;
    }
    try {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isEqualTo: username)
          .limit(1)
          .get();
      return query.docs.isNotEmpty;
    } catch (e) {
      debugPrint('Username check error: $e');
      rethrow;
    }
  }

  Future<void> _completeSetup() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter your name');
      return;
    }
    if (_usernameError != null || _usernameController.text.trim().isEmpty) {
      _showError('Please enter a username');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final userId = _userId;
      if (userId == null) {
        throw Exception('Not authenticated. Please log in again.');
      }

      final username = _usernameController.text.trim();
      final taken = await _isUsernameTaken(username);
      if (taken) {
        setState(() {
          _isLoading = false;
          _usernameError = 'Username already taken';
        });
        return;
      }

      String? photoUrl;
      if (_profileImage != null) {
        photoUrl = await _uploadProfileImage(userId);
        if (photoUrl == null) {
          if (!mounted) return;
          setState(() => _isLoading = false);
          _showError('Image upload failed. Try again.');
          return;
        }
      }

      // Save to Firestore
      final updates = <String, dynamic>{
        'uid': userId,
        'username': username,
        'display_name': _nameController.text.trim(),
        'bio': _bioController.text.trim(),
        'updated_at': FieldValue.serverTimestamp(),
      };
      if (photoUrl != null) updates['avatar_url'] = photoUrl;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set(updates, SetOptions(merge: true));

      // Try to update the provider too, but don't fail if it errors
      try {
        final authProvider =
            Provider.of<LumaAuthProvider>(context, listen: false);
        await authProvider.setupProfile(
          username: username,
          displayName: _nameController.text.trim(),
          bio: _bioController.text.trim().isNotEmpty
              ? _bioController.text.trim()
              : null,
          photoUrl: photoUrl,
          email: FirebaseAuth.instance.currentUser?.email,
        );
      } catch (e) {
        debugPrint('Provider update warning (non-fatal): $e');
      }

      if (!mounted) return;
      setState(() => _isLoading = false);
      Navigator.pushReplacementNamed(context, '/main');
    } catch (e, stackTrace) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      debugPrint('COMPLETE SETUP ERROR: $e');
      debugPrint('STACK: $stackTrace');
      _showError('Error: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // Header
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _hasCompleteProfile ? 'Your Profile' : 'Set up profile',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (_hasCompleteProfile)
                    TextButton(
                      onPressed: _proceedToApp,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.primary,
                        textStyle: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      child: const Text('Proceed'),
                    ),
                ],
              ),

              const SizedBox(height: 8),
              Text(
                _hasCompleteProfile
                    ? 'Review or update your profile info.'
                    : 'Add a name and username so people can find you.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  height: 1.4,
                ),
              ),

              const SizedBox(height: 32),

              // Avatar picker
              Center(
                child: GestureDetector(
                  onTap: _showImagePickerOptions,
                  child: Stack(
                    children: [
                      Container(
                        width: 112,
                        height: 112,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              theme.colorScheme.primary.withOpacity(0.15),
                          image: _profileImage != null
                              ? DecorationImage(
                                  image: FileImage(_profileImage!),
                                  fit: BoxFit.cover,
                                )
                              : _existingAvatarUrl != null
                                  ? DecorationImage(
                                      image: NetworkImage(
                                          _existingAvatarUrl!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                        ),
                        child: _profileImage == null &&
                                _existingAvatarUrl == null
                            ? Icon(
                                Icons.person,
                                size: 48,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
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
                          child: const Icon(
                            Icons.camera_alt,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Tap to add photo',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              _buildField(
                theme,
                label: 'Display name',
                hint: 'Your name',
                icon: Icons.person_outline,
                controller: _nameController,
              ),
              const SizedBox(height: 16),
              _buildField(
                theme,
                label: 'Username',
                hint: 'username',
                icon: Icons.alternate_email,
                controller: _usernameController,
                onChanged: _validateUsername,
                errorText: _usernameError,
                prefix: const Text(
                  '@',
                  style: TextStyle(color: Color(0xFF999999), fontSize: 16),
                ),
              ),
              const SizedBox(height: 16),
              _buildField(
                theme,
                label: 'Bio (optional)',
                hint: 'Tell people about you',
                icon: Icons.edit_note,
                controller: _bioController,
                maxLines: 3,
              ),

              const SizedBox(height: 24),

              // Verification info box
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.verified_outlined,
                        color: theme.colorScheme.primary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Verification',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Verified badges are available for public figures, brands and businesses.',
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

              const SizedBox(height: 32),

              // Buttons
              if (_hasCompleteProfile) ...[
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: _isLoading ? null : _proceedToApp,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                            side: BorderSide(color: theme.dividerColor),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Proceed'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _completeSetup,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Update'),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _completeSetup,
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Complete Setup'),
                  ),
                ),
              ],

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    ThemeData theme, {
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    int maxLines = 1,
    Function(String)? onChanged,
    String? errorText,
    Widget? prefix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon:
                prefix ?? Icon(icon, color: theme.colorScheme.primary),
            errorText: errorText,
          ),
        ),
      ],
    );
  }
}
