// S6-T7 verifier: main's Dart package and main's library against a head-written index (the committed v5 fixture).
import 'dart:ffi';
import 'dart:io';
import 'package:search_simpli/search_simpli.dart';

void main(List<String> args) {
  final lib = DynamicLibrary.open(args[0]);
  final base = args[1];
  final folder = args[2];
  try {
    SearchSimpli.open('$base/fx-open', library: lib);
    print('open: OPENED (not refused)');
  } catch (e) {
    print('open: ${e.runtimeType}: $e');
  }
  try {
    SearchSimpli.applyChanges('$base/fx-apply', {'changes': [{'op': 'add', 'root_id': 'r-legacy', 'path': 'zz-note.md', 'content_base64': 'IyBOb3RlCg=='}]}, library: lib);
    print('applyChanges: WROTE (not refused)');
  } catch (e) {
    print('applyChanges: ${e.runtimeType}: $e');
  }
  try {
    SearchSimpli.indexFolder('$base/fx-index', folder, library: lib);
    print('indexFolder: WROTE (not refused)');
  } catch (e) {
    print('indexFolder: ${e.runtimeType}: $e');
  }
  exit(0);
}
