// dart format width=150

/// GENERATED CODE - DO NOT MODIFY BY HAND
/// *****************************************************
///  FlutterGen
/// *****************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: deprecated_member_use,directives_ordering,implicit_dynamic_list_literal,unnecessary_import

import 'package:flutter/widgets.dart';

class $AssetsApiDocsGen {
  const $AssetsApiDocsGen();

  /// File path: assets/api_docs/DIRECTORY_API.md
  String get directoryApi => 'assets/api_docs/DIRECTORY_API.md';

  /// File path: assets/api_docs/DIRECTORY_API_ZH.md
  String get directoryApiZh => 'assets/api_docs/DIRECTORY_API_ZH.md';

  /// File path: assets/api_docs/INTEGRATION_API.md
  String get integrationApi => 'assets/api_docs/INTEGRATION_API.md';

  /// File path: assets/api_docs/INTEGRATION_API_ZH.md
  String get integrationApiZh => 'assets/api_docs/INTEGRATION_API_ZH.md';

  /// File path: assets/api_docs/integration-openapi-en.json
  String get integrationOpenapiEn => 'assets/api_docs/integration-openapi-en.json';

  /// File path: assets/api_docs/integration-openapi-zh-CN.json
  String get integrationOpenapiZhCN => 'assets/api_docs/integration-openapi-zh-CN.json';

  /// File path: assets/api_docs/integration-openapi-zh-HK.json
  String get integrationOpenapiZhHK => 'assets/api_docs/integration-openapi-zh-HK.json';

  /// File path: assets/api_docs/integration-openapi-zh-TW.json
  String get integrationOpenapiZhTW => 'assets/api_docs/integration-openapi-zh-TW.json';

  /// List of all assets
  List<String> get values => [
    directoryApi,
    directoryApiZh,
    integrationApi,
    integrationApiZh,
    integrationOpenapiEn,
    integrationOpenapiZhCN,
    integrationOpenapiZhHK,
    integrationOpenapiZhTW,
  ];
}

class $AssetsImgGen {
  const $AssetsImgGen();

  /// File path: assets/img/logo-128.png
  AssetGenImage get logo128 => const AssetGenImage('assets/img/logo-128.png');

  /// File path: assets/img/logo-256.png
  AssetGenImage get logo256 => const AssetGenImage('assets/img/logo-256.png');

  /// File path: assets/img/logo-32-black.png
  AssetGenImage get logo32Black => const AssetGenImage('assets/img/logo-32-black.png');

  /// File path: assets/img/logo-32-white.png
  AssetGenImage get logo32White => const AssetGenImage('assets/img/logo-32-white.png');

  /// File path: assets/img/logo-32.png
  AssetGenImage get logo32 => const AssetGenImage('assets/img/logo-32.png');

  /// File path: assets/img/logo-512-white.png
  AssetGenImage get logo512White => const AssetGenImage('assets/img/logo-512-white.png');

  /// File path: assets/img/logo-512.png
  AssetGenImage get logo512 => const AssetGenImage('assets/img/logo-512.png');

  /// File path: assets/img/logo.ico
  String get logo => 'assets/img/logo.ico';

  /// List of all assets
  List<dynamic> get values => [logo128, logo256, logo32Black, logo32White, logo32, logo512White, logo512, logo];
}

abstract final class Assets {
  static const String changelog = 'assets/CHANGELOG.md';
  static const String changelogZh = 'assets/CHANGELOG_ZH.md';
  static const String changelogZhHant = 'assets/CHANGELOG_ZH_HANT.md';
  static const $AssetsApiDocsGen apiDocs = $AssetsApiDocsGen();
  static const $AssetsImgGen img = $AssetsImgGen();

  /// List of all assets
  static List<String> get values => [changelog, changelogZh, changelogZhHant];
}

class AssetGenImage {
  const AssetGenImage(this._assetName, {this.size, this.flavors = const {}, this.animation});

  final String _assetName;

  final Size? size;
  final Set<String> flavors;
  final AssetGenImageAnimation? animation;

  Image image({
    Key? key,
    AssetBundle? bundle,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
    String? semanticLabel,
    bool excludeFromSemantics = false,
    double? scale,
    double? width,
    double? height,
    Color? color,
    Animation<double>? opacity,
    BlendMode? colorBlendMode,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    ImageRepeat repeat = ImageRepeat.noRepeat,
    Rect? centerSlice,
    bool matchTextDirection = false,
    bool gaplessPlayback = true,
    bool isAntiAlias = false,
    String? package,
    FilterQuality filterQuality = FilterQuality.medium,
    int? cacheWidth,
    int? cacheHeight,
  }) {
    return Image.asset(
      _assetName,
      key: key,
      bundle: bundle,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      scale: scale,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      isAntiAlias: isAntiAlias,
      package: package,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }

  ImageProvider provider({AssetBundle? bundle, String? package}) {
    return AssetImage(_assetName, bundle: bundle, package: package);
  }

  String get path => _assetName;

  String get keyName => _assetName;
}

class AssetGenImageAnimation {
  const AssetGenImageAnimation({required this.isAnimation, required this.duration, required this.frames});

  final bool isAnimation;
  final Duration duration;
  final int frames;
}
