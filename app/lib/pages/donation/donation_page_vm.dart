import 'package:localsend_app/model/state/purchase_state.dart';
// [FOSS_REMOVE_START]
// LegnaSend does not ship an in-app purchase provider.
// [FOSS_REMOVE_END]
import 'package:refena_flutter/refena_flutter.dart';

class DonationPageVm {
  final bool platformSupportPayment;
  final Map<PurchaseItem, String> prices;
  final Set<PurchaseItem> purchased;
  final bool pending;
  final void Function(PurchaseItem item) purchase;
  final void Function() restore;

  DonationPageVm({
    required this.platformSupportPayment,
    required this.prices,
    required this.purchased,
    required this.pending,
    required this.purchase,
    required this.restore,
  });
}

// [FOSS_REMOVE_START]
final donationPageVmProvider = donationPageNoopVmProvider;
// [FOSS_REMOVE_END]

/// This is a noop version of the original view model.
/// Used to compile the FOSS version of the app by removing the original provider above.
final donationPageNoopVmProvider = ViewProvider<DonationPageVm>((ref) {
  return DonationPageVm(
    platformSupportPayment: false,
    prices: {},
    purchased: {},
    pending: false,
    purchase: (_) {},
    restore: () {},
  );
});
