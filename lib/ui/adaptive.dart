import 'package:flutter/widgets.dart';

/// Keep the phone controls when a handset rotates into landscape.
bool phoneLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 600 || (size.width < 980 && size.height < 600);
}
