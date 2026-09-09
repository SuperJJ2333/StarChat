import 'package:flutter/foundation.dart';

class MomentsPrivacyChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

final momentsPrivacyChanges = MomentsPrivacyChanges();
