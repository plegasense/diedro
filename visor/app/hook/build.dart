// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';


/// Hook de compilación de Datum:
///  1. compila los shaders de Flutter GPU;
///  2. compila el núcleo C++ (core/) enlazado con Open CASCADE para la plataforma de destino.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'datum.shaderbundle.json',
    );

    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final root = input.packageRoot.resolve('../').toFilePath();
    final stub =
        code.targetOS == OS.iOS &&
        code.iOS.targetSdk == IOSSdk.iPhoneSimulator &&
        code.targetArchitecture == Architecture.x64;
    if (stub) {
      // El simulador de iOS en Intel no lleva Open CASCADE: API vacía para que enlace.
      await CBuilder.library(
        name: 'datum_core',
        assetName: 'src/datum_ffi.dart',
        sources: ['../core/src/datum_stub.cpp'],
        includes: ['../core/include'],
        language: Language.cpp,
        std: 'c++17',
      ).run(input: input, output: output, logger: Logger('datum_core'));
      return;
    }
    if (code.targetOS == OS.android) {
      // Diedro: el núcleo (datum_*) ya va dentro de libdiedro_jni.so; se enlaza en vez de duplicar OCCT.
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'src/datum_ffi.dart',
          linkMode: DynamicLoadingSystem(Uri.file('libdiedro_jni.so')),
        ),
      );
      return;
    }
    final occt = _occtInstall(root, code);
    if (!Directory(occt).existsSync()) {
      throw Exception(
        'Falta Open CASCADE para ${code.targetOS}/${code.targetArchitecture}: $occt\n'
        'Compílalo con los scripts de tools/build_occt_*.sh',
      );
    }
    final libNames =
        Directory('$occt/lib')
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.startsWith('libTK') && n.endsWith('.a'))
            .map((n) => n.substring(3, n.length - 2))
            .toList()
          ..sort();

    final builder = CBuilder.library(
      name: 'datum_core',
      assetName: 'src/datum_ffi.dart',
      sources: [
        '../core/src/datum_cad.cpp',
      ],
      includes: [
        '../core/include',
        '$occt/include/opencascade',
      ],
      language: Language.cpp,
      std: 'c++17',
      defines: {'UNORDERED': null, 'HAVE_UNORDERED_MAP': '1', 'LASZIPDLL_EXPORTS': null},
      flags: ['-Wno-deprecated-declarations', '-Wno-#pragma-messages', '-w'],
      libraries: [...libNames, if (code.targetOS == OS.android) ...['m', 'log']],
      libraryDirectories: ['$occt/lib'],
      cppLinkStdLib: code.targetOS == OS.android ? 'c++_static' : null,
      dartBuildFiles: ['hook/build.dart'],
    );
    await builder.run(
      input: input,
      output: output,
      logger: Logger('datum_core')
        ..onRecord.listen((r) => stderr.writeln(r.message)),
    );
    output.dependencies.addAll([
      input.packageRoot.resolve('../core/src/datum_cad.cpp'),
      input.packageRoot.resolve('../core/include/datum.h'),
    ]);
  });
}

String _occtInstall(String root, CodeConfig code) {
  final base = '${root}third_party/_install';
  switch (code.targetOS) {
    case OS.macOS:
      return '$base/occt-macos';
    case OS.iOS:
      final sdk = code.iOS.targetSdk == IOSSdk.iPhoneSimulator
          ? 'simulator'
          : 'device';
      return '$base/occt-ios-$sdk';
    case OS.android:
      final abi = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64-v8a',
        Architecture.x64 => 'x86_64',
        Architecture.arm => 'armeabi-v7a',
        _ => code.targetArchitecture.toString(),
      };
      return '$base/occt-android-$abi';
    default:
      throw UnsupportedError('Plataforma no soportada: ${code.targetOS}');
  }
}
