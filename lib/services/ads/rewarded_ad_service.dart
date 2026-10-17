import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class RewardedAdService {
  static const placementId = 'ca-app-pub-8529698532324480/5652460460';
  RewardedAd? _ad;
  bool _loading = false;
  void preload() {
    if (_ad != null || _loading) return;
    _loading = true;
    RewardedAd.load(adUnitId: placementId, request: const AdRequest(), rewardedAdLoadCallback: RewardedAdLoadCallback(onAdLoaded: (ad) { _loading = false; _ad = ad; }, onAdFailedToLoad: (_) { _loading = false; _ad = null; }));
  }
  Future<bool> showFor1080p() async {
    final ad = _ad; _ad = null; preload();
    if (ad == null) return false;
    final reward = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(onAdDismissedFullScreenContent: (ad) { ad.dispose(); if (!reward.isCompleted) reward.complete(false); preload(); }, onAdFailedToShowFullScreenContent: (ad, _) { ad.dispose(); if (!reward.isCompleted) reward.complete(false); preload(); });
    ad.show(onUserEarnedReward: (_, __) { if (!reward.isCompleted) reward.complete(true); });
    return reward.future;
  }
}
