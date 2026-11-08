package app.diedro.planos;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.animation.DecelerateInterpolator;
import android.view.animation.OvershootInterpolator;
import android.widget.TextView;

final class Ui {
    static final int BG = 0xFF0F1923, SURFACE = 0xFF17222E, SURFACE2 = 0xFF1F2E3C, TEAL = 0xFF36C2B4, PAPER = 0xFFEDEAE2,
            TEXT = 0xFFE8ECEF, MUTED = 0xFF8FA0AE, AMBER = 0xFFF2B84B, RED = 0xFFFF7B72;

    static int dp(Context c, float v) { return Math.round(v * c.getResources().getDisplayMetrics().density); }

    static GradientDrawable rr(Context c, int color, float radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(c, radiusDp));
        return g;
    }

    static GradientDrawable outline(Context c, int fill, int stroke, float radiusDp) {
        GradientDrawable g = rr(c, fill, radiusDp);
        g.setStroke(dp(c, 1.2f), stroke);
        return g;
    }

    static TextView text(Context c, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    static TextView pill(Context c, String s, int fill, int fg, boolean filled) {
        TextView t = text(c, s, 16, fg, true);
        t.setGravity(Gravity.CENTER);
        t.setBackground(filled ? rr(c, fill, 30) : outline(c, Color.TRANSPARENT, fill, 30));
        t.setPadding(dp(c, 20), dp(c, 14), dp(c, 20), dp(c, 14));
        t.setClickable(true);
        return t;
    }

    /** Respuesta táctil tipo iOS: se hunde al pulsar y rebota al soltar, con vibración suave. */
    static void press(View v) {
        v.setOnTouchListener((x, e) -> {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    x.animate().scaleX(0.96f).scaleY(0.96f).alpha(0.85f).setDuration(80).setInterpolator(new DecelerateInterpolator()).start();
                    x.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    x.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(260).setInterpolator(new OvershootInterpolator(2.5f)).start();
                    break;
            }
            return false;
        });
    }

    /** Aparece desplazándose hacia arriba con retardo escalonado. */
    static void rise(View v, int index, float distDp) {
        v.setAlpha(0f);
        v.setTranslationY(dp(v.getContext(), distDp));
        v.animate().alpha(1f).translationY(0).setStartDelay(60L * index).setDuration(420).setInterpolator(new DecelerateInterpolator(2f)).start();
    }

    /** Transición entre pantallas: la nueva entra desde el lado, la antigua se desliza y se desvanece. */
    static void swap(View in, View out, boolean forward) {
        float w = dp(in.getContext(), 70) * (forward ? 1 : -1);
        in.setVisibility(View.VISIBLE);
        in.setAlpha(0f);
        in.setTranslationX(w);
        in.animate().alpha(1f).translationX(0).setDuration(380).setStartDelay(0).setInterpolator(new DecelerateInterpolator(2.2f)).start();
        out.animate().alpha(0f).translationX(-w * 0.6f).setDuration(260).setInterpolator(new DecelerateInterpolator()).withEndAction(() -> {
            out.setVisibility(View.GONE);
            out.setAlpha(1f);
            out.setTranslationX(0);
        }).start();
    }

    /** Aviso propio (en lugar del Toast del sistema): píldora que sube con un pequeño rebote y se desvanece. */
    static void snack(android.widget.FrameLayout root, String msg, boolean err) {
        Context c = root.getContext();
        TextView t = text(c, (err ? "!  " : "✓  ") + msg, 15, err ? RED : TEXT, true);
        t.setBackground(outline(c, SURFACE, err ? RED : TEAL, 26));
        t.setPadding(dp(c, 22), dp(c, 13), dp(c, 22), dp(c, 13));
        t.setElevation(dp(c, 8));
        android.widget.FrameLayout.LayoutParams lp = new android.widget.FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        lp.bottomMargin = dp(c, 40); lp.leftMargin = lp.rightMargin = dp(c, 16);
        root.addView(t, lp);
        t.setAlpha(0f); t.setTranslationY(dp(c, 30));
        t.performHapticFeedback(android.os.Build.VERSION.SDK_INT >= 30 ? (err ? HapticFeedbackConstants.REJECT : HapticFeedbackConstants.CONFIRM) : HapticFeedbackConstants.VIRTUAL_KEY);
        t.animate().alpha(1f).translationY(0).setDuration(380).setInterpolator(new OvershootInterpolator(1.6f)).withEndAction(() ->
            t.animate().alpha(0f).translationY(dp(c, 14)).setStartDelay(err ? 3600 : 1800).setDuration(300).withEndAction(() -> root.removeView(t)).start()).start();
    }
}
