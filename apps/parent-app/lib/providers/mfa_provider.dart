import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/mfa_api.dart';
import 'auth_provider.dart';

/// MFA routes, built on the same injected [ApiClient] as every other screen so
/// tests can answer them from a route table.
final mfaApiProvider = Provider<MfaApi>((ref) => MfaApi(ref.watch(apiClientProvider)));

/// A one-shot notice shown on the login screen. `/mfa/verify` revokes every
/// session, so the app must say why the parent is signing in again instead of
/// silently landing back on the login form.
const kLoginNoticeMfaSessionEnded = 'mfa_session_ended';

final loginNoticeProvider = StateProvider<String?>((ref) => null);
