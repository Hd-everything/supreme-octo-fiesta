import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

class RewardedAdService {
  static const placementId = 'ca-app-pub-8529698532324480/5652460460';

  RewardedAd? _ad;
  Future<RewardedAd?>? _loadingAd;

  /// Starts filling the next ad while the user edits media.
  Future<void> preload() async {
    await _loadAd();
  }

  Future<RewardedAd?> _loadAd() {
    if (_ad case final ready?) return Future.value(ready);
    if (_loadingAd case final pending?) return pending;

    final completer = Completer<RewardedAd?>();
    _loadingAd = completer.future;
    RewardedAd.load(
      adUnitId: placementId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          if (!completer.isCompleted) completer.complete(ad);
        },
        onAdFailedToLoad: (_) {
          _ad = null;
          if (!completer.isCompleted) completer.complete(null);
        },
      ),
    );
    return completer.future.whenComplete(() {
      if (identical(_loadingAd, completer.future)) _loadingAd = null;
    });
  }

  Future<bool> showFor1080p() async {
    // A tap can happen before the background preload finishes. Wait briefly
    // for that request instead of turning an ad load race into a lost reward.
    final ad = _ad ?? await _loadAd().timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (ad == null) {
      unawaited(preload());
      return false;
    }
    if (identical(_ad, ad)) _ad = null;

    final reward = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (closedAd) {
        closedAd.dispose();
        if (!reward.isCompleted) reward.complete(earned);
        unawaited(preload());
      },
      onAdFailedToShowFullScreenContent: (failedAd, _) {
        failedAd.dispose();
        if (!reward.isCompleted) reward.complete(false);
        unawaited(preload());
      },
    );

    try {
      ad.show(onUserEarnedReward: (_, __) {
        earned = true;
      });
    } catch (_) {
      ad.dispose();
      unawaited(preload());
      return false;
    }
    return reward.future;
  }
}
