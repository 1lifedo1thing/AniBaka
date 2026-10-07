import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showSnackBar(
  String text, {
  ToastGravity gravity = ToastGravity.BOTTOM,
  bool isError = false,
  SnackBarAction? action,
}) {
  if (action != null ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: action == null ? 2 : 4),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? const Color(0xFFD32F2F) : null,
        action: action,
      ),
    );
  } else {
    Fluttertoast.showToast(
      msg: text,
      gravity: gravity,
      backgroundColor: isError ? const Color(0xFFD32F2F) : null,
    );
  }
}
