import 'package:flutter/material.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/gen/assets.gen.dart';

class LocalSendLogo extends StatelessWidget {
  final bool withText;

  const LocalSendLogo({required this.withText, super.key});

  @override
  Widget build(BuildContext context) {
    final logo = Semantics(
      image: true,
      label: Brand.name,
      child: Assets.img.logo512.image(
        width: 200,
        height: 200,
        excludeFromSemantics: true,
      ),
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const Text(
            Brand.name,
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}
