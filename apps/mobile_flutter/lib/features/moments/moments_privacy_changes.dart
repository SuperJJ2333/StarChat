import 'package:flutter/foundation.dart';

class MomentsPrivacyChanges extends ChangeNotifier {
  int _revision = 0;
  int get revision => _revision;
  void changed() {
    _revision++;
    notifyListeners();
  }
}

final momentsPrivacyChanges = MomentsPrivacyChanges();
