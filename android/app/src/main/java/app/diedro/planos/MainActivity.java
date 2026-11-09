package app.diedro.planos;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.*;
import java.io.*;

public class MainActivity extends Activity {
    private static final int PICK = 1, SAVE = 2, SAVEPROJ = 3, EXPORT = 4, EXPORTDIR = 5, SAVECSV = 6;
    private final java.util.LinkedHashMap<String, String> tols = new java.util.LinkedHashMap<>();
    private File step, pdf;
    private FrameLayout rootFrame;
    private View home, work;
    private ZoomView zoom;
    private TextView headTitle, status;
    private EditText title, partNo, material, tol;
    private LinearLayout results;
    private TextView update, saveBtn;
    private String stepName = "";
    private java.util.ArrayList<float[]> markFrac = new java.util.ArrayList<>();
    private java.util.ArrayList<int[]> markPos = new java.util.ArrayList<>();  // {nº de globo, índice de pieza en el STEP}
    private FrameLayout visorBox;
    private java.util.ArrayList<float[]> holeRefs = new java.util.ArrayList<>();  // {x, y (fracción de hoja), px,py,pz, ax,ay,az}

    // Agujeros del plano <-> visor 3D: se enlazan por la recta del eje (coordenadas del STEP).
    private java.util.ArrayList<float[]> viewRefs = new java.util.ArrayList<>();  // {ox,oy, ex(2), ey(2), ez(2), x0,y0,x1,y1} en fracción de hoja
    private double[] sec = null;  // sección del visor: {eje, posición}

    // Traza en el plano la sección activa del visor: en las vistas donde el plano de corte se ve de canto.
    private void applySection() {
        java.util.ArrayList<Float> l = new java.util.ArrayList<>();
        if (sec != null) for (float[] r : viewRefs) {
            int k = (int) sec[0];
            float ex = r[2 + 2 * k], ey = r[3 + 2 * k];
            if (Math.abs(ex) + Math.abs(ey) < 1e-6f) continue;
            float px = r[0] + (float) sec[1] * ex, py = r[1] + (float) sec[1] * ey;
            float mx = 0.02f;
            if (Math.abs(ex) > Math.abs(ey)) { l.add(px); l.add(Math.min(r[9], r[11]) - mx); l.add(px); l.add(Math.max(r[9], r[11]) + mx); }
            else { l.add(Math.min(r[8], r[10]) - mx); l.add(py); l.add(Math.max(r[8], r[10]) + mx); l.add(py); }
        }
        float[] a = new float[l.size()];
        for (int i = 0; i < a.length; i++) a[i] = l.get(i);
        zoom.setSecLines(a);
    }

    private void applyHoles(Bitmap b) {
        applySection();
        float[] xy = new float[2 * holeRefs.size()];
        for (int i = 0; i < holeRefs.size(); i++) { xy[2 * i] = holeRefs.get(i)[0] * b.getWidth(); xy[2 * i + 1] = holeRefs.get(i)[1] * b.getHeight(); }
        zoom.setHoles(xy, i -> {
            zoom.setLitHoles(java.util.Collections.singleton(i));
            float[] h = holeRefs.get(i);
            java.util.ArrayList<Double> l = new java.util.ArrayList<>();
            for (int k = 2; k < 8; k++) l.add((double) h[k]);
            if (visorBox.getVisibility() != View.VISIBLE) {
                boolean cold = VisorHost.engine == null || !step.getPath().equals(VisorHost.loaded == null ? "" : VisorHost.loaded.split("\\|")[0]);
                setMode(1);
                new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> VisorHost.channel(this).invokeMethod("holeAt", l), cold ? 4500 : 300);
            } else VisorHost.channel(this).invokeMethod("holeAt", l);
        });
    }

    private static boolean sameAxis(float[] h, java.util.List<?> v) {
        double[] q = new double[6];
        for (int k = 0; k < 6; k++) q[k] = ((Number) v.get(k)).doubleValue();
        double cx = h[6] * q[5] - h[7] * q[4], cy = h[7] * q[3] - h[5] * q[5], cz = h[5] * q[4] - h[6] * q[3];
        if (Math.sqrt(cx * cx + cy * cy + cz * cz) > 1e-3) return false;
        double dx = q[0] - h[2], dy = q[1] - h[3], dz = q[2] - h[4], dot = dx * h[5] + dy * h[6] + dz * h[7];
        return Math.sqrt(Math.pow(dx - dot * h[5], 2) + Math.pow(dy - dot * h[6], 2) + Math.pow(dz - dot * h[7], 2)) < 0.05;
    }

    // Globos del plano tocables: al tocar uno se selecciona su pieza en el visor 3D; la selección 3D ilumina su globo.
    private void applyMarks(Bitmap b) {
        float[] xy = new float[2 * markFrac.size()];
        int[] ids = new int[markFrac.size()];
        for (int i = 0; i < ids.length; i++) { xy[2 * i] = markFrac.get(i)[0] * b.getWidth(); xy[2 * i + 1] = markFrac.get(i)[1] * b.getHeight(); ids[i] = markPos.get(i)[1]; }
        zoom.setMarks(xy, ids, id -> {
            zoom.setLit(java.util.Collections.singleton(id));
            java.util.ArrayList<Integer> l = new java.util.ArrayList<>(); l.add(id);
            if (visorBox.getVisibility() != View.VISIBLE) {
                boolean cold = VisorHost.engine == null || !step.getPath().equals(VisorHost.loaded == null ? "" : VisorHost.loaded.split("\\|")[0]);
                setMode(1);
                new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> VisorHost.channel(this).invokeMethod("select", l), cold ? 4500 : 300);
            } else VisorHost.channel(this).invokeMethod("select", l);
        });
    }
    private io.flutter.embedding.android.FlutterView visorView;

    // Visor 3D de Datum junto al plano; al ocultarlo se desengancha del motor (que se conserva).
    private void show3d() {
        if (step == null || visorBox == null || visorView != null) return;
        visorBox.setVisibility(View.VISIBLE);
        boolean first = VisorHost.engine == null;
        io.flutter.plugin.common.MethodChannel ch = VisorHost.channel(this);
        ch.setMethodCallHandler((call, res) -> {
            if (call.method.equals("selected")) {
                java.util.HashSet<Integer> ids = new java.util.HashSet<>();
                for (Object o : (java.util.List<?>) call.arguments) ids.add(((Number) o).intValue());
                zoom.setLit(ids);
            } else if (call.method.equals("section")) {
                java.util.List<?> v = (java.util.List<?>) call.arguments;
                sec = v != null && v.size() >= 2 ? new double[]{((Number) v.get(0)).doubleValue(), ((Number) v.get(1)).doubleValue()} : null;
                applySection();
            } else if (call.method.equals("hole")) {
                java.util.List<?> v = (java.util.List<?>) call.arguments;
                java.util.HashSet<Integer> hs = new java.util.HashSet<>();
                if (v != null && v.size() >= 6) for (int i = 0; i < holeRefs.size(); i++) if (sameAxis(holeRefs.get(i), v)) hs.add(i);
                zoom.setLitHoles(hs);
            }
            res.success(null);
        });
        visorView = new io.flutter.embedding.android.FlutterView(this, new io.flutter.embedding.android.FlutterSurfaceView(this));
        visorBox.addView(visorView, new FrameLayout.LayoutParams(-1, -1));
        visorView.attachToFlutterEngine(VisorHost.engine);
        sendVisorConfig();
        VisorHost.engine.getLifecycleChannel().appIsResumed();
        String path = step.getPath() + "|" + step.lastModified();
        if (path.equals(VisorHost.loaded)) return;
        VisorHost.loaded = path;
        String f = step.getPath();
        if (first) new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> ch.invokeMethod("open", java.util.Arrays.asList(f, stepName)), 1500);
        else ch.invokeMethod("open", java.util.Arrays.asList(f, stepName));
    }

    /** El visor no tiene ajustes propios: usa el idioma y las unidades elegidos en Diedro. */
    private void sendVisorConfig() {
        if (VisorHost.engine != null) VisorHost.channel(this).invokeMethod("config", java.util.Arrays.asList(I18n.choice(), I18n.unitChoice()));
    }

    // Modos de pantalla: 0 plano, 1 dividido (plano + 3D), 2 solo 3D. El cajón «Datos» se desliza sobre cualquiera.
    private int mode = 0;
    private boolean drawerOpen = true;
    private LinearLayout body;
    private FrameLayout viewerBox;
    private View drawer;
    private TextView[] modeBtn = new TextView[3];
    private TextView dataBtn;

    private void setMode(int m) {
        if (m != 0 && step == null) return;
        mode = m;
        if (m != 0 && ed.on) toggleEdit();
        if (dwrapV != null) { dwrapV.setVisibility(m != 0 ? View.GONE : View.VISIBLE); ewrapV.setVisibility(m != 0 ? View.GONE : View.VISIBLE); }
        if (m == 0) hide3d(); else { visorBox.setVisibility(View.VISIBLE); show3d(); }
        viewerBox.setVisibility(m == 2 ? View.GONE : View.VISIBLE);
        layoutPanes();
        for (int i = 0; i < 3; i++) {
            boolean on = i == m;
            modeBtn[i].setBackground(on ? Ui.rr(this, Ui.TEAL, 20) : null);
            modeBtn[i].setTextColor(on ? 0xFF06201C : Ui.TEXT);
        }
    }

    private void layoutPanes() {
        android.content.res.Configuration cf = getResources().getConfiguration();
        boolean land = cf.screenWidthDp > cf.screenHeightDp, wide = cf.screenWidthDp >= 700;
        body.setOrientation(land ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        boolean both = mode == 1;
        int dh = (int) (getResources().getDisplayMetrics().heightPixels * 0.5f);
        FrameLayout.LayoutParams dl = (FrameLayout.LayoutParams) drawer.getLayoutParams();
        if (wide || land) { dl.width = dp(360); dl.height = -1; dl.gravity = Gravity.END; }
        else { dl.width = -1; dl.height = dh; dl.gravity = Gravity.BOTTOM; }
        dl.setMargins((wide || land) ? 0 : dp(8), 0, dp(8), dp(10));   // vertical: mismo margen a ambos lados (antes se pegaba al borde izquierdo)
        drawer.setLayoutParams(dl);
        boolean showDrawer = drawerOpen && mode == 0;
        drawer.setVisibility(showDrawer ? View.VISIBLE : View.GONE);
        body.setPadding(0, 0, showDrawer && (wide || land) ? dp(366) : 0, showDrawer && !(wide || land) ? dh + dp(6) : 0);
        for (View p : new View[]{viewerBox, visorBox}) {
            LinearLayout.LayoutParams l = new LinearLayout.LayoutParams(land ? 0 : -1, land ? -1 : 0, 1f);
            boolean first = p == viewerBox || mode == 2;
            l.setMargins(dp(14), 0, dp(14), dp(10));
            if (both && land) { l.leftMargin = p == viewerBox ? dp(14) : dp(4); l.rightMargin = p == viewerBox ? dp(4) : dp(14); }
            p.setLayoutParams(l);
        }
        body.requestLayout();
    }

    @Override public void onConfigurationChanged(android.content.res.Configuration c) { super.onConfigurationChanged(c); layoutPanes(); fitHome(); }   // rotación: antes el diseño quedaba como en la orientación anterior

    private void setDrawer(boolean open) {
        drawerOpen = open;
        dataBtn.setBackground(open ? Ui.rr(this, Ui.TEAL, 20) : null);
        dataBtn.setTextColor(open ? 0xFF06201C : Ui.TEXT);
        layoutPanes();
    }

    private TextView seg(String s) {
        TextView t = Ui.text(this, s, 14, Ui.TEXT, true);
        t.setGravity(Gravity.CENTER);
        boolean nw = getResources().getConfiguration().screenWidthDp < 440;
        int px = nw ? 7 : 16;
        if (nw) t.setTextSize(13);  // pantallas estrechas: que quepan Plano/Dividido/3D/Editar/Datos
        t.setSingleLine(true);
        t.setPadding(dp(px), dp(8), dp(px), dp(8));
        Ui.press(t);
        return t;
    }

    private TextView maxBtn(int target) {  // ⤢: pone este panel a pantalla completa, o vuelve al dividido
        TextView b = Ui.text(this, "⤢", 20, Ui.TEXT, true);
        b.setGravity(Gravity.CENTER);
        b.setBackground(Ui.rr(this, 0xAA17222E, 18));
        Ui.press(b);
        b.setOnClickListener(v -> setMode(mode == target ? 1 : target));
        return b;
    }

    private void hide3d() {
        if (visorView != null) { visorView.detachFromFlutterEngine(); visorBox.removeView(visorView); visorView = null; }
        visorBox.setVisibility(View.GONE);
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        I18n.init(this);
        rootFrame = new FrameLayout(this);
        rootFrame.setBackground(bg());
        buildUi();
        setContentView(rootFrame);
        handleIntent(getIntent());
        rootFrame.setOnApplyWindowInsetsListener((v, in) -> { v.setPadding(0, in.getSystemWindowInsetTop(), 0, in.getSystemWindowInsetBottom()); return in; });
    }

    private void buildUi() {
        rootFrame.removeAllViews();
        home = buildHome();
        work = buildWork();
        work.setVisibility(View.GONE);
        rootFrame.addView(home);
        rootFrame.addView(work);
    }

    // Cambio de idioma o unidades: reconstruye las vistas conservando datos y regenera el plano.
    private void rebuild() {
        String a = title.getText().toString(), p = partNo.getText().toString(), m = material.getText().toString(), g = tol.getText().toString();
        String hd = headTitle.getText().toString();
        boolean inWork = work.getVisibility() == View.VISIBLE;
        buildUi();
        title.setText(a); partNo.setText(p); material.setText(m); tol.setText(g);
        headTitle.setText(hd);
        if (inWork) { home.setVisibility(View.GONE); work.setVisibility(View.VISIBLE); }
        if (step != null) { pdf = null; generate(); }
    }

    private void acercaDe() {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(26), dp(24), dp(26), dp(22));
        box.setBackground(Ui.rr(this, Ui.SURFACE, 28));
        box.addView(Ui.text(this, "Diedro", 22, Ui.TEXT, true));
        String txt = t("Diedro es software libre (GNU GPL v3 o posterior), sin garantía. Funciona totalmente sin conexión: no tiene permiso de Internet, no recopila ni envía ningún dato. Los archivos y ajustes se guardan solo en este dispositivo.")
            + "\n\nThis product includes Open CASCADE Technology (https://dev.opencascade.org), licensed under LGPL 2.1 with the Open CASCADE exception; linked statically."
            + "\n\nFont osifont: GNU LGPL v3 with GPL font exception (https://hikikomori82.github.io/osifont/). Documents that embed it are not covered by the GPL because of it."
            + "\n\nC++ runtime (LLVM libc++): Apache License 2.0 with LLVM exception."
            + "\n\nFlutter, Dart and Flutter packages: BSD-3-Clause and other licences (Copyright The Flutter and Dart authors)."
            + "\n\n" + t("Código fuente y texto completo de las licencias: archivos LICENSE y NOTICE del proyecto.");
        TextView tv = Ui.text(this, txt, 13, Ui.TEXT, false);
        tv.setPadding(0, dp(14), 0, 0);
        box.addView(tv);
        ScrollView sv = new ScrollView(this);
        sv.addView(box);
        d.setContentView(sv);
        android.view.Window w = d.getWindow();
        w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        w.setLayout(Math.min(dp(560), getResources().getDisplayMetrics().widthPixels - dp(24)), -2);
        w.setDimAmount(0.6f);
        d.show();
    }

    private void settings() {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(26), dp(24), dp(26), dp(22));
        box.setBackground(Ui.rr(this, Ui.SURFACE, 28));
        box.addView(Ui.text(this, t("Ajustes"), 22, Ui.TEXT, true));
        String[] lv = new String[I18n.CODES.length + 1], ln = new String[lv.length];
        lv[0] = "auto"; ln[0] = t("Automático");
        for (int i = 0; i < I18n.CODES.length; i++) { lv[i + 1] = I18n.CODES[i]; ln[i + 1] = I18n.NAMES[i]; }
        String[] uv = {"auto", "metric", "imperial"}, un = {t("Automático"), t("Métrico (mm)"), t("Imperial (in)")};
        String[] sv3 = {"auto", "A4", "A3", "A2", "A1", "A0"}, sn3 = {t("Automático"), "A4", "A3", "A2", "A1", "A0"};
        final String[] sel = {I18n.choice(), I18n.unitChoice(), I18n.sheetChoice(), I18n.explodeChoice(), I18n.inspectChoice(), I18n.projChoice(), I18n.dfmChoice()};
        String[] ev = {"0", "1"}, en = {t("Normal"), t("Explosionada")}, iv = {"0", "1"}, in = {t("Sin globos"), t("Globos y tabla")};
        String[] dv = {"0", "1"}, dn = {t("Desactivada"), t("Activada")};
        String[] pv = {"1", "3"}, pn = {t("Primer diedro (ISO)"), t("Tercer diedro (ASME)")};
        for (int sec = 0; sec < 7; sec++) {
            TextView h = Ui.text(this, t(sec == 0 ? "Idioma" : sec == 1 ? "Unidades" : sec == 2 ? "Formato de papel" : sec == 3 ? "Isométrica de conjuntos" : sec == 4 ? "Inspección con globos" : sec == 5 ? "Método de proyección" : "Revisión para fresado"), 12, Ui.TEAL, true);
            h.setPadding(dp(2), dp(18), 0, dp(8));
            box.addView(h);
            String[] vals = sec == 0 ? lv : sec == 1 ? uv : sec == 2 ? sv3 : sec == 3 ? ev : sec == 4 ? iv : sec == 5 ? pv : dv, names = sec == 0 ? ln : sec == 1 ? un : sec == 2 ? sn3 : sec == 3 ? en : sec == 4 ? in : sec == 5 ? pn : dn;
            WrapLayout w = new WrapLayout(this);
            for (int i = 0; i < vals.length; i++) {
                final int s2 = sec; final String v = vals[i];
                TextView c = Ui.text(this, names[i], 14, v.equals(sel[sec]) ? Ui.BG : Ui.TEXT, false);
                c.setBackground(v.equals(sel[sec]) ? Ui.rr(this, Ui.TEAL, 14) : Ui.rr(this, Ui.SURFACE2, 14));
                c.setPadding(dp(14), dp(8), dp(14), dp(8));
                Ui.press(c);
                c.setOnClickListener(x -> { I18n.set(s2 == 0 ? v : sel[0], s2 == 1 ? v : sel[1], s2 == 2 ? v : sel[2], s2 == 3 ? v : sel[3], s2 == 4 ? v : sel[4], s2 == 5 ? v : sel[5], s2 == 6 ? v : sel[6]); d.dismiss(); rebuild(); sendVisorConfig(); });
                w.addView(c);
            }
            box.addView(w);
            if (sec == 4) { TextView hn = Ui.text(this, t("Añade un globo numerado por cota y hojas con la tabla de inspección. Para clasificar una característica, añade !C (crítica), !M (mayor) o !K (clave) a su tolerancia."), 11, 0xFF5B6E7E, false); hn.setPadding(0, dp(8), 0, 0); box.addView(hn); }
            if (sec == 6) { TextView hn = Ui.text(this, t("Añade avisos si la pieza fuera difícil de fresar (esquinas vivas, radios pequeños, cajeras y taladros profundos, paredes finas). No cambia el plano."), 11, 0xFF5B6E7E, false); hn.setPadding(0, dp(8), 0, 0); box.addView(hn); }
            if (sec == 5) { TextView hn = Ui.text(this, t("Primer diedro: planta bajo el alzado. Tercer diedro: planta encima y vista izquierda a la izquierda."), 11, 0xFF5B6E7E, false); hn.setPadding(0, dp(8), 0, 0); box.addView(hn); }
            if (sec == 2) { TextView hn = Ui.text(this, t("Automático elige el formato más pequeño que da una escala legible; si eliges otro, el plano se adapta a él."), 11, 0xFF5B6E7E, false); hn.setPadding(0, dp(8), 0, 0); box.addView(hn); }
        }
        TextView note = Ui.text(this, t("El texto del PDF saldrá en inglés en este idioma."), 11, 0xFF5B6E7E, false);
        note.setPadding(0, dp(14), 0, 0);
        String pl = I18n.lang();
        if (java.util.Arrays.asList("ja", "ko", "zh", "tw", "th", "hi").contains(pl)) box.addView(note);
        TextView about = Ui.text(this, t("Licencias y privacidad"), 14, Ui.TEXT, false);
        about.setBackground(Ui.rr(this, Ui.SURFACE2, 14));
        about.setPadding(dp(14), dp(10), dp(14), dp(10));
        Ui.press(about);
        about.setOnClickListener(x -> acercaDe());
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(-2, -2); alp.topMargin = dp(22);
        box.addView(about, alp);
        ScrollView sv = new ScrollView(this);
        sv.addView(box);
        d.setContentView(sv);
        android.view.Window w = d.getWindow();
        w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        w.setLayout(Math.min(dp(560), getResources().getDisplayMetrics().widthPixels - dp(24)), -2);
        w.setDimAmount(0.6f);
        d.show();
    }

    private GradientDrawable bg() {
        GradientDrawable g = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[]{0xFF152532, 0xFF0B1319});
        return g;
    }

    private int dp(float v) { return Ui.dp(this, v); }
    private static String t(String es) { return I18n.tr(es); }

    // ---------------------------------------------------------------- portada
    private View homeLogo, homeGap; private TextView homeName;
    /** En horizontal (poca altura) la portada se compacta para que el botón Abrir siga visible. */
    private void fitHome() {
        if (homeLogo == null) return;
        boolean low = getResources().getConfiguration().screenHeightDp < 480;
        homeLogo.getLayoutParams().width = homeLogo.getLayoutParams().height = dp(low ? 80 : 170);
        homeGap.getLayoutParams().height = dp(low ? 4 : 36);
        homeName.setTextSize(low ? 26 : 40); homeName.setPadding(0, dp(low ? 4 : 18), 0, dp(6));
        homeLogo.requestLayout();
    }

    private View buildHome() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setGravity(Gravity.CENTER_HORIZONTAL);
        c.setPadding(dp(24), dp(24), dp(24), dp(24));
        View gear = iconBtn("⚙");
        Ui.press(gear);
        gear.setOnClickListener(v -> settings());
        c.addView(gear, new LinearLayout.LayoutParams(dp(44), dp(44)));
        ((LinearLayout.LayoutParams) gear.getLayoutParams()).gravity = Gravity.END;
        View sp1 = new View(this);
        c.addView(sp1, new LinearLayout.LayoutParams(1, 0, 1f));
        LogoView logo = new LogoView(this);
        logo.setOnClickListener(v -> { v.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK); logo.startAnim(); logo.postDelayed(logo::stopAnim, 2600); });   // toque: la cota «mide» la D
        c.addView(logo, new LinearLayout.LayoutParams(dp(170), dp(170)));
        homeLogo = logo;
        TextView name = Ui.text(this, "D i e d r o", 40, Ui.TEXT, false);
        name.setTypeface(Typeface.create("sans-serif-thin", Typeface.NORMAL));
        name.setGravity(Gravity.CENTER);
        name.setPadding(0, dp(18), 0, dp(6));
        c.addView(name);
        TextView tag = Ui.text(this, t("Planos de fabricación desde tu STEP"), 15, Ui.MUTED, false);
        tag.setGravity(Gravity.CENTER);
        c.addView(tag);
        View sp2 = new View(this);
        c.addView(sp2, new LinearLayout.LayoutParams(1, 0, 1f));
        TextView open = Ui.pill(this, t("Abrir archivo STEP"), Ui.TEAL, 0xFF06201C, true);
        open.setTextSize(18);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(Math.min(dp(420), getResources().getDisplayMetrics().widthPixels - dp(48)), dp(60));
        c.addView(open, lp);
        Ui.press(open);
        open.setOnClickListener(v -> pick());
        LogoView lg = (LogoView) c.getChildAt(2);
        lg.setScaleX(0.85f); lg.setScaleY(0.85f); lg.setAlpha(0f);
        lg.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(700).setInterpolator(new android.view.animation.DecelerateInterpolator(2f)).start();
        Ui.rise(name, 2, 14); Ui.rise(tag, 3, 14); Ui.rise(open, 4, 24);
        View gap = new View(this);
        c.addView(gap, new LinearLayout.LayoutParams(1, dp(36)));
        homeName = name; homeGap = gap; fitHome();
        return c;
    }

    // ---------------------------------------------------------------- trabajo
    private LinearLayout card() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setBackground(Ui.rr(this, Ui.SURFACE, 18));
        l.setPadding(dp(16), dp(14), dp(16), dp(16));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(12);
        l.setLayoutParams(lp);
        return l;
    }

    private EditText field(LinearLayout p, String label, String hint) {
        TextView t = Ui.text(this, label, 12, Ui.MUTED, false);
        t.setPadding(dp(4), dp(10), 0, dp(4));
        p.addView(t);
        EditText e = new EditText(this); e.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI | android.view.inputmethod.EditorInfo.IME_ACTION_DONE);   // horizontal: teclado sin pantalla completa
        e.setHint(hint);
        e.setSingleLine();
        e.setInputType(InputType.TYPE_CLASS_TEXT);
        e.setImeOptions(EditorInfo.IME_ACTION_DONE);
        e.setTextColor(Ui.TEXT);
        e.setHintTextColor(0xFF5B6E7E);
        e.setTextSize(15);
        e.setBackground(Ui.rr(this, Ui.SURFACE2, 12));
        e.setPadding(dp(14), dp(11), dp(14), dp(11));
        p.addView(e, new LinearLayout.LayoutParams(-1, -2));
        e.setOnEditorActionListener((v, a, ev) -> { generate(); return false; });
        return e;
    }

    private View iconBtn(String glyph) {
        TextView t = Ui.text(this, glyph, 22, Ui.TEXT, false);
        t.setGravity(Gravity.CENTER);
        t.setBackground(Ui.rr(this, Ui.SURFACE2, 22));
        t.setLayoutParams(new LinearLayout.LayoutParams(dp(44), dp(44)));
        t.setClickable(true);
        return t;
    }

    private View buildWork() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);

        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(14), dp(10), dp(14), dp(10));
        View back = iconBtn("‹");
        ((TextView) back).setTextSize(30);
        Ui.press(back);
        back.setOnClickListener(v -> Ui.swap(home, work, false));
        bar.addView(back);
        headTitle = Ui.text(this, "", 18, Ui.TEXT, true);
        headTitle.setSingleLine(); headTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
        headTitle.setPadding(dp(14), 0, dp(10), 0);
        bar.addView(headTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        if (getResources().getConfiguration().screenWidthDp < 480) {  // móvil vertical: cabecera compacta
            bar.setPadding(dp(8), dp(8), dp(8), dp(8));
            headTitle.setPadding(dp(8), 0, dp(6), 0);
            headTitle.setTextSize(16);
        }
        // Acciones: un solo botón de guardado (descarga) y un menú «⋯» con el resto.
        saveBtn = (TextView) iconBtn("⤓");
        saveBtn.setBackground(Ui.rr(this, Ui.TEAL, 22));
        saveBtn.setTextColor(0xFF06201C);
        Ui.press(saveBtn);
        saveBtn.setOnClickListener(v -> {
            LinearLayout m = new LinearLayout(this);
            m.setOrientation(LinearLayout.VERTICAL);
            m.setBackground(Ui.rr(this, Ui.SURFACE2, 18));
            m.setPadding(dp(6), dp(6), dp(6), dp(6));
            android.widget.PopupWindow pw = new android.widget.PopupWindow(m, -2, -2, true);
            pw.setElevation(dp(12));
            final boolean csv = new File(getCacheDir(), "plano.pdf.csv").exists();
            java.util.ArrayList<String> it = new java.util.ArrayList<>(java.util.Arrays.asList(t("Guardar PDF"), t("Guardar DXF"), t("Guardar SVG"), t("Guardar proyecto")));
            if (csv) it.add(t("Tabla de inspección (CSV)"));
            for (int k = 0; k < it.size(); k++) {
                final int kk = k;
                TextView r = Ui.text(this, it.get(k), 15, Ui.TEXT, true);
                r.setPadding(dp(18), dp(12), dp(26), dp(12));
                Ui.press(r);
                r.setOnClickListener(x -> { pw.dismiss(); saveChoice(kk); });
                m.addView(r);
            }
            pw.showAsDropDown(v, -dp(150), dp(6));
        });
        View gw = iconBtn("⚙");
        Ui.press(gw);
        gw.setOnClickListener(v -> settings());
        LinearLayout.LayoutParams gl = new LinearLayout.LayoutParams(dp(44), dp(44));
        gl.rightMargin = dp(8);
        bar.addView(gw, gl);
        bar.addView(saveBtn);
        col.addView(bar);
        LinearLayout modes = new LinearLayout(this);
        modes.setGravity(Gravity.CENTER_VERTICAL);
        modes.setPadding(dp(10), 0, dp(10), dp(6));
        LinearLayout segs = new LinearLayout(this);
        segs.setBackground(Ui.rr(this, Ui.SURFACE2, 24));
        segs.setPadding(dp(3), dp(3), dp(3), dp(3));
        String[] nm = {t("Plano"), t("Dividido"), "3D"};
        for (int i = 0; i < 3; i++) {
            final int k = i;
            modeBtn[i] = seg(nm[i]);
            modeBtn[i].setOnClickListener(v -> setMode(k));
            segs.addView(modeBtn[i]);
        }
        modes.addView(segs);
        modes.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1f));
        dataBtn = seg(t("Datos"));
        dataBtn.setOnClickListener(v -> setDrawer(!drawerOpen));
        LinearLayout dwrap = new LinearLayout(this);
        dwrap.setBackground(Ui.rr(this, Ui.SURFACE2, 24));
        dwrap.setPadding(dp(3), dp(3), dp(3), dp(3));
        dwrap.addView(dataBtn);
        dwrapV = dwrap;
        editBtn = seg(t("Editar"));
        editBtn.setOnClickListener(v -> toggleEdit());
        LinearLayout ewrap = new LinearLayout(this);
        ewrap.setBackground(Ui.rr(this, Ui.SURFACE2, 24));
        ewrap.setPadding(dp(3), dp(3), dp(3), dp(3));
        ewrap.addView(editBtn);
        ewrapV = ewrap;
        LinearLayout.LayoutParams ewl = new LinearLayout.LayoutParams(-2, -2);
        ewl.rightMargin = dp(8);
        modes.addView(ewrap, ewl);
        modes.addView(dwrap);
        col.addView(modes);

        body = new LinearLayout(this);
        FrameLayout stage = new FrameLayout(this);
        stage.addView(body, new FrameLayout.LayoutParams(-1, -1));
        LinearLayout outer = new LinearLayout(this);
        rail = new SheetRail(this);
        rail.setVisibility(View.GONE);
        rail.onPick(k -> ed.setPage(k));
        boolean narrow = getResources().getConfiguration().screenWidthDp < 480;
        LinearLayout.LayoutParams rl = new LinearLayout.LayoutParams(dp(narrow ? 84 : 112), -1);
        rl.leftMargin = dp(8);
        outer.addView(rail, rl);
        outer.addView(stage, new LinearLayout.LayoutParams(0, -1, 1f));
        col.addView(outer, new LinearLayout.LayoutParams(-1, 0, 1f));

        FrameLayout viewer = new FrameLayout(this);
        viewerBox = viewer;
        viewer.setBackground(Ui.rr(this, 0xFF0A1118, 22));
        zoom = new ZoomView(this);
        ed = new Editor(edHost);
        zoom.setEditor(ed);
        viewer.addView(zoom, new FrameLayout.LayoutParams(-1, -1));
        status = Ui.text(this, "", 14, Ui.MUTED, false);
        status.setGravity(Gravity.CENTER);
        viewer.addView(status, new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER));
        discardBox = new LinearLayout(this);
        discardBox.setOrientation(LinearLayout.VERTICAL);
        discardBox.setBackground(Ui.outline(this, Ui.SURFACE, 0x88E0A94A, 22));
        discardBox.setPadding(dp(26), dp(24), dp(26), dp(26));
        discardBox.setVisibility(View.GONE);
        FrameLayout.LayoutParams dbl = new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER);
        dbl.setMargins(dp(28), 0, dp(28), 0);
        viewer.addView(discardBox, dbl);
        TextView hint = Ui.text(this, t("Pellizca para ampliar · doble toque para ajustar"), 11, 0xFF5B6E7E, false);
        hint.setPadding(dp(14), 0, 0, dp(10));
        viewer.addView(hint, new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.START));
        FrameLayout.LayoutParams mb1 = new FrameLayout.LayoutParams(dp(40), dp(40), Gravity.TOP | Gravity.END);
        mb1.setMargins(0, dp(10), dp(10), 0);
        viewer.addView(maxBtn(0), mb1);
        editScroll = new HorizontalScrollView(this);
        editScroll.setHorizontalScrollBarEnabled(false);
        editScroll.setVisibility(View.GONE);
        editBar = new LinearLayout(this);
        editBar.setGravity(Gravity.CENTER_VERTICAL);
        editScroll.addView(editBar);
        FrameLayout.LayoutParams ebl = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP | Gravity.START);
        ebl.setMargins(dp(10), dp(12), dp(58), 0);
        viewer.addView(editScroll, ebl);
        body.addView(viewer);

        visorBox = new FrameLayout(this);
        visorBox.setBackground(Ui.rr(this, 0xFF0A1118, 22));
        visorBox.setVisibility(View.GONE);
        visorView = null;
        body.addView(visorBox);

        ScrollView sv = new ScrollView(this);
        sv.setVerticalScrollBarEnabled(false);
        sv.setBackground(Ui.outline(this, Ui.BG, 0x5536C2B4, 22));
        sv.setElevation(dp(12));
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(14), dp(10), dp(14), dp(14));
        sv.addView(panel);
        drawer = sv;
        FrameLayout.LayoutParams dlp = new FrameLayout.LayoutParams(dp(360), -1, Gravity.END);
        dlp.setMargins(0, 0, dp(8), dp(10));
        stage.addView(sv, dlp);

        LinearLayout data = card();
        data.addView(Ui.text(this, t("Datos del plano"), 16, Ui.TEXT, true));
        title = field(data, t("Pieza"), t("Nombre"));
        partNo = field(data, t("N.° de plano"), t("Opcional"));
        material = field(data, t("Material"), t("Opcional"));
        tol = field(data, t("Tolerancia general"), t("p. ej. ISO 2768-m"));
        update = Ui.pill(this, t("Actualizar plano"), Ui.TEAL, Ui.TEAL, false);
        update.setTextSize(14);
        Ui.press(update);
        update.setOnClickListener(v -> generate());
        LinearLayout.LayoutParams ul = new LinearLayout.LayoutParams(-1, -2);
        ul.topMargin = dp(16);
        data.addView(update, ul);
        panel.addView(data);

        results = new LinearLayout(this);
        results.setOrientation(LinearLayout.VERTICAL);
        panel.addView(results);
        col.post(() -> { setDrawer(drawerOpen); setMode(mode); });
        return col;
    }

    // ---------------------------------------------------------------- hojas y exportación
    private SheetRail rail;
    private String[] pendingExport;

    private void showRail(String r0, File out) {
        rail.setItems(r0);
        boolean multi = rail.count() > 1;
        rail.setVisibility(multi ? View.VISIBLE : View.GONE);
        if (!multi) return;
        rail.select(ed.page);
        rail.loadThumbs(out);
    }

    /** Menú ⤓: 0 PDF, 1 DXF, 2 SVG, 3 proyecto, 4 CSV. Con varias hojas pregunta cuáles. */
    private void saveChoice(int k) {
        if (k == 3) { saveProject(); return; }
        if (k == 4) {
            startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/csv")
                    .putExtra(Intent.EXTRA_TITLE, title.getText().toString().replaceAll("[^A-Za-z0-9_-]", "_") + "_inspeccion.csv"), SAVECSV);
            return;
        }
        if (pdf == null) return;
        final String ext = k == 0 ? "pdf" : k == 1 ? "dxf" : "svg";
        final int n = rail.count();
        if (n < 2) { if (k == 0) save(); else exportSel(ext, String.valueOf(Math.max(0, ed.page)), false); return; }
        StringBuilder all = new StringBuilder();
        for (int i = 0; i < n; i++) all.append(i > 0 ? "," : "").append(i);
        final String cur = String.valueOf(Math.max(0, ed.page));
        java.util.ArrayList<String> o = new java.util.ArrayList<>(java.util.Arrays.asList(t("Esta hoja"), t("Todas las hojas"), t("Elegir hojas…")));
        if (k == 0) o.add(t("Un PDF por pieza"));
        choiceDialog(t(k == 0 ? "Guardar PDF" : k == 1 ? "Guardar DXF" : "Guardar SVG"), o, c -> {
            if (c == 0) exportSel(ext, cur, false);
            else if (c == 1) { if (k == 0) save(); else exportSel(ext, all.toString(), k == 1); }
            else if (c == 3) exportSel(ext, all.toString(), true);
            else pickSheets(sel -> exportSel(ext, sel, k == 1 && sel.contains(",")));
        });
    }

    private void choiceDialog(String title0, java.util.List<String> opts, java.util.function.IntConsumer ok) {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(22), dp(24), dp(22), dp(18));
        box.setBackground(Ui.rr(this, Ui.SURFACE, 28));
        TextView cap = Ui.text(this, title0.toUpperCase(), 11, Ui.TEAL, true);
        cap.setLetterSpacing(0.12f);
        cap.setPadding(dp(6), 0, 0, dp(10));
        box.addView(cap);
        for (int i = 0; i < opts.size(); i++) {
            final int k = i;
            TextView r = Ui.text(this, opts.get(i), 16, Ui.TEXT, true);
            r.setBackground(Ui.rr(this, Ui.SURFACE2, 16));
            r.setPadding(dp(18), dp(14), dp(18), dp(14));
            Ui.press(r);
            r.setOnClickListener(v -> { d.dismiss(); ok.accept(k); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.topMargin = dp(8);
            box.addView(r, lp);
        }
        d.setContentView(box);
        d.getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        d.getWindow().setLayout(Math.min(dp(380), getResources().getDisplayMetrics().widthPixels - dp(32)), -2);
        d.show();
    }

    private void pickSheets(java.util.function.Consumer<String> ok) {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(22), dp(24), dp(22), dp(18));
        box.setBackground(Ui.rr(this, Ui.SURFACE, 28));
        TextView cap = Ui.text(this, t("Elegir hojas").toUpperCase(), 11, Ui.TEAL, true);
        cap.setLetterSpacing(0.12f);
        cap.setPadding(dp(6), 0, 0, dp(6));
        box.addView(cap);
        final int n = rail.count();
        final boolean[] on = new boolean[n];
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        final TextView go = Ui.pill(this, t("Listo"), Ui.TEAL, 0xFF06201C, true);
        for (int i = 0; i < n; i++) {
            final int k = i;
            final TextView r = Ui.text(this, "☐  " + rail.label(i), 15, Ui.TEXT, false);
            r.setPadding(dp(16), dp(12), dp(16), dp(12));
            r.setBackground(Ui.rr(this, Ui.SURFACE2, 14));
            Ui.press(r);
            r.setOnClickListener(v -> {
                on[k] = !on[k];
                r.setText((on[k] ? "☑  " : "☐  ") + rail.label(k));
                r.setTextColor(on[k] ? Ui.TEAL : Ui.TEXT);
                boolean any = false; for (boolean b : on) any |= b;
                go.setAlpha(any ? 1f : 0.4f);
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.topMargin = dp(6);
            list.addView(r, lp);
        }
        ScrollView sv = new ScrollView(this);
        sv.addView(list);
        box.addView(sv, new LinearLayout.LayoutParams(-1, -2));
        go.setTextSize(15);
        go.setAlpha(0.4f);
        Ui.press(go);
        LinearLayout.LayoutParams gl = new LinearLayout.LayoutParams(-1, -2);
        gl.topMargin = dp(14);
        box.addView(go, gl);
        go.setOnClickListener(v -> {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < n; i++) if (on[i]) sb.append(sb.length() > 0 ? "," : "").append(i);
            if (sb.length() == 0) return;
            d.dismiss();
            ok.accept(sb.toString());
        });
        d.setContentView(box);
        d.getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        d.getWindow().setLayout(Math.min(dp(400), getResources().getDisplayMetrics().widthPixels - dp(32)), -2);
        d.show();
    }

    /** Exporta las hojas «sel» (PDF/DXF/SVG); un solo fichero → crear documento, varios → carpeta. */
    private void exportSel(String ext, String sel, boolean split) {
        if (pdf == null) return;
        final String ops = String.join("\n", ed.ops);
        String n0 = title.getText().toString().replaceAll("[^A-Za-z0-9_-]", "_");
        final String name = (n0.isEmpty() ? "plano" : n0) + "." + ext;
        final File dir = new File(getCacheDir(), "exp");
        new Thread(() -> {
            File[] old = dir.listFiles();
            if (old != null) for (File f : old) f.delete();
            dir.mkdirs();
            String r = Native.exportPages(dir.getPath(), name, ops, sel, split);
            runOnUiThread(() -> {
                if (r.startsWith("ERROR")) { Ui.snack(rootFrame, r, true); return; }
                pendingExport = r.trim().split("\n");
                pendingExt = ext;
                if (pendingExport.length > 1) startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), EXPORTDIR);
                else startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(ext.equals("svg") ? "image/svg+xml" : ext.equals("pdf") ? "application/pdf" : "application/dxf").putExtra(Intent.EXTRA_TITLE, name), EXPORT);
            });
        }).start();
    }
    private String pendingExt = "pdf";

    private void writeExport(Uri u, boolean tree) {
        try {
            if (!tree) {
                try (InputStream in = new FileInputStream(pendingExport[0]); OutputStream out = getContentResolver().openOutputStream(u)) { copy(in, out); }
            } else {
                Uri doc = android.provider.DocumentsContract.buildDocumentUriUsingTree(u, android.provider.DocumentsContract.getTreeDocumentId(u));
                for (String f : pendingExport) {
                    String nm = new File(f).getName().replaceAll("(?i)\\." + pendingExt + "$", "");
                    Uri o = android.provider.DocumentsContract.createDocument(getContentResolver(), doc, pendingExt.equals("pdf") ? "application/pdf" : pendingExt.equals("svg") ? "image/svg+xml" : "application/dxf", nm);
                    try (InputStream in = new FileInputStream(f); OutputStream out = getContentResolver().openOutputStream(o)) { copy(in, out); }
                }
            }
            Ui.snack(rootFrame, t("Exportado"), false);
        } catch (Exception e) { Ui.snack(rootFrame, t("No se pudo guardar:") + " " + e.getMessage(), true); }
    }

    // ---------------------------------------------------------------- edición del plano
    private Editor ed;
    private HorizontalScrollView editScroll;
    private LinearLayout editBar;
    private TextView editBtn;
    private View dwrapV, ewrapV;
    private int renderSeq;
    private final java.util.concurrent.ExecutorService renderQ = java.util.concurrent.Executors.newSingleThreadExecutor();
    private final Editor.Host edHost = new Editor.Host() {
        @Override public void changed() { rerender(); buildEditBar(); if (rail != null && rail.count() > 1) rail.select(ed.page); }
        @Override public void toolbar() { buildEditBar(); }
        @Override public void ask(String title, String init, java.util.function.Consumer<String> ok) { askText(t(title), init, ok); }
    };

    private boolean refLine(String l, java.util.ArrayList<float[]> hr, java.util.ArrayList<float[]> vr) {
        boolean h = l.startsWith("AGUJERO\t");
        if (!h && !l.startsWith("VISTA\t")) return false;
        try {
            String[] q = l.split("\t", -1);
            float sw = Float.parseFloat(q[q.length - 2]), sh = Float.parseFloat(q[q.length - 1]);
            if (h) {  // AGUJERO x y px py pz ax ay az diam hojaW hojaH
                hr.add(new float[]{Float.parseFloat(q[1]) / sw, 1 - Float.parseFloat(q[2]) / sh, Float.parseFloat(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7]), Float.parseFloat(q[8])});
            } else {  // VISTA v ox oy exx exy eyx eyy ezx ezy x0 y0 x1 y1 hojaW hojaH
                float[] f = new float[12];
                for (int k = 0; k < 12; k++) f[k] = Float.parseFloat(q[2 + k]) * (k % 2 == 0 ? 1 / sw : -1 / sh);
                f[1] += 1; f[9] += 1; f[11] += 1;  // y: abajo→arriba; los vectores solo cambian de signo
                vr.add(f);
            }
        } catch (Exception ignored) {}
        return true;
    }

    /** Repinta el plano con las ediciones actuales (sin regenerar), conservando el zoom. */
    private void rerender() {
        if (pdf == null) return;
        final String ops = String.join("\n", ed.ops);
        final File f = pdf;
        final int seq = ++renderSeq;
        renderQ.execute(() -> {
            String info0 = Native.render(f.getPath(), ops);
            final boolean ok = !info0.startsWith("ERROR");
            final String info = ok ? info0 : "";   // si falla la edición, el PDF anterior sigue válido: al menos se cambia de hoja
            Bitmap b = render(f);
            runOnUiThread(() -> {
                if (b == null || seq != renderSeq) return;
                java.util.ArrayList<float[]> hr = new java.util.ArrayList<>(), vr = new java.util.ArrayList<>();
                for (String l : info.split("\n")) refLine(l, hr, vr);
                if (ok) ed.info(info);
                holeRefs = ed.page == 0 ? hr : new java.util.ArrayList<>(); viewRefs = ed.page == 0 ? vr : new java.util.ArrayList<>();
                java.util.ArrayList<float[]> mk = new java.util.ArrayList<>();
                java.util.ArrayList<int[]> mi = new java.util.ArrayList<>();
                if (ed.page == 0) for (String l : info.split("\n")) if (l.startsWith("PIEZA\t")) {
                    try {
                        String[] q = l.split("\t", -1);
                        float sw = Float.parseFloat(q[q.length - 2]), sh = Float.parseFloat(q[q.length - 1]);
                        mk.add(new float[]{Float.parseFloat(q[2]) / sw, 1 - Float.parseFloat(q[3]) / sh});
                        mi.add(new int[]{Integer.parseInt(q[1]), Integer.parseInt(q[4])});
                    } catch (Exception ignored) {}
                }
                markFrac = mk; markPos = mi;
                zoom.swapBitmap(b);
                applyMarks(b);
                applyHoles(b);
                buildEditBar();
            });
        });
    }

    private TextView chip(String s, boolean on, View.OnClickListener l) {
        TextView c = Ui.text(this, s, 13, on ? 0xFF06201C : Ui.TEXT, true);
        c.setGravity(Gravity.CENTER);
        c.setBackground(Ui.rr(this, on ? Ui.TEAL : 0xEE1F2E3C, 18));
        c.setPadding(dp(13), dp(8), dp(13), dp(8));
        Ui.press(c);
        c.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.rightMargin = dp(6);
        c.setLayoutParams(lp);
        return c;
    }

    private void buildEditBar() {
        if (editBar == null) return;
        editBar.removeAllViews();
        editScroll.setVisibility(ed.on ? View.VISIBLE : View.GONE);
        zoom.setTopInset(ed.on ? dp(44) : 0);
        if (!ed.on) return;
        for (int i = 0; i < ed.pages && ed.pages > 1 && (rail == null || rail.count() < 2); i++) { final int k = i; editBar.addView(chip(t("Hoja") + " " + (i + 1), ed.page == i, v -> ed.setPage(k))); }
        String[] tn = {"Mover", "Texto", "Línea", "Flecha", "Cota"};
        for (int i = 0; i < tn.length; i++) { final int k = i; editBar.addView(chip(t(tn[i]), ed.tool == i, v -> ed.setTool(k))); }
        TextView u = chip("↶", false, v -> ed.undo()), r = chip("↷", false, v -> ed.redo());
        u.setAlpha(ed.ops.isEmpty() ? 0.4f : 1f);
        r.setAlpha(ed.redo.isEmpty() ? 0.4f : 1f);
        editBar.addView(u); editBar.addView(r);
        if (ed.selG >= 0) {
            TextView n = Ui.text(this, t(ed.selName()), 13, Ui.AMBER, true);
            n.setPadding(dp(6), 0, dp(10), 0);
            editBar.addView(n);
            editBar.addView(chip(t("Escala") + " −", false, v -> ed.scaleSel(0.8f)));
            editBar.addView(chip(t("Escala") + " +", false, v -> ed.scaleSel(1.25f)));
            editBar.addView(chip(t("Ocultar"), false, v -> ed.deleteSel()));
        } else if (ed.selT < 0) {
            TextView n = Ui.text(this, t("Escala de la hoja"), 13, Ui.MUTED, false);
            n.setPadding(dp(6), 0, dp(6), 0);
            editBar.addView(n);
            editBar.addView(chip("−", false, v -> ed.scaleAll(0.8f)));
            editBar.addView(chip("+", false, v -> ed.scaleAll(1.25f)));
        } else {
            editBar.addView(chip(t("Editar texto"), false, v -> ed.editSelText()));
            editBar.addView(chip(t("Borrar"), false, v -> ed.deleteSel()));
        }
    }

    private void toggleEdit() {
        if (pdf == null) return;
        ed.on = !ed.on;
        editBtn.setBackground(ed.on ? Ui.rr(this, Ui.TEAL, 20) : null);
        editBtn.setTextColor(ed.on ? 0xFF06201C : Ui.TEXT);
        ed.setTool(Editor.SEL);
        zoom.invalidate();
    }

    private void askText(String title, String init, java.util.function.Consumer<String> ok) {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(28), dp(26), dp(28), dp(24));
        box.setBackground(Ui.rr(this, Ui.SURFACE, 28));
        TextView cap = Ui.text(this, title.toUpperCase(), 11, Ui.TEAL, true);
        cap.setLetterSpacing(0.12f);
        cap.setPadding(0, 0, 0, dp(12));
        box.addView(cap);
        EditText e = new EditText(this); e.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI | android.view.inputmethod.EditorInfo.IME_ACTION_DONE);   // horizontal: teclado sin pantalla completa
        e.setSingleLine();
        e.setText(init);
        e.setSelection(init.length());
        e.setTextSize(18);
        e.setTextColor(Ui.TEXT);
        e.setBackground(Ui.outline(this, Ui.BG, 0x6636C2B4, 16));
        e.setPadding(dp(18), dp(14), dp(18), dp(14));
        box.addView(e);
        TextView go = Ui.pill(this, t("Listo"), Ui.TEAL, 0xFF06201C, true);
        go.setTextSize(15);
        Ui.press(go);
        LinearLayout.LayoutParams gl = new LinearLayout.LayoutParams(-1, -2);
        gl.topMargin = dp(16);
        box.addView(go, gl);
        go.setOnClickListener(v -> { d.dismiss(); ok.accept(e.getText().toString()); });
        d.setContentView(box);
        d.getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        d.getWindow().setLayout(Math.min(dp(420), getResources().getDisplayMetrics().widthPixels - dp(32)), -2);
        d.getWindow().setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
        d.show();
    }

    private LinearLayout discardBox;

    private void showResult(String r) {
        discardBox.setVisibility(View.GONE);
        results.removeAllViews();
        try { results.post(() -> { for (int i = 0; i < results.getChildCount(); i++) Ui.rise(results.getChildAt(i), i + 1, 22); }); } catch (Exception ignored) {}
        if (r.startsWith("ERROR")) {
            LinearLayout e = card();
            e.setBackground(Ui.outline(this, Ui.SURFACE, Ui.RED, 18));
            e.addView(Ui.text(this, t("No se pudo generar el plano"), 15, Ui.RED, true));
            TextView m = Ui.text(this, r.substring(5).trim(), 13, Ui.TEXT, false);
            m.setPadding(0, dp(6), 0, 0);
            e.addView(m);
            results.addView(e);
            return;
        }
        if (r.startsWith("DESCARTE")) {   // pieza fuera de alcance: aviso de la app, sin plano
            String[] ln = r.trim().split("\n");
            LinearLayout e = discardBox;
            e.removeAllViews();
            TextView h = Ui.text(this, "⚠", 30, 0xFFE0A94A, false);
            e.addView(h);
            TextView tt = Ui.text(this, ln.length > 1 ? ln[1].substring(6) : t("Pieza fuera de alcance"), 18, 0xFFE0A94A, true);
            tt.setPadding(0, dp(8), 0, 0);
            e.addView(tt);
            for (int i = 2; i < ln.length; i++) {
                TextView m = Ui.text(this, ln[i].substring(6), i == ln.length - 1 && ln.length > 4 ? 12 : 15, i == 2 ? Ui.TEXT : Ui.MUTED, false);
                m.setPadding(0, dp(10), 0, 0);
                e.addView(m);
            }
            e.setVisibility(View.VISIBLE);
            Ui.rise(e, 1, 22);
            return;
        }
        WrapLayout chips = new WrapLayout(this);
        java.util.ArrayList<String> warns = new java.util.ArrayList<>();
        String head = "";
        java.util.ArrayList<float[]> mk = new java.util.ArrayList<>();
        java.util.ArrayList<int[]> mi = new java.util.ArrayList<>();
        java.util.ArrayList<float[]> hr = new java.util.ArrayList<>(), vr = new java.util.ArrayList<>();
        for (String l : r.split("\n")) {
            if (l.startsWith("PIEZA\t")) {  // PIEZA pos bx by parte nombre hojaW hojaH
                try {
                    String[] q = l.split("\t", -1);
                    float sw = Float.parseFloat(q[q.length - 2]), sh = Float.parseFloat(q[q.length - 1]);
                    mk.add(new float[]{Float.parseFloat(q[2]) / sw, 1 - Float.parseFloat(q[3]) / sh});
                    mi.add(new int[]{Integer.parseInt(q[1]), Integer.parseInt(q[4])});
                } catch (Exception ignored) {}
            } else if (refLine(l, hr, vr)) {
            } else if (l.startsWith("OK")) head = l;
            else if (l.startsWith("COTA ")) {
                String[] kt = l.substring(5).split("\t", 2);
                final String key = kt[0], shown = kt.length > 1 ? kt[1] : kt[0];
                String tv = tols.get(key);
                boolean tolerable = key.matches("Ø?[0-9.]+");
                TextView c = Ui.text(this, tv == null || tv.isEmpty() ? shown : shown + " " + tv, 14, tv == null || tv.isEmpty() ? Ui.TEXT : Ui.TEAL, false);
                c.setBackground(tolerable ? Ui.outline(this, Ui.SURFACE2, 0x5536C2B4, 14) : Ui.rr(this, Ui.SURFACE2, 14));
                if (tolerable) { Ui.press(c); c.setOnClickListener(v -> askTol(key, shown)); }
                c.setPadding(dp(12), dp(6), dp(12), dp(6));
                chips.addView(c);
            } else if (l.startsWith("AVISO ")) warns.add(l.substring(6));
        }
        markFrac = mk; markPos = mi; holeRefs = hr; viewRefs = vr;
        LinearLayout sum = card();
        String[] h = head.split(" ");
        String fmt = h.length > 1 ? h[1] : "";
        String esc = "";
        try { double s = Double.parseDouble(h[3]); esc = s >= 1 ? trim(s) + ":1" : "1:" + trim(1 / s); } catch (Exception ignored) {}
        sum.addView(Ui.text(this, t("Formato") + " " + fmt + "  ·  " + t("Escala") + " " + esc, 13, Ui.MUTED, false));
        TextView t = Ui.text(this, t("Cotas generadas"), 16, Ui.TEXT, true);
        t.setPadding(0, dp(8), 0, dp(10));
        sum.addView(t);
        sum.addView(chips);
        TextView tip = Ui.text(this, t("Toca una cota para añadir su tolerancia o ajuste. Solo se imprime lo que tú introduces."), 11, 0xFF5B6E7E, false);
        tip.setPadding(0, dp(10), 0, 0);
        sum.addView(tip);
        results.addView(sum);
        if (!warns.isEmpty()) {
            LinearLayout w = card();
            w.setBackground(Ui.outline(this, Ui.SURFACE, 0x88F2B84B, 18));
            w.addView(Ui.text(this, t("Sin acotar"), 16, Ui.AMBER, true));
            for (String s : warns) {
                TextView x = Ui.text(this, "• " + stripWarn(s), 13, Ui.TEXT, false);
                x.setPadding(0, dp(8), 0, 0);
                w.addView(x);
            }
            TextView n = Ui.text(this, t("Estos rasgos aún no se dibujan. Revisa la pieza antes de fabricar."), 12, Ui.MUTED, false);
            n.setPadding(0, dp(10), 0, 0);
            w.addView(n);
            results.addView(w);
        }
    }

    private static String stripWarn(String s) {
        String pre = I18n.tr("NO ACOTADO (rasgo no de revolución):", I18n.pdfLang());
        return s.startsWith(pre) ? s.substring(pre.length()).trim() : s;
    }

    private static String trim(double v) { return I18n.num(v); }

    private void askTol(String key, String shown) {
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(28), dp(26), dp(28), dp(24));
        GradientDrawable bg = Ui.rr(this, Ui.SURFACE, 28);
        box.setBackground(bg);
        TextView cap = Ui.text(this, key.startsWith("Ø") ? t("TOLERANCIA O ROSCA") : t("TOLERANCIA"), 11, Ui.TEAL, true);
        cap.setLetterSpacing(0.12f);
        box.addView(cap);
        TextView ti = Ui.text(this, shown, 30, Ui.TEXT, true);
        ti.setPadding(0, dp(4), 0, dp(16));
        box.addView(ti);
        EditText e = new EditText(this); e.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI | android.view.inputmethod.EditorInfo.IME_ACTION_DONE);   // horizontal: teclado sin pantalla completa
        e.setSingleLine();
        e.setHint(key.startsWith("Ø") ? t("Ajuste, desviación o rosca") : t("Desviación"));
        e.setText(tols.get(key) == null ? "" : tols.get(key));
        e.setTextSize(18);
        e.setTextColor(Ui.TEXT);
        e.setHintTextColor(0xFF5B6E7E);
        e.setBackground(Ui.outline(this, Ui.BG, 0x6636C2B4, 16));
        e.setPadding(dp(18), dp(14), dp(18), dp(14));
        e.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_DONE);
        box.addView(e);
        android.widget.HorizontalScrollView hs = new android.widget.HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        LinearLayout row = new LinearLayout(this);
        java.util.ArrayList<String> pre = new java.util.ArrayList<>(java.util.Arrays.asList("h6", "h7", "g6", "f7", "H7", "H8", "k6", "m6", "p6", "js6", "±0.1", "±0.05", "+0.1/0"));
        if (key.startsWith("Ø")) {  // pasos normales ISO 261: solo se ofrecen como atajo, el usuario decide
            String[][] metric = {{"3", "0.5"}, {"4", "0.7"}, {"5", "0.8"}, {"6", "1"}, {"8", "1.25"}, {"10", "1.5"}, {"12", "1.75"}, {"14", "2"}, {"16", "2"}, {"18", "2.5"}, {"20", "2.5"}, {"22", "2.5"}, {"24", "3"}, {"27", "3"}, {"30", "3.5"}, {"36", "4"}, {"42", "4.5"}, {"48", "5"}};
            for (String[] mm : metric) if (mm[0].equals(key.substring(1))) { pre.add(0, "M" + mm[0] + "x" + mm[1]); break; }
        }
        for (String p : pre) {
            TextView c = Ui.text(this, p, 14, Ui.TEXT, false);
            c.setBackground(Ui.rr(this, Ui.SURFACE2, 14));
            c.setPadding(dp(14), dp(8), dp(14), dp(8));
            Ui.press(c);
            c.setOnClickListener(v -> { e.setText(p); e.setSelection(p.length()); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            lp.rightMargin = dp(8);
            row.addView(c, lp);
        }
        hs.addView(row);
        LinearLayout.LayoutParams hp = new LinearLayout.LayoutParams(-1, -2);
        hp.topMargin = dp(14);
        box.addView(hs, hp);
        LinearLayout acts = new LinearLayout(this);
        acts.setGravity(Gravity.END);
        TextView no = Ui.pill(this, t("Quitar"), Ui.MUTED, Ui.MUTED, false);
        TextView ok = Ui.pill(this, t("Aplicar"), Ui.TEAL, Ui.BG, true);
        Ui.press(no); Ui.press(ok);
        no.setOnClickListener(v -> { tols.remove(key); d.dismiss(); generate(); });
        Runnable apply = () -> { String v = e.getText().toString().trim(); if (v.isEmpty()) tols.remove(key); else tols.put(key, v); d.dismiss(); generate(); };
        ok.setOnClickListener(v -> apply.run());
        e.setOnEditorActionListener((v, id, ev) -> { apply.run(); return true; });
        LinearLayout.LayoutParams ap = new LinearLayout.LayoutParams(-2, -2);
        ap.leftMargin = dp(10);
        acts.addView(no);
        acts.addView(ok, ap);
        LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(-1, -2);
        cp.topMargin = dp(22);
        box.addView(acts, cp);
        d.setContentView(box);
        android.view.Window w = d.getWindow();
        w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        w.setLayout(Math.min(dp(520), getResources().getDisplayMetrics().widthPixels - dp(24)), -2);
        w.setGravity(Gravity.BOTTOM);
        w.getAttributes().y = dp(16);
        w.setDimAmount(0.6f);
        w.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE | android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
        d.show();
        box.setTranslationY(dp(60)); box.setAlpha(0f);
        box.animate().translationY(0).alpha(1f).setDuration(320).setInterpolator(new android.view.animation.DecelerateInterpolator(2f)).start();
    }

    private String tolsText() {
        StringBuilder b = new StringBuilder();
        for (java.util.Map.Entry<String, String> en : tols.entrySet()) b.append(en.getKey()).append('\t').append(en.getValue()).append('\n');
        return b.toString();
    }

    private void handleIntent(Intent in) {
        if (in == null) return;
        Uri u = null;
        if (Intent.ACTION_VIEW.equals(in.getAction())) u = in.getData();
        else if (Intent.ACTION_SEND.equals(in.getAction())) u = in.getParcelableExtra(Intent.EXTRA_STREAM);
        if (u != null) load(u);
    }

    @Override protected void onNewIntent(Intent in) { super.onNewIntent(in); handleIntent(in); }

    private static String sha256(File f) throws Exception {
        java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(f)) { byte[] b = new byte[65536]; int n; while ((n = in.read(b)) > 0) md.update(b, 0, n); }
        StringBuilder sb = new StringBuilder();
        for (byte x : md.digest()) sb.append(String.format("%02x", x));
        return sb.toString();
    }

    private void writeProject(OutputStream os) throws Exception {
        org.json.JSONObject j = new org.json.JSONObject();
        j.put("formato", 1).put("app", "Diedro").put("pieza", title.getText().toString()).put("plano", partNo.getText().toString())
                .put("material", material.getText().toString()).put("toleranciaGeneral", tol.getText().toString()).put("modelo", stepName)
                .put("sha256", sha256(step));
        org.json.JSONObject t = new org.json.JSONObject();
        for (java.util.Map.Entry<String, String> en : tols.entrySet()) t.put(en.getKey(), en.getValue());
        j.put("tolerancias", t);
        j.put("ediciones", new org.json.JSONArray(ed.ops));
        try (java.util.zip.ZipOutputStream z = new java.util.zip.ZipOutputStream(os)) {
            z.putNextEntry(new java.util.zip.ZipEntry("project.json"));
            z.write(j.toString(2).getBytes("UTF-8"));
            z.closeEntry();
            z.putNextEntry(new java.util.zip.ZipEntry("model.step"));
            try (InputStream in = new FileInputStream(step)) { copy(in, z); }
            z.closeEntry();
        }
    }

    private boolean readProject(Uri u) {
        try (java.util.zip.ZipInputStream z = new java.util.zip.ZipInputStream(getContentResolver().openInputStream(u))) {
            java.util.zip.ZipEntry e;
            org.json.JSONObject j = null;
            File st = new File(getCacheDir(), "in.proj");
            boolean gotStep = false;
            while ((e = z.getNextEntry()) != null) {
                if (e.getName().equals("project.json")) { ByteArrayOutputStream b = new ByteArrayOutputStream(); copy(z, b); j = new org.json.JSONObject(b.toString("UTF-8")); }
                else if (e.getName().equals("model.step")) { try (OutputStream o = new FileOutputStream(st)) { copy(z, o); } gotStep = true; }
            }
            if (j == null || !gotStep) return false;
            if (!j.optString("sha256").equals(sha256(st))) { Ui.snack(rootFrame, t("El proyecto está dañado (huella SHA-256 distinta)"), true); return false; }
            File ok = new File(getCacheDir(), "in.step"); ok.delete(); if (!st.renameTo(ok)) return false;
            step = ok;
            stepName = j.optString("modelo", "pieza.step");
            title.setText(j.optString("pieza")); partNo.setText(j.optString("plano")); material.setText(j.optString("material")); tol.setText(j.optString("toleranciaGeneral"));
            tols.clear();
            org.json.JSONObject t = j.optJSONObject("tolerancias");
            if (t != null) for (java.util.Iterator<String> it = t.keys(); it.hasNext(); ) { String k = it.next(); tols.put(k, t.getString(k)); }
            ed.reset();
            org.json.JSONArray ea = j.optJSONArray("ediciones");
            if (ea != null) for (int i = 0; i < ea.length(); i++) ed.ops.add(ea.getString(i));
            return true;
        } catch (Exception ex) { return false; }
    }

    private void saveProject() {
        if (step == null) return;
        String n = title.getText().toString().replaceAll("[^A-Za-z0-9_-]", "_");
        startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream")
                .putExtra(Intent.EXTRA_TITLE, (n.isEmpty() ? "proyecto" : n) + ".diedro"), SAVEPROJ);
    }

    // ---------------------------------------------------------------- acciones
    private void pick() {
        startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), PICK);
    }

    private void save() {
        if (pdf == null) return;
        String n = title.getText().toString().replaceAll("[^A-Za-z0-9_-]", "_");
        startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/pdf")
                .putExtra(Intent.EXTRA_TITLE, (n.isEmpty() ? "plano" : n) + ".pdf"), SAVE);
    }

    @Override protected void onActivityResult(int rq, int rc, Intent d) {
        if (rc != RESULT_OK || d == null || d.getData() == null) return;
        Uri u = d.getData();
        if (rq == SAVE) {
            try (InputStream in = new FileInputStream(pdf); OutputStream out = getContentResolver().openOutputStream(u)) {
                copy(in, out);
                Ui.snack(rootFrame, t("PDF guardado"), false);
            } catch (Exception e) { Ui.snack(rootFrame, t("No se pudo guardar:") + " " + e.getMessage(), true); }
            return;
        }
        if ((rq == EXPORT || rq == EXPORTDIR) && pendingExport != null) { writeExport(u, rq == EXPORTDIR); return; }
        if (rq == SAVECSV) {
            try (InputStream in = new FileInputStream(new File(getCacheDir(), "plano.pdf.csv")); OutputStream out = getContentResolver().openOutputStream(u)) { copy(in, out); Ui.snack(rootFrame, t("Exportado"), false); }
            catch (Exception e) { Ui.snack(rootFrame, t("No se pudo guardar:") + " " + e.getMessage(), true); }
            return;
        }
        if (rq == SAVEPROJ) {
            try (OutputStream out = getContentResolver().openOutputStream(u)) { writeProject(out); Ui.snack(rootFrame, t("Proyecto guardado"), false); }
            catch (Exception e) { Ui.snack(rootFrame, t("No se pudo guardar:") + " " + e.getMessage(), true); }
            return;
        }
        if (rq != PICK) return;
        load(u);
    }

    private void load(Uri u) {
        String name = "pieza.step";
        try (android.database.Cursor c = getContentResolver().query(u, null, null, null, null)) {
            if (c != null && c.moveToFirst()) { String n = c.getString(c.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)); if (n != null && !n.isEmpty()) name = n; }
        } catch (Exception ignored) {}
        if (name.toLowerCase().endsWith(".diedro")) {   // un proyecto se valida antes de tocar el modelo actual
            if (!readProject(u)) { Ui.snack(rootFrame, t("Proyecto Diedro no válido"), true); return; }
            headTitle.setText(stepName);
            pdf = null; zoom.setBitmap(null);
            Ui.swap(work, home, true);
            generate();
            return;
        }
        try {
            File tmp = new File(getCacheDir(), "in.tmp"), dst = new File(getCacheDir(), "in.step");
            try (InputStream in = getContentResolver().openInputStream(u); OutputStream out = new FileOutputStream(tmp)) {
                if (in == null) throw new IOException("sin datos");
                copy(in, out);
            }
            if (!tmp.renameTo(dst)) throw new IOException("sin espacio");
            step = dst;   // solo si la copia terminó bien
        } catch (Exception e) {
            Ui.snack(rootFrame, t("No se pudo leer el archivo:") + " " + e.getMessage(), true);
            return;
        }
        tols.clear();
        ed.reset();
        stepName = name;
        String base = name.replaceAll("(?i)\\.(step|stp)$", "");
        title.setText(base);
        partNo.setText(""); material.setText(""); tol.setText("");
        headTitle.setText(name);
        pdf = null;
        zoom.setBitmap(null);
        Ui.swap(work, home, true);
        generate();
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    }

    private void generate() {
        if (step == null) return;
        update.setEnabled(false);
        status.setText(t("Generando plano…"));
        status.setAlpha(1f);
        status.animate().alpha(0.35f).setDuration(700).withEndAction(() -> { if (!status.getText().toString().isEmpty()) status.animate().alpha(1f).setDuration(700).start(); }).start();
        zoom.animate().alpha(0.25f).setDuration(200).start();
        final String tolsText = tolsText();
        final String t = title.getText().toString(), p = partNo.getText().toString(), m = material.getText().toString(), g = tol.getText().toString();
        final Loader[] ld = {null};
        final Runnable showLd = () -> { ld[0] = new Loader(this, t("Generando plano…"), t("Las piezas complejas pueden tardar unos minutos.")); ld[0].show(rootFrame); };
        rootFrame.postDelayed(showLd, 1500);
        final int my = ++genId;
        new Thread(() -> { synchronized (GEN_LOCK) {
            File out = new File(getCacheDir(), "plano.pdf");
            out.delete();
            new File(getCacheDir(), "plano.pdf.csv").delete();
            Native.setProjection(I18n.thirdAngle());
            Native.setDfm(I18n.dfm());
            String r0 = Native.generate(step.getPath(), out.getPath(), t, p, m, g, tolsText, I18n.lang(), I18n.imperial(), I18n.sheet(), I18n.explode(), I18n.inspect());
            String inf = r0.startsWith("ERROR") || !out.exists() ? "" : Native.render(out.getPath(), String.join("\n", ed.ops));
            if (inf.startsWith("ERROR")) inf = "";
            final String info = inf, r = inf.isEmpty() ? r0 : r0.replaceAll("(?m)^(AGUJERO|VISTA)\t.*\n?", "") + "\n" + inf;
            Bitmap bmp = out.exists() ? render(out) : null;
            runOnUiThread(() -> {
                rootFrame.removeCallbacks(showLd); if (ld[0] != null) ld[0].hide(rootFrame);
                if (my != genId) return;   // llegó otra carga/regeneración: este resultado ya no vale
                update.setEnabled(true);
                status.setText("");
                showResult(r);
                if (r0.startsWith("DESCARTE")) {
                    pdf = null; rail.setVisibility(View.GONE); zoom.setBitmap(null); zoom.setAlpha(1f); if (mode != 0) setMode(0);
                    if (android.os.Build.VERSION.SDK_INT >= 30) rootFrame.performHapticFeedback(android.view.HapticFeedbackConstants.REJECT);
                    return;
                }
                if (out.exists()) showRail(r0, out);
                if (!info.isEmpty()) ed.info(info);
                if (bmp != null) { pdf = out; zoom.setBitmap(bmp); applyMarks(bmp); applyHoles(bmp); buildEditBar(); zoom.setAlpha(0f); zoom.animate().alpha(1f).setDuration(450).start(); }
            });
        } }).start();
    }
    private int genId;
    private static final Object GEN_LOCK = new Object();

    private Bitmap render(File f) {
        try (ParcelFileDescriptor fd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY); PdfRenderer r = new PdfRenderer(fd); PdfRenderer.Page pg = r.openPage(Math.min(ed.page, r.getPageCount() - 1))) {
            int w = 3000, h = (int) ((long) w * pg.getHeight() / pg.getWidth());
            Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            b.eraseColor(Color.WHITE);
            pg.render(b, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
            return b;
        } catch (Exception e) {
            return null;
        }
    }

    @Override public void onBackPressed() {
        if (work.getVisibility() == View.VISIBLE) Ui.swap(home, work, false);
        else super.onBackPressed();
    }
}
