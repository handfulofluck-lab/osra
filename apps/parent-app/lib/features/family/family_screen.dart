import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';

/// The four grantable permission scopes for an invited member (#13).
const kInvitePermissions = ['rules', 'location', 'alerts', 'social'];

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
      appBar: AppBar(title: const Text('Family members')),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load family: $e')),
        data: (overview) {
          final parents = overview.parents.isEmpty && overview.parent.id.isNotEmpty
              // NOTE: older servers omit the parents array — fall back to the
              // signed-in parent so the list is never empty.
              ? [overview.parent]
              : overview.parents;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Parents', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              if (parents.isEmpty)
                const Card(child: ListTile(leading: Icon(Icons.person_outline), title: Text('No parents found')))
              else
                for (final p in parents)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(p.email.isEmpty ? '?' : p.email[0].toUpperCase())),
                      title: Text(p.displayName.isEmpty ? p.email : p.displayName),
                      subtitle: Text(p.email),
                      trailing: Chip(visualDensity: VisualDensity.compact, label: Text(p.role)),
                    ),
                  ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Invite member'),
                  onPressed: () => _inviteMember(context, ref),
                ),
              ),
              const SizedBox(height: 24),
              Text('Pending invites', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              invites.when(
                loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                error: (e, _) => Text('Failed to load invites: $e'),
                data: (items) {
                  final pending = items.where((i) => i.status == 'pending').toList();
                  if (pending.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('No pending invites')),
                    );
                  }
                  return Column(
                    children: [
                      for (final invite in pending)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.mail_outline),
                            title: Text(invite.email),
                            subtitle: Text('${invite.role} · ${invite.permissions.join(', ')}'),
                            trailing: IconButton(
                              tooltip: 'Revoke invite',
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invite to ${invite.email} revoked')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Revoke failed: $e')));
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
      setState(() => _error = 'Enter an email address');
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = _acceptToken;
    return AlertDialog(
      title: Text(token == null ? 'Invite member' : 'Invite sent'),
      content: SingleChildScrollView(
        child: token == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _role,
                    decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'co-parent', child: Text('Co-parent')),
                      DropdownMenuItem(value: 'guardian', child: Text('Guardian')),
                    ],
                    onChanged: (v) => setState(() => _role = v ?? 'co-parent'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Permissions', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final p in kInvitePermissions)
                    CheckboxListTile(
                      dense: true,
                      title: Text(p[0].toUpperCase() + p.substring(1)),
                      value: _permissions[p] ?? true,
                      onChanged: (v) => setState(() => _permissions[p] = v ?? false),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Invite sent to $_invitedEmail.'),
                  const SizedBox(height: 12),
                  SelectableText(
                    token,
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text('(test build: share this token — the invited parent registers, then POSTs accept with it)'),
                ],
              ),
      ),
      actions: token == null
          ? [
              TextButton(onPressed: _sending ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
              FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send invite'),
              ),
            ]
          : [
              TextButton.icon(onPressed: _copyToken, icon: const Icon(Icons.copy), label: const Text('Copy token')),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Done')),
            ],
    );
  }
}
