import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class StatusHdAdBanner extends StatefulWidget {
  const StatusHdAdBanner({super.key});

  @override
  State<StatusHdAdBanner> createState() => _StatusHdAdBannerState();
}

class _StatusHdAdBannerState extends State<StatusHdAdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final ad = BannerAd(
      adUnitId: 'ca-app-pub-8529698532324480/5652460460',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(onAdLoaded: (ad) { if (mounted) setState(() { _ad = ad as BannerAd; _loaded = true; }); }, onAdFailedToLoad: (ad, _) { ad.dispose(); }),
    );
    _ad = ad;
    ad.load();
  }

  @override
  void dispose() { _ad?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _ad == null) return const SizedBox.shrink();
    return Semantics(label: 'Advertisement', container: true, child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SizedBox(width: _ad!.size.width.toDouble(), height: _ad!.size.height.toDouble(), child: AdWidget(ad: _ad!))));
  }
}
