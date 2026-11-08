import 'en.dart';
import 'lang_cs.dart';
import 'lang_nl.dart';
import 'lang_tw.dart';
import 'lang_id.dart';
import 'lang_vi.dart';
import 'lang_th.dart';
import 'lang_hi.dart';
import 'lang_uk.dart';
import 'lang_sv.dart';
import 'lang_de.dart';
import 'lang_zh.dart';
import 'lang_pt.dart';
import 'lang_fr.dart';
import 'lang_ja.dart';
import 'lang_ru.dart';
import 'lang_ko.dart';
import 'lang_it.dart';
import 'lang_tr.dart';
import 'lang_pl.dart';

export 'en.dart' show kEn;

/// Traducciones por idioma: clave = texto en español del código. Cada idioma vive en `lang_<código>.dart`.
/// Si falta una clave en un idioma se usa la inglesa.
const Map<String, Map<String, String>> kTranslations = <String, Map<String, String>>{
  'de': kLang_de,
  'zh': kLang_zh,
  'pt': kLang_pt,
  'fr': kLang_fr,
  'ja': kLang_ja,
  'ru': kLang_ru,
  'ko': kLang_ko,
  'it': kLang_it,
  'tr': kLang_tr,
  'pl': kLang_pl,
  'cs': kLang_cs,
  'nl': kLang_nl,
  'tw': kLang_tw,
  'id': kLang_id,
  'vi': kLang_vi,
  'th': kLang_th,
  'hi': kLang_hi,
  'uk': kLang_uk,
  'sv': kLang_sv,
};
