// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

import android.content.Context;
import android.content.SharedPreferences;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.*;

/** Idiomas y unidades como en Datum: elección «auto» o un código; textos desde assets/strings.tsv (base española). */
final class I18n {
    static final String[] CODES = {"es", "en", "de", "fr", "it", "pt", "nl", "sv", "pl", "cs", "uk", "ru", "tr", "id", "vi", "th", "hi", "ja", "ko", "zh", "tw"};
    static final String[] NAMES = {"Español", "English", "Deutsch", "Français", "Italiano", "Português", "Nederlands", "Svenska", "Polski", "Čeština", "Українська", "Русский", "Türkçe", "Bahasa Indonesia", "Tiếng Việt", "ไทย", "हिन्दी", "日本語", "한국어", "简体中文", "繁體中文"};
    private static final HashMap<String, String[]> rows = new HashMap<>();
    private static String[] header = new String[0];
    private static SharedPreferences prefs;
    private static String choice = "auto", unitChoice = "auto", sheetChoice = "auto", explodeChoice = "0", inspectChoice = "0", projChoice = "1", dfmChoice = "0";

    static void init(Context c) {
        if (prefs != null) return;
        prefs = c.getSharedPreferences("diedro", Context.MODE_PRIVATE);
        choice = prefs.getString("lang", "auto");
        unitChoice = prefs.getString("units", "auto");
        sheetChoice = prefs.getString("sheet", "auto");
        explodeChoice = prefs.getString("explode", "0");
        inspectChoice = prefs.getString("inspect", "0");
        projChoice = prefs.getString("proj", "1");
        dfmChoice = prefs.getString("dfm", "0");
        try (BufferedReader r = new BufferedReader(new InputStreamReader(c.getAssets().open("strings.tsv"), "UTF-8"))) {
            String ln = r.readLine();
            header = ln.split("\t", -1);
            while ((ln = r.readLine()) != null) { String[] p = ln.split("\t", -1); if (p.length == header.length) rows.put(p[1], p); }
        } catch (Exception ignored) {}
    }

    static String choice() { return choice; }
    static String unitChoice() { return unitChoice; }
    static String sheetChoice() { return sheetChoice; }
    static String explodeChoice() { return explodeChoice; }
    static String inspectChoice() { return inspectChoice; }
    static String projChoice() { return projChoice; }
    static String dfmChoice() { return dfmChoice; }
    static boolean dfm() { return dfmChoice.equals("1"); }
    static boolean thirdAngle() { return projChoice.equals("3"); }
    static boolean inspect() { return inspectChoice.equals("1"); }
    static boolean explode() { return explodeChoice.equals("1"); }
    /** Formato elegido para el nativo: "" = automático. */
    static String sheet() { return sheetChoice.equals("auto") ? "" : sheetChoice; }
    static void set(String lang, String units, String sheet, String explode, String inspect, String proj, String dfm) {
        dfmChoice = dfm; projChoice = proj; choice = lang; unitChoice = units; sheetChoice = sheet; explodeChoice = explode; inspectChoice = inspect;
        prefs.edit().putString("lang", lang).putString("units", units).putString("sheet", sheet).putString("explode", explode).putString("inspect", inspect).putString("proj", proj).putString("dfm", dfm).apply();
    }

    /** Código de idioma efectivo. */
    static String lang() {
        if (!choice.equals("auto")) return choice;
        Locale l = Locale.getDefault();
        String c = l.getLanguage();
        if (c.equals("in")) c = "id";
        if (c.equals("gl") || c.equals("ca") || c.equals("eu")) return "es";
        if (c.equals("zh")) {
            String s = l.getScript(), k = l.getCountry();
            return s.equals("Hant") || k.equals("TW") || k.equals("HK") || k.equals("MO") ? "tw" : "zh";
        }
        for (String x : CODES) if (x.equals(c)) return c;
        return "en";
    }

    static boolean imperial() {
        if (unitChoice.equals("imperial")) return true;
        if (unitChoice.equals("metric")) return false;
        String k = Locale.getDefault().getCountry();
        return k.equals("US") || k.equals("LR") || k.equals("MM");
    }

    static boolean decimalComma(String l) {
        for (String d : new String[]{"en", "ja", "ko", "zh", "tw", "th", "hi"}) if (d.equals(l)) return false;
        return true;
    }

    /** El PDF solo trae glifos latinos, cirílicos y griegos: el resto de idiomas sale en inglés. */
    static String pdfLang() {
        String l = lang();
        for (String d : new String[]{"ja", "ko", "zh", "tw", "th", "hi"}) if (d.equals(l)) return "en";
        return l;
    }

    static String tr(String es) { return tr(es, lang()); }

    static String tr(String es, String lang) {
        if (lang.equals("es")) return es;
        String[] r = rows.get(es);
        if (r == null) return es;
        int col = Arrays.asList(header).indexOf(lang);
        String t = col > 0 ? r[col] : "";
        if (t.isEmpty()) t = r[2];
        return t.isEmpty() ? es : t;
    }

    static String num(double v) {
        String s = v == Math.rint(v) ? String.valueOf((long) v) : String.format(Locale.US, "%.2f", v);
        return decimalComma(lang()) ? s.replace('.', ',') : s;
    }
}
