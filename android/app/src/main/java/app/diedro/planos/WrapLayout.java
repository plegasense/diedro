// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/** Reparte los hijos en filas (chips). */
public class WrapLayout extends ViewGroup {
    private final int gap;

    public WrapLayout(Context c) { super(c); gap = Ui.dp(c, 8); }

    @Override protected void onMeasure(int wSpec, int hSpec) {
        int maxW = MeasureSpec.getSize(wSpec), x = 0, y = 0, rowH = 0;
        for (int i = 0; i < getChildCount(); i++) {
            View v = getChildAt(i);
            v.measure(MeasureSpec.makeMeasureSpec(maxW, MeasureSpec.AT_MOST), MeasureSpec.UNSPECIFIED);
            if (x > 0 && x + v.getMeasuredWidth() > maxW) { x = 0; y += rowH + gap; rowH = 0; }
            x += v.getMeasuredWidth() + gap;
            rowH = Math.max(rowH, v.getMeasuredHeight());
        }
        setMeasuredDimension(maxW, y + rowH);
    }

    @Override protected void onLayout(boolean ch, int l, int t, int r, int b) {
        int maxW = r - l, x = 0, y = 0, rowH = 0;
        for (int i = 0; i < getChildCount(); i++) {
            View v = getChildAt(i);
            if (x > 0 && x + v.getMeasuredWidth() > maxW) { x = 0; y += rowH + gap; rowH = 0; }
            v.layout(x, y, x + v.getMeasuredWidth(), y + v.getMeasuredHeight());
            x += v.getMeasuredWidth() + gap;
            rowH = Math.max(rowH, v.getMeasuredHeight());
        }
    }
}
