import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../utils/verified_badge.dart';
import '../../services/cloudinary_service.dart';
// Make sure to import the premium screen we created!
// Adjust the path if your file is in a different folder.
import 'luma_premium_screen.dart'; 

const String _cloudName = 'dn2mwp1lc';
const String _uploadPreset = 'aura_chat';

class AppLocalizations {
  static String currentLanguage = 'en';

  static final Map<String, Map<String, String>> _translations = {
    'en': {
      'settings': 'Settings',
      'account': 'Account',
      'security_change_number': 'Security, change number',
      'privacy': 'Privacy',
      'block_contacts': 'Block contacts, disappearing messages',
      'avatar': 'Avatar',
      'create_edit_photo': 'Create, edit, profile photo',
      'chats': 'Chats',
      'theme_wallpapers': 'Theme, wallpapers, chat history',
      'notifications': 'Notifications',
      'message_group_call_tones': 'Message, group & call tones',
      'storage_and_data': 'Storage and Data',
      'network_usage': 'Network usage, auto-download',
      'app_language': 'App Language',
      'english_default': 'English (device default)',
      'help': 'Help',
      'help_center': 'Help center, contact us, privacy policy',
      'invite_friends': 'Invite Friends',
      'log_out': 'Log Out',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Select Language',
      'cancel': 'Cancel',
      'preferences': 'Preferences',
    },
    'es': {
      'settings': 'Configuración',
      'account': 'Cuenta',
      'security_change_number': 'Seguridad, cambiar número',
      'privacy': 'Privacidad',
      'block_contacts': 'Bloquear contactos, mensajes temporales',
      'avatar': 'Avatar',
      'create_edit_photo': 'Crear, editar, foto de perfil',
      'chats': 'Chats',
      'theme_wallpapers': 'Tema, fondos, historial',
      'notifications': 'Notificaciones',
      'message_group_call_tones': 'Tono de mensajes, grupos y llamadas',
      'storage_and_data': 'Almacenamiento y Datos',
      'network_usage': 'Uso de red, descarga automática',
      'app_language': 'Idioma',
      'english_default': 'Español',
      'help': 'Ayuda',
      'help_center': 'Centro de ayuda, contacto, política',
      'invite_friends': 'Invitar Amigos',
      'log_out': 'Cerrar Sesión',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Seleccionar Idioma',
      'cancel': 'Cancelar',
      'preferences': 'Preferencias',
    },
    'fr': {
      'settings': 'Paramètres',
      'account': 'Compte',
      'security_change_number': 'Sécurité, changer numéro',
      'privacy': 'Confidentialité',
      'block_contacts': 'Bloquer contacts, messages éphémères',
      'avatar': 'Avatar',
      'create_edit_photo': 'Créer, modifier, photo de profil',
      'chats': 'Discussions',
      'theme_wallpapers': 'Thème, fonds, historique',
      'notifications': 'Notifications',
      'message_group_call_tones': 'Sonneries messages, groupes, appels',
      'storage_and_data': 'Stockage et Données',
      'network_usage': 'Usage réseau, téléchargement auto',
      'app_language': 'Langue',
      'english_default': 'Français',
      'help': 'Aide',
      'help_center': 'Centre aide, contact, politique',
      'invite_friends': 'Inviter des Amis',
      'log_out': 'Déconnexion',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Choisir la Langue',
      'cancel': 'Annuler',
      'preferences': 'Préférences',
    },
    'ha': {
      'settings': 'Saituna',
      'account': 'Asusu',
      'security_change_number': 'Tsaro, canza lamba',
      'privacy': 'Sirri',
      'block_contacts': 'Toshe lambobi, saƙonnin da suke ɓacewa',
      'avatar': 'Hoton fuska',
      'create_edit_photo': 'Ƙirƙira, gyara, hoton bayani',
      'chats': 'Sadarwa',
      'theme_wallpapers': 'Jigo, fentin fuska, tarihi',
      'notifications': 'Sanarwa',
      'message_group_call_tones': 'Sautin saƙo, ƙungiya & kira',
      'storage_and_data': 'Majiya da Bayanai',
      'network_usage': 'Amfani da hanyar sadarwa, sauke kai tsaye',
      'app_language': 'Yaren App',
      'english_default': 'Hausa',
      'help': 'Taimako',
      'help_center': 'Cibiyar taimako, tuntuɓa, manufofi',
      'invite_friends': 'Gayyato Abokai',
      'log_out': 'Fita',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Zaɓi Harshe',
      'cancel': 'Soke',
      'preferences': 'Zaɓuɓɓuka',
    },
    'yo': {
      'settings': 'Ètò',
      'account': 'Àkáòwò',
      'security_change_number': 'Ààbò, yí nọ́mbà padà',
      'privacy': 'Àṣírí',
      'block_contacts': 'Dínà àwọn olùbáaṣepọ̀, àwọn ìròyìn tó ń lọ',
      'avatar': 'Àwòrán',
      'create_edit_photo': 'Ṣẹ̀dá, ṣàtúnṣe, àwòrán prófáìlì',
      'chats': 'Ìtàkurọ̀sọ̀',
      'theme_wallpapers': 'Àkọlé, àwòrán bàckgráùnd, ìtàn',
      'notifications': 'Àlàrtì',
      'message_group_call_tones': 'Ohùn ìròyìn, ẹgbẹ́ & ìpè',
      'storage_and_data': 'Ibi ipamọ̀ àti Dátà',
      'network_usage': 'Lò nẹ́twọ́kì, ìgbàsílẹ̀ fúnrarẹ̀',
      'app_language': 'Èdè App',
      'english_default': 'Yorùbá',
      'help': 'Ìrànlọ́wọ́',
      'help_center': 'Ilé ìrànlọ́wọ́, àbọ̀, òfin àṣírí',
      'invite_friends': 'Pè Àwọn Ọ̀rẹ́',
      'log_out': 'Jáde',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Yan Èdè',
      'cancel': 'Fagilé',
      'preferences': 'Àwọn àṣàyàn',
    },
    'ig': {
      'settings': 'Ntọala',
      'account': 'Akaụntụ',
      'security_change_number': 'Nchekwa, ịgbanwe nọmba',
      'privacy': 'Nzuzo',
      'block_contacts': 'Gbochie ndị kọntaktị, ozi na-efu',
      'avatar': 'Foto',
      'create_edit_photo': 'Kepụta, dezie, foto profaịlụ',
      'chats': 'Mkparịta ụka',
      'theme_wallpapers': 'Isiokwu, ihe osise, akụkọ',
      'notifications': 'Nziọkwà',
      'message_group_call_tones': 'Ọkwa ozi, òtù & oku',
      'storage_and_data': 'Nchekwa na Data',
      'network_usage': 'Iji netwọk, ibudata onwe',
      'app_language': 'Asụsụ App',
      'english_default': 'Igbo',
      'help': 'Enyemaka',
      'help_center': 'Ụlọ enyemaka, kọntaktị, iwu nzuzo',
      'invite_friends': 'Kpọọ Ndị Enyi',
      'log_out': 'Pụọ',
      'version': 'Luma Chat v1.0.0',
      'select_language': 'Họrọ Asụsụ',
      'cancel': 'Kagbuo',
      'preferences': 'Mmasị',
    },
  };

  static String get(String key) {
    return _translations[currentLanguage]?[key] ??
        _translations['en']?[key] ??
        key;
  }

  static List<Map<String, String>> get supportedLanguages => [
        {'code': 'en', 'name': 'English'},
        {'code': 'es', 'name': 'Español'},
        {'code': 'fr', 'name': 'Français'},
        {'code': 'ha', 'name': 'Hausa'},
        {'code': 'yo', 'name': 'Yorùbá'},
        {'code': 'ig', 'name': 'Igbo'},
      ];
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  File? _newProfileImage;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('app_language');
    if (savedLang != null && mounted) {
      setState(() => AppLocalizations.currentLanguage = savedLang);
    }
  }

  Future<void> _pickNewProfileImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() {
      _newProfileImage = File(picked.path);
      _isUploading = true;
    });

    await _uploadProfileImage();
  }

  Future<void> _uploadProfileImage() async {
    if (_newProfileImage == null) return;

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final currentAvatarUrl = userDoc.data()?['avatar_url'] as String?;

      if (currentAvatarUrl != null && currentAvatarUrl.isNotEmpty) {
        await CloudinaryService.deleteFile(currentAvatarUrl);
      }

      final fileBytes = await _newProfileImage!.readAsBytes();
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

      final publicUrl = jsonData['secure_url'] as String;

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'avatar_url': publicUrl,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await authProvider.updateProfile(photoUrl: publicUrl);

      if (!mounted) return;
      setState(() => _isUploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AppLocalizations.get('avatar')} updated!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isUploading = false);
      debugPrint('Cloudinary upload error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to upload: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _backupChats() async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      final userEmail = authProvider.user?.email;

      if (userId == null) {
        _showBackupError('Not authenticated');
        return;
      }

      if (mounted) setState(() => _isUploading = true);

      final chatsSnapshot = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: userId)
          .get();

      final backupData = <Map<String, dynamic>>[];

      for (final chatDoc in chatsSnapshot.docs) {
        final chatId = chatDoc.id;
        final messagesSnapshot = await FirebaseFirestore.instance
            .collection('chats')
            .doc(chatId)
            .collection('messages')
            .orderBy('created_at')
            .get();

        final messages = messagesSnapshot.docs.map((m) {
          final data = m.data();
          final ts = data['created_at'] ?? data['timestamp'];
          return {
            'id': m.id,
            'sender_id': data['sender_id'],
            'text': data['text'],
            'created_at':
                ts is Timestamp ? ts.toDate().toIso8601String() : null,
            'type': data['type'] ?? 'text',
            'media_url': data['media_url'],
          };
        }).toList();

        backupData.add({
          'chat_id': chatId,
          'participants': chatDoc.data()['participants'],
          'messages': messages,
        });
      }

      final jsonString = jsonEncode({
        'exported_at': DateTime.now().toIso8601String(),
        'user_id': userId,
        'chats': backupData,
      });

      final tempDir = Directory.systemTemp;
      final fileName =
          'luma_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(jsonString);

      if (mounted) setState(() => _isUploading = false);

      final emailBody = Uri.encodeComponent(
        'Luma Chat Backup\n\n'
        'Exported: ${DateTime.now().toIso8601String()}\n'
        'Chats backed up: ${backupData.length}\n\n'
        'Please attach the backup file from:\n${file.path}\n\n'
        'To restore: Save this email and use Restore in Luma Chat settings.',
      );

      final emailSubject = Uri.encodeComponent(
          'Luma Chat Backup - ${DateTime.now().toLocal()}');
      final emailUri = Uri.parse(
          'mailto:${userEmail ?? ''}?subject=$emailSubject&body=$emailBody');

      if (await canLaunchUrl(emailUri)) {
        await launchUrl(emailUri);
      } else {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Backup Ready'),
            content: Text(
              'Chat backup saved locally.\n\nFile: ${file.path}\n\n'
              '${backupData.length} chats backed up.\n\n'
              'Please manually email this file to yourself for safekeeping.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _isUploading = false);
      _showBackupError('Backup failed: $e');
    }
  }

  void _showBackupError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showLanguagePicker() {
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
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    AppLocalizations.get('select_language'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...AppLocalizations.supportedLanguages.map((lang) {
                final isSelected =
                    AppLocalizations.currentLanguage == lang['code'];
                return ListTile(
                  leading: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                  title: Text(
                    lang['name']!,
                    style: TextStyle(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  onTap: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString(
                        'app_language', lang['code']!);
                    if (!mounted) return;
                    setState(() {
                      AppLocalizations.currentLanguage = lang['code']!;
                    });
                    Navigator.pop(context);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // NEW LOGOUT FLOW (Card Style + Phone Verification)
  // =========================================================================
  Future<void> _logOut() async {
    final authProvider = Provider.of<LumaAuthProvider>(context, listen: false);

    // 1. Beautiful Card Popup
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Theme.of(ctx).brightness == Brightness.dark 
            ? const Color(0xFF1F2C34) 
            : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.logout, color: Colors.red, size: 32),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.get('log_out'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Are you sure you want to log out of Luma Chat?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Theme.of(ctx).dividerColor),
                        ),
                      ),
                      child: Text(
                        AppLocalizations.get('cancel'),
                        style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Log Out', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      // 2. Sign out
      await authProvider.signOut();

      if (!mounted) return;

      // 3. Go to Phone Verification Screen (Make sure this route exists in your router!)
      Navigator.pushNamedAndRemoveUntil(context, '/phone_verification', (route) => false);
      
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to log out. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);
    final username = authProvider.userName ?? 'Unknown';
    final displayName = authProvider.displayName ?? username;
    final email = authProvider.email ?? '';
    final avatar = authProvider.userPhotoUrl;
    final userVerified = isVerified(email);

    final currentLang = AppLocalizations.supportedLanguages.firstWhere(
      (l) => l['code'] == AppLocalizations.currentLanguage,
      orElse: () => {'code': 'en', 'name': 'English'},
    );

    // Dynamic Pricing for Luma Premium Banner
    final countryCode = Localizations.localeOf(context).countryCode;
    final premiumPriceText = countryCode == 'NG' ? '₦2,000/mo' : '\$4.99/mo';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppLocalizations.get('settings'),
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  // Profile header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap:
                              _isUploading ? null : _pickNewProfileImage,
                          child: Stack(
                            children: [
                              _buildAvatar(theme, avatar, _newProfileImage),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color:
                                          theme.scaffoldBackgroundColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: _isUploading
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child:
                                              CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.camera_alt,
                                          size: 12, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      displayName,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 17,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (userVerified) ...[
                                    const SizedBox(width: 6),
                                    const VerifiedBadge(
                                        size: 14, showTooltip: false),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '@$username',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.55),
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                email,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.45),
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.qr_code,
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.7)),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),

                  // =================================================================
                  // LUMA PREMIUM BANNER
                  // =================================================================
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context, 
                      MaterialPageRoute(builder: (_) => const LumaPremiumScreen())
                    ),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF2B2B2B), Color(0xFF1A1A1A)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFD4A73A), width: 1),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.stars, color: Color(0xFFD4A73A), size: 32),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Luma Premium',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                Text(
                                  'Get exclusive features • $premiumPriceText',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.white54),
                        ],
                      ),
                    ),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  _sectionTitle(theme, AppLocalizations.get('account')),
                  _tile(
                    theme,
                    icon: Icons.key_outlined,
                    title: AppLocalizations.get('account'),
                    subtitle:
                        AppLocalizations.get('security_change_number'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/account_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.lock_outline,
                    title: AppLocalizations.get('privacy'),
                    subtitle: AppLocalizations.get('block_contacts'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/privacy_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.face_outlined,
                    title: AppLocalizations.get('avatar'),
                    subtitle: AppLocalizations.get('create_edit_photo'),
                    onTap: _pickNewProfileImage,
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  _sectionTitle(theme, AppLocalizations.get('preferences')),
                  _tile(
                    theme,
                    icon: Icons.chat_bubble_outline,
                    title: AppLocalizations.get('chats'),
                    subtitle: AppLocalizations.get('theme_wallpapers'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/appearance'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.notifications_none,
                    title: AppLocalizations.get('notifications'),
                    subtitle:
                        AppLocalizations.get('message_group_call_tones'),
                    onTap: () => Navigator.pushNamed(
                        context, '/notifications_settings'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.storage_outlined,
                    title: AppLocalizations.get('storage_and_data'),
                    subtitle: AppLocalizations.get('network_usage'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/data_storage'),
                  ),
                  _tile(
                    theme,
                    icon: Icons.language_outlined,
                    title: AppLocalizations.get('app_language'),
                    subtitle: currentLang['name']!,
                    onTap: _showLanguagePicker,
                  ),
                  _tile(
                    theme,
                    icon: Icons.backup_outlined,
                    title: 'Backup Chats',
                    subtitle: 'Export chat history to email',
                    onTap: _backupChats,
                  ),
                  _tile(
                    theme,
                    icon: Icons.restore_outlined,
                    title: 'Restore Chats',
                    subtitle: 'Import chat history from backup',
                    onTap: () =>
                        Navigator.pushNamed(context, '/restore_chats'),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  _sectionTitle(theme, AppLocalizations.get('help')),
                  _tile(
                    theme,
                    icon: Icons.help_outline,
                    title: AppLocalizations.get('help'),
                    subtitle: AppLocalizations.get('help_center'),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content:
                                Text('Help center coming soon')),
                      );
                    },
                  ),
                  _tile(
                    theme,
                    icon: Icons.people_outline,
                    title: AppLocalizations.get('invite_friends'),
                    onTap: () =>
                        Navigator.pushNamed(context, '/invite_friends'),
                  ),

                  Divider(height: 0.5, color: theme.dividerColor),

                  ListTile(
                    leading: Icon(Icons.logout,
                        color: theme.colorScheme.error),
                    title: Text(
                      AppLocalizations.get('log_out'),
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                      ),
                    ),
                    onTap: _logOut,
                  ),

                  const SizedBox(height: 32),

                  Center(
                    child: Text(
                      AppLocalizations.get('version'),
                      style: TextStyle(
                        color:
                            theme.colorScheme.onSurface.withOpacity(0.3),
                        fontSize: 12,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(
      ThemeData theme, String? avatarUrl, File? localFile) {
    const size = 72.0;

    if (localFile != null) {
      return ClipOval(
        child: Image.file(localFile,
            width: size, height: size, fit: BoxFit.cover),
      );
    }

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.primary.withOpacity(0.15),
        ),
        child: Icon(Icons.person,
            color: theme.colorScheme.primary, size: 34),
      );
    }

    return ClipOval(
      child: Image.network(
        avatarUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            width: size,
            height: size,
            color: theme.colorScheme.primary.withOpacity(0.15),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary.withOpacity(0.15),
          ),
          child: Icon(Icons.person,
              color: theme.colorScheme.primary, size: 34),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
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
          ? Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.5),
                ),
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
}
