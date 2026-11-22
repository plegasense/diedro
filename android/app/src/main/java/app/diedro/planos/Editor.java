// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

import android.graphics.*;
import java.util.ArrayList;
import java.util.Locale;

/** Edición del plano: lista de operaciones (deshacer/rehacer), selección, imán a vértices y herramientas. Coordenadas en mm de hoja (y hacia arriba). */
final class Editor implements ZoomView.EditHandler {
    interface Host {
        void changed();                                   // se modificaron las operaciones: hay que volver a pintar
        void toolbar();                                   // cambió selección o herramienta
        void ask(String title, String init, java.util.function.Consumer<String> ok);
    }

    static final int SEL = 0, TEXT = 1, LINE = 2, ARROW = 3, DIM = 4;
    final ArrayList<String> ops = new ArrayList<>(), redo = new ArrayList<>();
    boolean on;
    int tool = SEL, selG = -1, selT = -1, page = 0, pages = 1;
    private float ax0, ay0, bx0, by0;
    boolean dimPend;   // cota: ya se midieron A y B, falta tocar dónde colocar la línea
    private String raw = "";
    private final Host host;
    private float sw = 297, sh = 210, scale = 1;
    private final ArrayList<float[]> grp = new ArrayList<>();   // {g, x0,y0,x1,y1}
    private final ArrayList<String> gname = new ArrayList<>();
    private final ArrayList<float[]> txt = new ArrayList<>();   // {idx, g, x, y, h, ang, ancho}
    private final ArrayList<String> ttxt = new ArrayList<>();
    private float[] pts = new float[0];
    private final ArrayList<float[]> ext = new ArrayList<>();   // {g, x1,y1,x2,y2} de las líneas del usuario (asas)
    private int hEnd = -1;   // extremo que se arrastra (0/1) o -1
    private boolean comma, imp;
    private final ArrayList<float[]> ents = new ArrayList<>();    // geometría acotable: {0,g,x1,y1,x2,y2} línea · {1,g,cx,cy,r,a0,a1} arco · {2,g,x,y} punto
    final ArrayList<float[]> picks = new ArrayList<>();           // elementos ya tocados para la cota en curso
    int dmode;   // 0 auto · 1 Ø · 2 R · 3 horizontal · 4 vertical · 5 alineada · 6 rosca · 7 entre centros
    String hint = "";
    // gesto en curso
    private float ax, ay, bx, by, sx;
    private boolean dragging, wasSel;
    private float px0, py0;
    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

    Editor(Host h) { host = h; }

    /** Lee las líneas PAGINA/GRUPO/TEXTO/PUNTOS que devuelve Native.render (de la página activa). */
    void info(String r) {
        raw = r;
        final String pg = String.valueOf(page);
        int np = 0;
        for (String l : r.split("\n")) if (l.startsWith("PAGINA\t")) np++;
        pages = Math.max(1, np);
        grp.clear(); gname.clear(); txt.clear(); ttxt.clear(); ext.clear(); ents.clear(); picks.clear(); imp = false;
        int nPts = 0;
        comma = false;
        for (String l : r.split("\n")) {
            String[] q = l.split("\t", -1);
            try {
                if (l.startsWith("PAGINA\t") && q[1].equals(pg)) { sw = Float.parseFloat(q[2]); sh = Float.parseFloat(q[3]); scale = Float.parseFloat(q[4]); imp = q.length > 5 && q[5].equals("1"); }
                else if (l.startsWith("LINEA\t") && q[1].equals(pg)) ents.add(new float[]{0, Integer.parseInt(q[2]), Float.parseFloat(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6])});
                else if (l.startsWith("ARCO\t") && q[1].equals(pg)) ents.add(new float[]{1, Integer.parseInt(q[2]), Float.parseFloat(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7])});
                else if (l.startsWith("GRUPO\t") && q[1].equals(pg)) {
                    grp.add(new float[]{Integer.parseInt(q[2]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7])});
                    gname.add(q[3]);
                } else if (l.startsWith("TEXTO\t") && q[1].equals(pg)) {
                    txt.add(new float[]{Integer.parseInt(q[2]), Integer.parseInt(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7]), Float.parseFloat(q[8])});
                    ttxt.add(q.length > 9 ? q[9] : "");
                    if (q.length > 9 && q[9].matches(".*\\d,\\d.*")) comma = true;
                } else if (l.startsWith("EXTREMOS\t") && q[1].equals(pg)) {
                    ext.add(new float[]{Integer.parseInt(q[2]), Float.parseFloat(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6])});
                } else if (l.startsWith("PUNTOS") && nPts++ == page) {
                    pts = new float[(q.length - 1) / 2 * 2];
                    for (int i = 0; i < pts.length; i++) pts[i] = Float.parseFloat(q[i + 1]);
                }
            } catch (Exception ignored) {}
        }
        if (gname.size() > 0 && selG >= 0 && groupIndex(selG) < 0) selG = -1;
        if (selT >= 0 && textIndex(selT) < 0) selT = -1;
    }

    private int groupIndex(int g) { for (int i = 0; i < grp.size(); i++) if ((int) grp.get(i)[0] == g) return i; return -1; }
    private int textIndex(int t) { for (int i = 0; i < txt.size(); i++) if ((int) txt.get(i)[0] == t) return i; return -1; }

    // ------------------------------------------------------------ operaciones
    private static String f(float v) { return String.format(Locale.ROOT, "%.3f", v); }
    private static String clean(String s) { return s.replace('\t', ' ').replace('\n', ' ').trim(); }

    private ArrayList<String> backup = new ArrayList<>();   // ediciones guardadas al «volver al original» (se pueden recuperar)
    boolean hasBackup() { return ops.isEmpty() && !backup.isEmpty(); }
    boolean canOriginal() { return !ops.isEmpty(); }
    /** Vuelve al plano original sin perder las ediciones: quedan guardadas hasta la siguiente edición. */
    void original() { if (ops.isEmpty()) return; backup = new ArrayList<>(ops); ops.clear(); redo.clear(); selG = selT = -1; dimPend = false; picks.clear(); host.changed(); }
    void restoreOriginal() { if (!hasBackup()) return; ops.addAll(backup); backup.clear(); host.changed(); }
    void add(String op) { ops.add(op); redo.clear(); backup.clear(); host.changed(); }
    void undo() { if (ops.isEmpty()) return; redo.add(ops.remove(ops.size() - 1)); host.changed(); }
    void redo() { if (redo.isEmpty()) return; ops.add(redo.remove(redo.size() - 1)); host.changed(); }
    void reset() { backup.clear(); ops.clear(); redo.clear(); selG = selT = -1; page = 0; dimPend = false; }

    void scaleSel(float k) { if (selG >= 0) add("S\t" + page + "\t" + selG + "\t" + f(k)); }
    void scaleAll(float k) { for (float[] g : grp) ops.add("S\t" + page + "\t" + (int) g[0] + "\t" + f(k)); redo.clear(); host.changed(); }
    float pinchK = 1;
    boolean canPinch() { return on && tool == SEL && (selG >= 0 || selT >= 0); }
    void pinchEnd() {   // pellizco terminado: aplica el factor a la selección
        float k = Math.max(0.2f, Math.min(5f, pinchK)); pinchK = 1;
        if (Math.abs(k - 1) < 0.04f) { host.changed(); return; }
        if (selT >= 0) add("TS\t" + page + "\t" + selT + "\t" + f(k)); else if (selG >= 0) scaleSel(k);
    }
    void deleteSel() {
        if (selT >= 0) { add("DD\t" + page + "\t" + selT); selT = -1; }
        else if (selG >= 0) { add("H\t" + page + "\t" + selG); selG = -1; }
        host.toolbar();
    }
    void duplicateSel() {   // copia del texto seleccionado, desplazada 5 mm
        int i = textIndex(selT);
        if (i < 0) return;
        float[] t = txt.get(i);
        add("AT\t" + page + "\t" + f(t[2] + 5) + "\t" + f(t[3] - 5) + "\t" + f(t[4]) + "\t" + clean(ttxt.get(i)));
    }
    void editSelText() {
        int i = textIndex(selT);
        if (i < 0) return;
        final int t = selT;
        host.ask("Editar texto", ttxt.get(i), s -> add("T\t" + page + "\t" + t + "\t" + clean(s)));
    }
    String selName() { int i = groupIndex(selG); return selG >= 0 && i >= 0 ? gname.get(i) : selT >= 0 ? "Texto" : ""; }

    void setPage(int p) { if (p == page) return; page = p; selG = selT = -1; dimPend = false; picks.clear(); info(raw); host.changed(); }
    void setTool(int t) { tool = t; dmode = 0; dimPend = false; picks.clear(); hint = t == DIM ? "Toca una arista, círculo, arco o punto para acotar" : ""; selG = selT = -1; dragging = false; host.toolbar(); }

    // ------------------------------------------------------------ gestos
    private float kOf(int g) {  // escala acumulada del grupo por las operaciones S
        float k = 1;
        for (String o : ops) { String[] q = o.split("\t"); if (q[0].equals("S") && q.length > 3 && Integer.parseInt(q[2]) == g) k *= Float.parseFloat(q[3]); }
        return k;
    }

    private int hitGroup(float x, float y) {
        int best = -1; float ba = Float.MAX_VALUE;
        for (int i = 0; i < grp.size(); i++) {
            float[] g = grp.get(i);
            if (g[0] < 0 || x < g[1] - 1 || x > g[3] + 1 || y < g[2] - 1 || y > g[4] + 1) continue;
            float a = (g[3] - g[1]) * (g[4] - g[2]);
            if (a < ba) { ba = a; best = (int) g[0]; }
        }
        return best;
    }

    private int hitText(float x, float y) {
        for (int i = txt.size() - 1; i >= 0; i--) {
            float[] t = txt.get(i);
            double a = -Math.toRadians(t[5]), dx = x - t[2], dy = y - t[3];
            double u = dx * Math.cos(a) - dy * Math.sin(a), v = dx * Math.sin(a) + dy * Math.cos(a);
            if (u > -1.5 && u < t[6] + 1.5 && v > -1.5 && v < t[4] + 1.5) return (int) t[0];
        }
        return -1;
    }

    private float[] snap(float x, float y) {
        float r = 14f / sx * sw, bd = r * r;
        float[] o = {x, y, 0};
        for (int i = 0; i + 1 < pts.length; i += 2) {
            float dx = pts[i] - x, dy = pts[i + 1] - y, d = dx * dx + dy * dy;
            if (d < bd) { bd = d; o[0] = pts[i]; o[1] = pts[i + 1]; o[2] = 1; }
        }
        return o;
    }

    @Override public boolean down(float fx, float fy, float pxPerWidth, float screenX, float screenY) {
        if (!on) return false;
        sx = pxPerWidth;
        float x = fx * sw, y = (1 - fy) * sh;
        px0 = screenX; py0 = screenY;
        dragging = false;
        hEnd = -1;
        if (tool == SEL && selG >= 0) {   // asas en los extremos de una línea del usuario
            float r = 18f / sx * sw;
            for (float[] e : ext) if ((int) e[0] == selG)
                for (int k = 0; k < 2; k++) if (Math.hypot(x - e[1 + 2 * k], y - e[2 + 2 * k]) < r) { hEnd = k; ax = x; ay = y; bx = x; by = y; return true; }
        }
        if (tool == SEL) {
            int t = hitText(x, y);
            wasSel = t >= 0 && t == selT;
            int g = t >= 0 ? -1 : hitGroup(x, y);
            if (t < 0 && g < 0) { if (selG >= 0 || selT >= 0) { selG = selT = -1; host.toolbar(); } return false; }
            boolean ch = t != selT || g != selG;
            selT = t; selG = g; ax = x; ay = y; bx = x; by = y;
            if (ch) host.toolbar();
            return true;
        }
        float[] s = snap(x, y);
        ax = bx = s[0]; ay = by = s[1];
        return true;
    }

    @Override public void move(float fx, float fy, float screenX, float screenY) {
        float x = fx * sw, y = (1 - fy) * sh;
        if (Math.hypot(screenX - px0, screenY - py0) > 20) dragging = true;
        if (tool == SEL) { bx = x; by = y; return; }
        float[] s = snap(x, y);
        bx = s[0]; by = s[1];
    }

    @Override public void up(float fx, float fy) {
        float x = fx * sw, y = (1 - fy) * sh;
        if (tool == SEL && hEnd >= 0) {
            if (dragging) { float[] sn = snap(x, y); for (float[] e : ext) if ((int) e[0] == selG) add("LE\t" + page + "\t" + selG + "\t" + hEnd + "\t" + f(sn[0]) + "\t" + f(sn[1])); }
            hEnd = -1; dragging = false;
            return;
        }
        if (tool == SEL) {
            if (dragging) {
                float dx = x - ax, dy = y - ay;
                if (selT >= 0) add("DM\t" + page + "\t" + selT + "\t" + f(dx) + "\t" + f(dy));
                else if (selG >= 0) add("M\t" + page + "\t" + selG + "\t" + f(dx) + "\t" + f(dy));
            } else if (wasSel && selT >= 0) editSelText();
            dragging = false;
            return;
        }
        if (tool == DIM && !dimPend && !dragging) { dimTap(x, y); return; }
        float[] s = snap(x, y);
        bx = s[0]; by = s[1];
        final float x1 = ax, y1 = ay, x2 = bx, y2 = by;
        dragging = false;
        if (tool == TEXT) { host.ask("Texto", "", s2 -> { if (!clean(s2).isEmpty()) add("AT\t" + page + "\t" + f(x1) + "\t" + f(y1) + "\t3.5\t" + clean(s2)); }); return; }
        if (tool == DIM && dimPend) {   // 3.er toque: la línea de cota pasa por aquí
            dimPend = false;
            float ux = bx0 - ax0, uy = by0 - ay0, L = (float) Math.hypot(ux, uy);
            final float off = (-(uy / L) * (x - ax0) + (ux / L) * (y - ay0)), k = scale * kOf(hitGroup((ax0 + bx0) / 2, (ay0 + by0) / 2));
            String v = String.format(Locale.ROOT, "%.2f", L / k).replaceAll("\\.?0+$", "");
            final float a1 = ax0, b1 = ay0, a2 = bx0, b2 = by0;
            host.ask("Valor de la cota", comma ? v.replace('.', ',') : v, s2 -> add("AD\t" + page + "\t" + f(a1) + "\t" + f(b1) + "\t" + f(a2) + "\t" + f(b2) + "\t" + f(off) + "\t" + clean(s2)));
            return;
        }
        float len = (float) Math.hypot(x2 - x1, y2 - y1);
        if (len < 1) return;
        if (tool == LINE) add("AL\t" + page + "\t" + f(x1) + "\t" + f(y1) + "\t" + f(x2) + "\t" + f(y2) + "\t0");
        else if (tool == ARROW) host.ask("Nota", "", s2 -> add("AA\t" + page + "\t" + f(x1) + "\t" + f(y1) + "\t" + f(x2) + "\t" + f(y2) + "\t" + clean(s2)));
        else if (tool == DIM) { ax0 = x1; ay0 = y1; bx0 = x2; by0 = y2; dimPend = true; host.toolbar(); }
    }


    // ------------------------------------------------------------ cota inteligente (toques sobre la geometría)
    private float tolMm() { return 16f / sx * sw; }

    private static double segDist(double px, double py, double x1, double y1, double x2, double y2) {
        double dx = x2 - x1, dy = y2 - y1, l2 = dx * dx + dy * dy, t = l2 == 0 ? 0 : Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / l2));
        return Math.hypot(px - x1 - t * dx, py - y1 - t * dy);
    }

    /** Elemento acotable bajo el toque: vértice (≤ tol), si no el círculo/arista más cercano. */
    private float[] pick(float x, float y) {
        float tol = tolMm(), bd = tol * tol;
        float[] best = null;
        for (int i = 0; i + 1 < pts.length; i += 2) { float dx = pts[i] - x, dy = pts[i + 1] - y, d = dx * dx + dy * dy; if (d < bd) { bd = d; best = new float[]{2, -1, pts[i], pts[i + 1]}; } }
        if (best != null) return best;
        double bb = tol;
        for (float[] e : ents) {
            double d;
            if (e[0] == 0) d = segDist(x, y, e[2], e[3], e[4], e[5]);
            else {
                double ang = Math.toDegrees(Math.atan2(y - e[3], x - e[2])), a0 = e[5], sweep = e[6] - e[5];
                if (sweep < 359) { double u = ((ang - a0) % 360 + 360) % 360; if (u > sweep + 6) continue; }
                d = Math.abs(Math.hypot(x - e[2], y - e[3]) - e[4]);
            }
            if (d < bb) { bb = d; best = e.clone(); }
        }
        if (best != null && best[0] == 1 && dmode == 7) return new float[]{2, best[1], best[2], best[3]};   // «entre centros»: el círculo cuenta como su centro
        return best;
    }

    private static boolean same(float[] a, float[] b) { return java.util.Arrays.equals(a, b); }

    private void dimTap(float x, float y) {
        float[] h = pick(x, y);
        if (h != null && h[0] == 1) { picks.clear(); picks.add(h); hint = "Toca donde colocar la cota"; host.toolbar(); return; }
        if (picks.isEmpty()) { if (h != null) { picks.add(h); hint = h[0] == 2 ? "Toca otra arista o punto, o toca donde colocar la cota" : "Toca otra arista o punto, o toca donde colocar la cota"; } host.toolbar(); return; }
        if (picks.size() == 1 && h != null && !same(h, picks.get(0)) && picks.get(0)[0] != 1) { picks.add(h); hint = "Toca donde colocar la cota"; host.toolbar(); return; }
        if (picks.size() == 1 && picks.get(0)[0] == 2) return;   // un punto solo no se acota: falta otro
        place(x, y);
    }

    private String num(double mm, int g) {
        double v = mm / (scale * kOf(g));
        String s;
        if (imp) { s = String.format(Locale.ROOT, "%.3f", v / 25.4); if (s.startsWith("0.")) s = s.substring(1); }   // ASME Y14.5 §4.3.2(b): 3 decimales, sin cero inicial
        else s = String.format(Locale.ROOT, "%.2f", v).replaceAll("(\\.\\d*?)0+$", "$1").replaceAll("\\.$", "");
        return comma ? s.replace('.', ',') : s;
    }

    private void place(float x, float y) {
        final float[] a = picks.get(0), b = picks.size() > 1 ? picks.get(1) : null;
        final int g = (int) (a[1] >= 0 ? a[1] : b != null ? b[1] : -1);
        String op = null, txt = "";
        if (a[0] == 1) {
            boolean full = a[6] - a[5] >= 359;
            int m = dmode == 1 || dmode == 2 || dmode == 6 ? dmode : full ? 1 : 2;
            double an = Math.toDegrees(Math.atan2(y - a[3], x - a[2]));
            if (m == 2) { txt = "R" + num(a[4], g); op = "RAD\t" + page + "\t" + f(a[2]) + "\t" + f(a[3]) + "\t" + f(a[4]) + "\t" + f((float) an) + "\t"; }
            else { txt = (m == 6 ? "M" : "Ø") + num(2 * a[4], g); op = "DIA\t" + page + "\t" + f(a[2]) + "\t" + f(a[3]) + "\t" + f(a[4]) + "\t" + f((float) an) + "\t"; }
        } else {
            double[] p1, p2;
            if (a[0] == 0 && b != null && b[0] == 0) {   // dos aristas: ángulo o distancia entre paralelas
                double d1x = a[4] - a[2], d1y = a[5] - a[3], d2x = b[4] - b[2], d2y = b[5] - b[3], l1 = Math.hypot(d1x, d1y), l2 = Math.hypot(d2x, d2y);
                double cr = (d1x * d2y - d1y * d2x) / (l1 * l2);
                if (Math.abs(cr) < 0.01) {   // paralelas
                    double t = ((x - a[2]) * d1x + (y - a[3]) * d1y) / (l1 * l1);
                    double q1x = a[2] + t * d1x, q1y = a[3] + t * d1y, u = ((q1x - b[2]) * d2x + (q1y - b[3]) * d2y) / (l2 * l2);
                    p1 = new double[]{q1x, q1y}; p2 = new double[]{b[2] + u * d2x, b[3] + u * d2y};
                    linear(p1, p2, x, y, g); return;
                }
                double t = ((b[2] - a[2]) * d2y - (b[3] - a[3]) * d2x) / (d1x * d2y - d1y * d2x);
                double vx = a[2] + t * d1x, vy = a[3] + t * d1y;
                double[] rays = {Math.toDegrees(Math.atan2(d1y, d1x)), Math.toDegrees(Math.atan2(-d1y, -d1x)), Math.toDegrees(Math.atan2(d2y, d2x)), Math.toDegrees(Math.atan2(-d2y, -d2x))};
                for (int i = 0; i < 4; i++) rays[i] = (rays[i] % 360 + 360) % 360;
                java.util.Arrays.sort(rays);
                double th = (Math.toDegrees(Math.atan2(y - vy, x - vx)) % 360 + 360) % 360, a0 = rays[3], a1 = rays[0] + 360;
                for (int i = 0; i < 3; i++) if (th >= rays[i] && th < rays[i + 1]) { a0 = rays[i]; a1 = rays[i + 1]; }
                if (th < rays[0]) { a0 = rays[3] - 360; a1 = rays[0]; }
                double r = Math.max(8, Math.min(90, Math.hypot(x - vx, y - vy)));
                String v = String.format(Locale.ROOT, "%.1f", a1 - a0).replaceAll("\\.0$", "");
                if (comma) v = v.replace('.', ',');
                final String op2 = "ANG\t" + page + "\t" + f((float) vx) + "\t" + f((float) vy) + "\t" + f((float) a0) + "\t" + f((float) a1) + "\t" + f((float) r) + "\t";
                finish(op2, v + "°");
                return;
            }
            if (a[0] == 0) { p1 = new double[]{a[2], a[3]}; p2 = new double[]{a[4], a[5]}; }
            else if (b == null) return;
            else if (b[0] == 2) { p1 = new double[]{a[2], a[3]}; p2 = new double[]{b[2], b[3]}; }
            else {   // punto y arista: distancia perpendicular
                double dx = b[4] - b[2], dy = b[5] - b[3], u = ((a[2] - b[2]) * dx + (a[3] - b[3]) * dy) / (dx * dx + dy * dy);
                p1 = new double[]{a[2], a[3]}; p2 = new double[]{b[2] + u * dx, b[3] + u * dy};
            }
            linear(p1, p2, x, y, g); return;
        }
        finish(op, txt);
    }

    private void linear(double[] p1, double[] p2, float x, float y, int g) {
        int m = dmode == 3 || dmode == 4 ? dmode : 5;
        double dx = p2[0] - p1[0], dy = p2[1] - p1[1];
        String op, v;
        if (m == 3) { if (Math.abs(dx) < 0.5) { picks.clear(); host.toolbar(); return; } v = num(Math.abs(dx), g); op = "DX\t" + page + "\t" + f((float) p1[0]) + "\t" + f((float) p1[1]) + "\t" + f((float) p2[0]) + "\t" + f((float) p2[1]) + "\t0\t" + f(y) + "\t"; }
        else if (m == 4) { if (Math.abs(dy) < 0.5) { picks.clear(); host.toolbar(); return; } v = num(Math.abs(dy), g); op = "DX\t" + page + "\t" + f((float) p1[0]) + "\t" + f((float) p1[1]) + "\t" + f((float) p2[0]) + "\t" + f((float) p2[1]) + "\t1\t" + f(x) + "\t"; }
        else {
            double L = Math.hypot(dx, dy);
            if (L < 0.5) { picks.clear(); host.toolbar(); return; }
            float off = (float) (-(dy / L) * (x - p1[0]) + (dx / L) * (y - p1[1]));
            v = num(L, g);
            op = "AD\t" + page + "\t" + f((float) p1[0]) + "\t" + f((float) p1[1]) + "\t" + f((float) p2[0]) + "\t" + f((float) p2[1]) + "\t" + f(off) + "\t";
        }
        finish(op, v);
    }

    private void finish(final String op, String init) {
        picks.clear(); hint = "Toca una arista, círculo, arco o punto para acotar";
        host.toolbar();
        host.ask("Valor de la cota", init, s2 -> { if (!clean(s2).isEmpty()) add(op + clean(s2)); });
    }

    @Override public void cancel() { dragging = false; }

    // ------------------------------------------------------------ dibujo sobre la hoja
    void draw(Canvas c, Matrix m, int bw, int bh, float dp) {
        if (!on) return;
        float kx = bw / sw, ky = bh / sh;
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(2 * dp);
        p.setColor(0xFF36C2B4);
        p.setPathEffect(new DashPathEffect(new float[]{8 * dp, 5 * dp}, 0));
        float ox = dragging && tool == SEL ? bx - ax : 0, oy = dragging && tool == SEL ? by - ay : 0;
        float[] r = null;
        int gi = groupIndex(selG);
        if (selG >= 0 && gi >= 0) { float[] g = grp.get(gi); r = new float[]{g[1] - 1, g[2] - 1, g[3] + 1, g[4] + 1}; }
        int ti = textIndex(selT);
        if (selT >= 0 && ti >= 0) { float[] t = txt.get(ti); r = new float[]{t[2] - 1, t[3] - 1, t[2] + t[6] + 1, t[3] + t[4] + 1}; }
        if (r != null) {
            float cx0 = (r[0] + r[2]) / 2, cy0 = (r[1] + r[3]) / 2, hw = (r[2] - r[0]) / 2 * pinchK, hh = (r[3] - r[1]) / 2 * pinchK;
            r = new float[]{cx0 - hw, cy0 - hh, cx0 + hw, cy0 + hh};
            float[] q = {(r[0] + ox) * kx, (sh - r[3] - oy) * ky, (r[2] + ox) * kx, (sh - r[1] - oy) * ky};
            m.mapPoints(q);
            c.drawRect(q[0], q[1], q[2], q[3], p);
        }
        p.setPathEffect(null);
        if (tool == SEL && selG >= 0) {
            p.setColor(0xFF36C2B4);
            p.setStyle(Paint.Style.FILL);
            for (float[] e : ext) if ((int) e[0] == selG) for (int k = 0; k < 2; k++) {
                float[] q = {e[1 + 2 * k] * kx, (sh - e[2 + 2 * k]) * ky};
                if (hEnd == k && dragging) { q[0] = bx * kx; q[1] = (sh - by) * ky; }
                m.mapPoints(q);
                c.drawCircle(q[0], q[1], 7 * dp, p);
            }
            p.setStyle(Paint.Style.STROKE);
        }
        if (tool == DIM && !picks.isEmpty()) {
            p.setColor(0xFFF2B84B); p.setStrokeWidth(4 * dp);
            for (float[] e : picks) {
                if (e[0] == 0) { float[] q = {e[2] * kx, (sh - e[3]) * ky, e[4] * kx, (sh - e[5]) * ky}; m.mapPoints(q); c.drawLine(q[0], q[1], q[2], q[3], p); }
                else if (e[0] == 1) {
                    Path pa = new Path();
                    int n = 48; float sw0 = e[6] - e[5];
                    for (int i = 0; i <= n; i++) { double t = Math.toRadians(e[5] + sw0 * i / n); float[] q = {(float) (e[2] + e[4] * Math.cos(t)) * kx, (float) (sh - e[3] - e[4] * Math.sin(t)) * ky}; m.mapPoints(q); if (i == 0) pa.moveTo(q[0], q[1]); else pa.lineTo(q[0], q[1]); }
                    c.drawPath(pa, p);
                } else { float[] q = {e[2] * kx, (sh - e[3]) * ky}; m.mapPoints(q); p.setStyle(Paint.Style.FILL); c.drawCircle(q[0], q[1], 7 * dp, p); p.setStyle(Paint.Style.STROKE); }
            }
            p.setStrokeWidth(2 * dp);
        }
        if (dimPend) {
            float[] q = {ax0 * kx, (sh - ay0) * ky, bx0 * kx, (sh - by0) * ky};
            m.mapPoints(q);
            p.setColor(0xFFF2B84B);
            c.drawLine(q[0], q[1], q[2], q[3], p);
        }
        if (tool != SEL && tool != TEXT) {
            float[] q = {ax * kx, (sh - ay) * ky, bx * kx, (sh - by) * ky};
            m.mapPoints(q);
            p.setColor(0xFFF2B84B);
            if (dragging) c.drawLine(q[0], q[1], q[2], q[3], p);
            p.setStyle(Paint.Style.FILL);
            c.drawCircle(q[0], q[1], 4 * dp, p);
            if (dragging) c.drawCircle(q[2], q[3], 4 * dp, p);
        }
    }
}
