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
    private boolean comma;
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
        grp.clear(); gname.clear(); txt.clear(); ttxt.clear();
        int nPts = 0;
        comma = false;
        for (String l : r.split("\n")) {
            String[] q = l.split("\t", -1);
            try {
                if (l.startsWith("PAGINA\t") && q[1].equals(pg)) { sw = Float.parseFloat(q[2]); sh = Float.parseFloat(q[3]); scale = Float.parseFloat(q[4]); }
                else if (l.startsWith("GRUPO\t") && q[1].equals(pg)) {
                    grp.add(new float[]{Integer.parseInt(q[2]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7])});
                    gname.add(q[3]);
                } else if (l.startsWith("TEXTO\t") && q[1].equals(pg)) {
                    txt.add(new float[]{Integer.parseInt(q[2]), Integer.parseInt(q[3]), Float.parseFloat(q[4]), Float.parseFloat(q[5]), Float.parseFloat(q[6]), Float.parseFloat(q[7]), Float.parseFloat(q[8])});
                    ttxt.add(q.length > 9 ? q[9] : "");
                    if (q.length > 9 && q[9].matches(".*\\d,\\d.*")) comma = true;
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

    void add(String op) { ops.add(op); redo.clear(); host.changed(); }
    void undo() { if (ops.isEmpty()) return; redo.add(ops.remove(ops.size() - 1)); host.changed(); }
    void redo() { if (redo.isEmpty()) return; ops.add(redo.remove(redo.size() - 1)); host.changed(); }
    void reset() { ops.clear(); redo.clear(); selG = selT = -1; page = 0; dimPend = false; }

    void scaleSel(float k) { if (selG >= 0) add("S\t" + page + "\t" + selG + "\t" + f(k)); }
    void scaleAll(float k) { for (float[] g : grp) ops.add("S\t" + page + "\t" + (int) g[0] + "\t" + f(k)); redo.clear(); host.changed(); }
    void deleteSel() {
        if (selT >= 0) { add("TD\t" + page + "\t" + selT); selT = -1; }
        else if (selG >= 0) { add("H\t" + page + "\t" + selG); selG = -1; }
        host.toolbar();
    }
    void editSelText() {
        int i = textIndex(selT);
        if (i < 0) return;
        final int t = selT;
        host.ask("Editar texto", ttxt.get(i), s -> add("T\t" + page + "\t" + t + "\t" + clean(s)));
    }
    String selName() { int i = groupIndex(selG); return selG >= 0 && i >= 0 ? gname.get(i) : selT >= 0 ? "Texto" : ""; }

    void setPage(int p) { if (p == page) return; page = p; selG = selT = -1; dimPend = false; info(raw); host.changed(); }
    void setTool(int t) { tool = t; dimPend = false; selG = selT = -1; dragging = false; host.toolbar(); }

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
        if (tool == SEL) {
            if (dragging) {
                float dx = x - ax, dy = y - ay;
                if (selT >= 0) add("TM\t" + page + "\t" + selT + "\t" + f(dx) + "\t" + f(dy));
                else if (selG >= 0) add("M\t" + page + "\t" + selG + "\t" + f(dx) + "\t" + f(dy));
            } else if (wasSel && selT >= 0) editSelText();
            dragging = false;
            return;
        }
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
            float[] q = {(r[0] + ox) * kx, (sh - r[3] - oy) * ky, (r[2] + ox) * kx, (sh - r[1] - oy) * ky};
            m.mapPoints(q);
            c.drawRect(q[0], q[1], q[2], q[3], p);
        }
        p.setPathEffect(null);
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
