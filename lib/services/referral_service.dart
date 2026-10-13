import 'api_functions.dart';

class ReferralService {
  Future<String?> ensureCode() async {
    try {
      final result = await FirebaseFunctions.instance.httpsCallable('ensureReferralCode').call();
      final data = Map<String, dynamic>.from(result.data as Map);
      return data['code']?.toString();
    } catch (_) {
      return null;
    }
  }
}
