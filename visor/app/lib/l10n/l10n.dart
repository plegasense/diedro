import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'translations.dart';

/// Idiomas de la interfaz. El texto de partida en el código está en español: [tr] lo devuelve tal cual y,
/// en otro idioma, busca su traducción (`kTranslations[lang]`, y si falta la del inglés `kEn`). Por defecto es
/// español (así los tests y las herramientas no cambian); `main` lo ajusta según el idioma del dispositivo.
class L {
  static String lang = 'es';

  /// País del dispositivo (`PlatformDispatcher.instance.locale.countryCode`), p. ej. 'US'. Lo ajusta `main`;
  /// lo usan las unidades «Automático». Nulo si se desconoce.
  static String? countryCode;
  static bool get en => lang == 'en';

  /// Idiomas con traducción propia además de es/en.
  static const supported = {'de', 'zh', 'pt', 'fr', 'ja', 'ru', 'ko', 'it', 'tr', 'pl', 'cs', 'nl', 'id', 'vi', 'th', 'hi', 'uk', 'sv'};

  /// Español, gallego, catalán y euskera usan la interfaz en español; los idiomas con traducción, la suya;
  /// el resto, inglés. [languageCode] es el del dispositivo (`PlatformDispatcher.instance.locale.languageCode`).
  /// El chino se sirve en escritura tradicional (`tw`) para `Hant` o Taiwán/Hong Kong/Macao.
  static void setFromLanguageCode(String languageCode, {String? scriptCode, String? countryCode}) {
    if (const {'es', 'gl', 'ca', 'eu'}.contains(languageCode)) {
      lang = 'es';
    } else if (languageCode == 'zh' &&
        (scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(countryCode))) {
      lang = 'tw';
    } else if (supported.contains(languageCode)) {
      lang = languageCode;
    } else {
      lang = 'en';
    }
  }

  /// Separador decimal y de miles según el idioma.
  static String get decimal => switch (lang) {
    'en' || 'ja' || 'ko' || 'zh' || 'tw' || 'th' || 'hi' => '.',
    _ => ',',
  };
  static String get thousands => switch (lang) {
    'en' || 'ja' || 'ko' || 'zh' || 'tw' || 'th' || 'hi' => ',',
    'de' || 'it' || 'pt' || 'tr' || 'nl' || 'id' || 'vi' => '.',
    'fr' => '\u202f',
    'ru' || 'pl' || 'cs' || 'uk' || 'sv' => '\u00a0',
    _ => ' ',
  };

  /// Nombre de cada idioma en su propia lengua, para el selector.
  static const names = {
    'es': 'Español', 'en': 'English', 'de': 'Deutsch', 'fr': 'Français', 'it': 'Italiano', 'pt': 'Português',
    'nl': 'Nederlands', 'sv': 'Svenska', 'pl': 'Polski', 'cs': 'Čeština', 'uk': 'Українська', 'ru': 'Русский',
    'tr': 'Türkçe', 'id': 'Bahasa Indonesia', 'vi': 'Tiếng Việt', 'th': 'ไทย', 'hi': 'हिन्दी', 'ja': '日本語',
    'ko': '한국어', 'zh': '简体中文', 'tw': '繁體中文',
  };

  /// Elección del usuario: 'auto' (idioma del dispositivo) o un código de [names]. Al cambiar, la interfaz se reconstruye.
  static final ValueNotifier<String> choice = ValueNotifier('auto');

  /// Aplica [c] ('auto' o un código de [names]) a [lang] y avisa a la interfaz.
  static void apply(String c) {
    if (c != 'auto' && !names.containsKey(c)) c = 'auto';
    if (c == 'auto') {
      final loc = PlatformDispatcher.instance.locale;
      setFromLanguageCode(loc.languageCode, scriptCode: loc.scriptCode, countryCode: loc.countryCode);
    } else {
      lang = c;
    }
    choice.value = c;
  }

  /// Textos sin traducción vistos fuera del español (sólo para depurar).
  static final Set<String> missing = {};
}

/// Traduce [es] (plantilla en español con marcadores `{nombre}`) y rellena los marcadores de [args].
String tr(String es, [Map<String, Object?>? args]) {
  var s = es;
  if (L.lang != 'es') {
    final t = kTranslations[L.lang]?[es] ?? kEn[es];
    if (t == null) {
      L.missing.add(es);
    } else {
      s = t;
    }
  }
  if (args != null) {
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  }
  return s;
}

extension LocalNumber on String {
  /// Pasa un número escrito con punto decimal a la convención del idioma.
  String get ldec => L.decimal == '.' ? this : replaceAll('.', L.decimal);
}

/// Separador de miles del idioma.
String get kThousands => L.thousands;
