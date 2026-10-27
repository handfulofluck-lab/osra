import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../../api/permission_errors.dart';
import '../auth/mfa_reset_messages.dart';

/// The four grantable permission scopes for an invited member (#13).
const kInvitePermissions = ['rules', 'location', 'alerts', 'social'];

/// The permission scope as a label (#419). Unknown values are returned raw, like [mfaResetRoleName].
String familyPermissionName(AppLocalizations l10n, String permission) => switch (permission) {
      'rules' => l10n.familyPermRules,
      'location' => l10n.familyPermLocation,
      'alerts' => l10n.familyPermAlerts,
      'social' => l10n.familyPermSocial,
      _ => permission,
    };

/// Feature #13: family members screen — parents with roles from
/// `/v1/family/me`, an 'Invite member' flow (`POST /v1/family/invites`) and
/// the pending-invite list with owner-side revoke (`DELETE .../invites/:id`).
class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final invites = ref.watch(familyInvitesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.familyMembersTitle)),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(readErrorText(context.l10n, e, () => context.l10n.familyLoadFailed('$e')))),
        data: (overview) {
          final parents = overview.parents.isEmpty && overview.parent.id.isNotEmpty
              // NOTE: older servers omit the parents array — fall back to the
              // signed-in parent so the list is never empty.
              ? [overview.parent]
              : overview.parents;
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(context.l10n.familyParentsHeading, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpace.xs),
              if (parents.isEmpty)
                Card(child: ListTile(leading: const Icon(Icons.person_outline), title: Text(context.l10n.familyNoParents)))
              else
                for (final p in parents)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(p.email.isEmpty ? '?' : p.email[0].toUpperCase())),
                      title: Text(p.displayName.isEmpty ? p.email : p.displayName),
                      subtitle: Text(p.email),
                      trailing: Chip(visualDensity: VisualDensity.compact, label: Text(mfaResetRoleName(context.l10n, p.role))),
                    ),
                  ),
              const SizedBox(height: AppSpace.lg),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(context.l10n.familyInviteMember),
                  onPressed: () => _inviteMember(context, ref),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
              Text(context.l10n.familyPendingInvites, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpace.xs),
              invites.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpace.lg),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Text(readErrorText(context.l10n, e, () => context.l10n.familyInvitesLoadFailed('$e'))),
                data: (items) {
                  final pending = items.where((i) => i.status == 'pending').toList();
                  if (pending.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                      child: Center(child: Text(context.l10n.familyNoPendingInvites)),
                    );
                  }
                  return Column(
                    children: [
                      for (final invite in pending)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.mail_outline),
                            title: Text(invite.email),
                            subtitle: Text('${mfaResetRoleName(context.l10n, invite.role)} · ${invite.permissions.map((p) => familyPermissionName(context.l10n, p)).join(', ')}'),
                            trailing: IconButton(
                              tooltip: context.l10n.familyRevokeInvite,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _revokeInvite(context, ref, invite),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _inviteMember(BuildContext context, WidgetRef ref) async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => const InviteMemberDialog(),
    );
    if (sent == true) ref.invalidate(familyInvitesProvider);
  }

  Future<void> _revokeInvite(BuildContext context, WidgetRef ref, FamilyInvite invite) async {
    try {
      await ref.read(apiClientProvider).raw.delete('/v1/family/invites/${invite.id}');
      ref.invalidate(familyInvitesProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.familyInviteRevoked(invite.email))));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.familyRevokeFailed('$e'))));
      }
    }
  }
}

/// Invite-member dialog (feature #13): email, role (co-parent/guardian) and
/// permission checkboxes → `POST /v1/family/invites`. On success the body
/// switches to the accept token with the test-build share hint; pops true.
class InviteMemberDialog extends ConsumerStatefulWidget {
  const InviteMemberDialog({super.key});

  @override
  ConsumerState<InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends ConsumerState<InviteMemberDialog> {
  final _email = TextEditingController();
  String _role = 'co-parent';
  final _permissions = {for (final p in kInvitePermissions) p: true};
  bool _sending = false;
  String? _error;

  /// Set once the server answers — the form is replaced by the token view.
  String? _acceptToken;
  String? _invitedEmail;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  List<String> get _selectedPermissions =>
      kInvitePermissions.where((p) => _permissions[p] == true).toList();

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = context.l10n.familyEnterEmail);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post(
        '/v1/family/invites',
        data: {'email': email, 'role': _role, 'permissions': _selectedPermissions},
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final invite = data['invite'] is Map ? Map<String, dynamic>.from(data['invite'] as Map) : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _sending = false;
        _acceptToken = data['acceptToken']?.toString();
        _invitedEmail = invite['email']?.toString() ?? email;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final body = e.response?.data;
      setState(() {
        _sending = false;
        _error = body is Map ? '${body['error'] ?? e.message}' : e.message;
      });
    }
  }

  Future<void> _copyToken() async {
    final token = _acceptToken;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.familyTokenCopied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final token = _acceptToken;
    return AlertDialog(
      title: Text(token == null ? context.l10n.familyInviteMember : context.l10n.familyInviteSent),
      content: SingleChildScrollView(
        child: token == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: context.l10n.familyEmailLabel,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  DropdownButtonFormField<String>(
                    initialValue: _role,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: context.l10n.familyRoleLabel,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                    ),
                    items: [
                      DropdownMenuItem(value: 'co-parent', child: Text(context.l10n.familyRoleCoParent)),
                      DropdownMenuItem(value: 'guardian', child: Text(context.l10n.familyRoleGuardian)),
                    ],
                    onChanged: (v) => setState(() => _role = v ?? 'co-parent'),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(context.l10n.familyPermissions, style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final p in kInvitePermissions)
                    CheckboxListTile(
                      dense: true,
                      title: Text(familyPermissionName(context.l10n, p)),
                      value: _permissions[p] ?? true,
                      onChanged: (v) => setState(() => _permissions[p] = v ?? false),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpace.sm),
                    Text(_error!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger)),
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.familyInviteSentTo(_invitedEmail ?? '')),
                  const SizedBox(height: AppSpace.md),
                  SelectableText(
                    token,
                    // Deliberate: the accept token keeps its literal monospace
                    // style; AppType.recoveryCode is 16 px with 0.4 tracking
                    // and would change this dialog's 320 px layout.
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(context.l10n.familyTokenExplanation),
                ],
              ),
      ),
      actions: token == null
          ? [
              TextButton(onPressed: _sending ? null : () => Navigator.of(context).pop(false), child: Text(context.l10n.cancel)),
              FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(context.l10n.familySendInvite),
              ),
            ]
          : [
              TextButton.icon(onPressed: _copyToken, icon: const Icon(Icons.copy), label: Text(context.l10n.familyCopyToken)),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.l10n.familyDone)),
            ],
    );
  }
}
