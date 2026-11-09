// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

import android.content.Context;
import android.graphics.*;
import android.animation.ValueAnimator;
import android.view.View;
import android.view.animation.LinearInterpolator;

/** Logo "D con cota". */
public class LogoView extends View {
    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private ValueAnimator va; private float ph = -1;   // ph<0: logo fijo; 0..1: animación de carga

    public LogoView(Context c) { super(c); p.setStyle(Paint.Style.STROKE); p.setStrokeCap(Paint.Cap.ROUND); p.setStrokeJoin(Paint.Join.ROUND); }

    /** Animación de carga: un trazo recorre la D (como un lápiz que dibuja) y la cota se abre y se cierra midiéndola. */
    public void startAnim() { stopAnim(); va = ValueAnimator.ofFloat(0, 1); va.setDuration(2600); va.setRepeatCount(-1); va.setInterpolator(new LinearInterpolator()); va.addUpdateListener(v -> { ph = (float) v.getAnimatedValue(); invalidate(); }); va.start(); }
    public void stopAnim() { if (va != null) va.cancel(); va = null; ph = -1; invalidate(); }

    @Override protected void onDraw(Canvas c) {
        float w = getWidth(), h = getHeight(), s = Math.min(w, h), u = s / 100f;
        c.translate((w - s) / 2, (h - s) / 2);
        p.setColor(Ui.PAPER);
        p.setStrokeWidth(7 * u);
        Path d = new Path();
        d.moveTo(28 * u, 14 * u);
        d.lineTo(28 * u, 70 * u);
        d.lineTo(48 * u, 70 * u);
        d.arcTo(new RectF(24 * u, 14 * u, 76 * u, 70 * u), 90, -180);
        d.close();
        if (ph < 0) {
            c.drawPath(d, p);
            p.setColor(Ui.TEAL);
            p.setStrokeWidth(3.2f * u);
            c.drawLine(20 * u, 86 * u, 84 * u, 86 * u, p);
            c.drawLine(20 * u, 80 * u, 20 * u, 92 * u, p);
            c.drawLine(84 * u, 80 * u, 84 * u, 92 * u, p);
            return;
        }
        p.setAlpha(55); c.drawPath(d, p); p.setAlpha(255);   // D tenue de fondo + trazo vivo que la recorre
        PathMeasure pm = new PathMeasure(d, true); float L = pm.getLength();
        float head = ph * L, tail = head - 0.55f * L; Path seg = new Path();
        if (tail < 0) { pm.getSegment(L + tail, L, seg, true); pm.getSegment(0, head, seg, true); } else pm.getSegment(tail, head, seg, true);
        c.drawPath(seg, p);
        // cota que se abre y se cierra (mide la D): vaivén suave con extremos que se desplazan
        float k = 0.5f - 0.5f * (float) Math.cos(ph * 2 * Math.PI), half = (14 + 26 * k) * u;
        p.setColor(Ui.TEAL); p.setStrokeWidth(3.2f * u);
        c.drawLine(52 * u - half, 86 * u, 52 * u + half, 86 * u, p);
        c.drawLine(52 * u - half, 80 * u, 52 * u - half, 92 * u, p);
        c.drawLine(52 * u + half, 80 * u, 52 * u + half, 92 * u, p);
    }
}
