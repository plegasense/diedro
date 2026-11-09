// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

import android.content.Context;
import android.view.Gravity;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Pantalla de carga: velo + tarjeta con arco giratorio, aviso y tiempo transcurrido. Aparece solo si la espera pasa de 1,5 s. */
final class Loader extends FrameLayout {
    private final LogoView spin;
    private final TextView clock, stageTx, pctTx;
    private final android.widget.ProgressBar bar;
    private static final String[] STAGES = {"Leyendo el modelo", "Analizando la pieza", "Vistas y cotas", "Vista isométrica", "Globos de inspección", "Escribiendo el PDF"};
    private static final String[] TIPS = {"Cada cota del plano sigue ISO 129-1.", "Diedro funciona sin conexión: tu pieza no sale de este dispositivo.", "En Ajustes eliges el formato de papel y el primer o tercer diedro.", "El texto del PDF usa osifont, la letra normalizada del dibujo técnico (ISO 3098)."};
    private TextView hintTx; private int tip;
    private final Runnable rotate = new Runnable() { @Override public void run() {
        tip = (tip + 1) % TIPS.length;
        hintTx.animate().alpha(0f).setDuration(250).withEndAction(() -> { hintTx.setText(I18n.tr(TIPS[tip])); hintTx.animate().alpha(1f).setDuration(250).start(); }).start();
        postDelayed(this, 6000); } };
    private final long t0 = System.currentTimeMillis();
    private final Runnable tick = new Runnable() { @Override public void run() {
        long s = (System.currentTimeMillis() - t0) / 1000; clock.setText(String.format("%d:%02d", s / 60, s % 60)); 
        int v = Native.progress(), pc = v / 10, st = Math.max(0, Math.min(5, v % 10));
        bar.setProgress(pc); pctTx.setText(pc + " %"); stageTx.setText(I18n.tr(STAGES[st]) + "…");
        postDelayed(this, 400); } };

    Loader(Context c, String title, String hint) {
        super(c);
        setBackgroundColor(0xB3081017); setClickable(true); setAlpha(0f);
        LinearLayout card = new LinearLayout(c); card.setOrientation(LinearLayout.VERTICAL); card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setBackground(Ui.outline(c, Ui.SURFACE, Ui.SURFACE2, 22)); int p = Ui.dp(c, 28); card.setPadding(p, p, p, p);
        spin = new LogoView(c); card.addView(spin, new LinearLayout.LayoutParams(Ui.dp(c, 96), Ui.dp(c, 96)));
        TextView a = Ui.text(c, title, 17, Ui.TEXT, true); a.setGravity(Gravity.CENTER); a.setPadding(0, Ui.dp(c, 16), 0, 0); card.addView(a);
        clock = Ui.text(c, "0:00", 24, Ui.TEAL, true); clock.setGravity(Gravity.CENTER); clock.setTypeface(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD); card.addView(clock);
        bar = new android.widget.ProgressBar(c, null, android.R.attr.progressBarStyleHorizontal); bar.setMax(100);
        bar.getProgressDrawable().setColorFilter(Ui.TEAL, android.graphics.PorterDuff.Mode.SRC_IN);
        LinearLayout.LayoutParams bl = new LinearLayout.LayoutParams(-1, Ui.dp(c, 8)); bl.topMargin = Ui.dp(c, 12); card.addView(bar, bl);
        stageTx = Ui.text(c, "", 13, Ui.TEXT, false); stageTx.setGravity(Gravity.CENTER); stageTx.setPadding(0, Ui.dp(c, 6), 0, 0); card.addView(stageTx);
        pctTx = Ui.text(c, "", 12, Ui.MUTED, false); pctTx.setGravity(Gravity.CENTER); card.addView(pctTx);
        TextView h = Ui.text(c, hint, 12, Ui.MUTED, false); h.setGravity(Gravity.CENTER); h.setPadding(0, Ui.dp(c, 6), 0, 0); card.addView(h); hintTx = h;
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Ui.dp(c, 300), -2, Gravity.CENTER); addView(card, lp);
    }

    void show(FrameLayout root) { root.addView(this, -1, -1); animate().alpha(1f).setDuration(250).start(); spin.startAnim(); post(tick); postDelayed(rotate, 6000); }
    void hide(FrameLayout root) { removeCallbacks(tick); removeCallbacks(rotate); spin.stopAnim(); animate().alpha(0f).setDuration(200).withEndAction(() -> root.removeView(this)).start(); }
}
