package app.diedro.planos;

import android.content.Context;
import android.graphics.*;
import android.view.*;

/** Visor con pellizco para zoom, arrastre y doble toque. */
public class ZoomView extends View {
    private Bitmap bmp;
    private final Matrix m = new Matrix();
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);
    private final Paint shadow = new Paint();
    private float fit = 1;
    private final ScaleGestureDetector sg;
    private final GestureDetector gd;
    private float lx, ly;
    private int lastPtr;
    // Marcas tocables (globos del plano): centro en píxeles del bitmap y un identificador (pieza).
    private float[] markXY = new float[0];
    private int[] markIds = new int[0];
    private final java.util.Set<Integer> lit = new java.util.HashSet<>();
    private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
    public interface OnMark { void tapped(int id); }
    private OnMark onMark;
    // Agujeros del plano (centro en píxeles del bitmap) tocables; los iluminados se dibujan con un anillo azul.
    private float[] holeXY = new float[0];
    private final java.util.Set<Integer> litHoles = new java.util.HashSet<>();
    private final Paint hring = new Paint(Paint.ANTI_ALIAS_FLAG);
    private OnMark onHole;

    public interface EditHandler {
        boolean down(float fx, float fy, float pxPerWidth, float sx, float sy);
        void move(float fx, float fy, float sx, float sy);
        void up(float fx, float fy);
        void cancel();
    }
    private Editor edit;
    private boolean editing;
    public void setEditor(Editor e) { edit = e; invalidate(); }
    /** Cambia la imagen conservando el zoom y el encuadre actuales (al editar). */
    public void swapBitmap(Bitmap b) { boolean same = bmp != null && b != null && bmp.getWidth() == b.getWidth() && bmp.getHeight() == b.getHeight(); bmp = b; if (!same) fitToView(); else invalidate(); }
    private float[] frac(float x, float y) {
        Matrix inv = new Matrix();
        float[] q = {x, y};
        if (m.invert(inv)) inv.mapPoints(q);
        return new float[]{q[0] / bmp.getWidth(), q[1] / bmp.getHeight()};
    }

    public ZoomView(Context c) {
        super(c);
        shadow.setColor(0x66000000);
        ring.setStyle(Paint.Style.STROKE);
        ring.setColor(0xFFFF8A00);
        hring.setStyle(Paint.Style.STROKE);
        hring.setColor(0xFF1E88E5);
        sg = new ScaleGestureDetector(c, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector d) { zoom(d.getScaleFactor(), d.getFocusX(), d.getFocusY()); return true; }
        });
        gd = new GestureDetector(c, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onSingleTapConfirmed(MotionEvent e) {
                if (onMark == null || bmp == null || (edit != null && edit.on)) return false;
                Matrix inv = new Matrix();
                if (!m.invert(inv)) return false;
                float[] p = {e.getX(), e.getY()};
                inv.mapPoints(p);
                int best = -1; float bd = Float.MAX_VALUE, lim = bmp.getWidth() * 0.012f;
                for (int i = 0; i < markIds.length; i++) {
                    float d = (float) Math.hypot(markXY[2 * i] - p[0], markXY[2 * i + 1] - p[1]);
                    if (d < lim && d < bd) { bd = d; best = markIds[i]; }
                }
                if (best < 0 && onHole != null) {
                    int bh = -1; float bdh = Float.MAX_VALUE, limh = bmp.getWidth() * 0.012f;
                    for (int i = 0; i < holeXY.length / 2; i++) {
                        float d = (float) Math.hypot(holeXY[2 * i] - p[0], holeXY[2 * i + 1] - p[1]);
                        if (d < limh && d < bdh) { bdh = d; bh = i; }
                    }
                    if (bh >= 0) { onHole.tapped(bh); return true; }
                }
                if (best < 0) return false;
                onMark.tapped(best);
                return true;
            }
            @Override public boolean onDoubleTap(MotionEvent e) {
                if (curScale() > fit * 1.5f) fitToView(); else zoom(3f, e.getX(), e.getY());
                return true;
            }
        });
    }

    public void setBitmap(Bitmap b) { bmp = b; fitToView(); }

    public void setMarks(float[] xy, int[] ids, OnMark l) { markXY = xy; markIds = ids; onMark = l; lit.clear(); invalidate(); }

    public void setHoles(float[] xy, OnMark l) { holeXY = xy; onHole = l; litHoles.clear(); invalidate(); }

    private float[] secLines = new float[0];  // segmentos de la sección del visor, en fracción de hoja
    private final Paint secPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    public void setSecLines(float[] l) { secLines = l; invalidate(); }
    public void setLitHoles(java.util.Set<Integer> ids) { litHoles.clear(); litHoles.addAll(ids); invalidate(); }

    public void setLit(java.util.Set<Integer> ids) { lit.clear(); lit.addAll(ids); invalidate(); }

    private float curScale() { float[] v = new float[9]; m.getValues(v); return v[Matrix.MSCALE_X]; }

    private int topInset;
    /** Margen superior reservado (barra de edición) para que la hoja no quede debajo. */
    public void setTopInset(int px) { if (px != topInset) { topInset = px; fitToView(); } }

    private void fitToView() {
        if (bmp == null || getWidth() == 0) return;
        float pad = Ui.dp(getContext(), 20);
        float hh = getHeight() - topInset - Ui.dp(getContext(), 14);   // hueco inferior para el texto de ayuda
        fit = Math.min((getWidth() - 2 * pad) / bmp.getWidth(), (hh - 2 * pad) / bmp.getHeight());
        m.reset();
        m.postScale(fit, fit);
        m.postTranslate((getWidth() - bmp.getWidth() * fit) / 2, topInset + (hh - bmp.getHeight() * fit) / 2);
        invalidate();
    }

    private void zoom(float f, float cx, float cy) {
        float s = curScale(), n = Math.max(fit * 0.7f, Math.min(fit * 14, s * f));
        m.postScale(n / s, n / s, cx, cy);
        invalidate();
    }

    @Override protected void onSizeChanged(int w, int h, int ow, int oh) { fitToView(); }

    @Override protected void onDraw(Canvas c) {
        if (bmp == null) return;
        RectF r = new RectF(0, 0, bmp.getWidth(), bmp.getHeight());
        m.mapRect(r);
        float o = Ui.dp(getContext(), 4);
        c.drawRect(r.left + o, r.top + o, r.right + o, r.bottom + o, shadow);
        c.drawBitmap(bmp, m, paint);
        float sc = curScale();
        ring.setStrokeWidth(Ui.dp(getContext(), 3));
        for (int i = 0; i < markIds.length; i++) if (lit.contains(markIds[i])) {
            float[] p = {markXY[2 * i], markXY[2 * i + 1]};
            m.mapPoints(p);
            c.drawCircle(p[0], p[1], bmp.getWidth() * 0.0075f * sc + Ui.dp(getContext(), 3), ring);
        }
        secPaint.setStyle(Paint.Style.STROKE);
        secPaint.setColor(0xFF1E88E5);
        secPaint.setStrokeWidth(Ui.dp(getContext(), 2));
        secPaint.setPathEffect(new android.graphics.DashPathEffect(new float[]{Ui.dp(getContext(), 10), Ui.dp(getContext(), 5)}, 0));
        for (int i = 0; i + 3 < secLines.length; i += 4) {
            float[] p = {secLines[i] * bmp.getWidth(), secLines[i + 1] * bmp.getHeight(), secLines[i + 2] * bmp.getWidth(), secLines[i + 3] * bmp.getHeight()};
            m.mapPoints(p);
            c.drawLine(p[0], p[1], p[2], p[3], secPaint);
        }
        if (edit != null) edit.draw(c, m, bmp.getWidth(), bmp.getHeight(), Ui.dp(getContext(), 1));
        hring.setStrokeWidth(Ui.dp(getContext(), 3));
        for (int i : litHoles) if (2 * i + 1 < holeXY.length) {
            float[] p = {holeXY[2 * i], holeXY[2 * i + 1]};
            m.mapPoints(p);
            c.drawCircle(p[0], p[1], bmp.getWidth() * 0.006f * sc + Ui.dp(getContext(), 5), hring);
        }
    }

    @Override public boolean onTouchEvent(MotionEvent e) {
        if (edit != null && edit.on && bmp != null) {
            int a = e.getActionMasked();
            if (a == MotionEvent.ACTION_DOWN) { float[] f = frac(e.getX(), e.getY()); editing = edit.down(f[0], f[1], curScale() * bmp.getWidth(), e.getX(), e.getY()); }
            else if (editing && a == MotionEvent.ACTION_POINTER_DOWN) { edit.cancel(); editing = false; }
            if (editing) {
                float[] f = frac(e.getX(), e.getY());
                if (a == MotionEvent.ACTION_MOVE) edit.move(f[0], f[1], e.getX(), e.getY());
                else if (a == MotionEvent.ACTION_UP) { edit.up(f[0], f[1]); editing = false; }
                else if (a == MotionEvent.ACTION_CANCEL) { edit.cancel(); editing = false; }
                invalidate();
                getParent().requestDisallowInterceptTouchEvent(true);
                return true;
            }
        }
        sg.onTouchEvent(e);
        gd.onTouchEvent(e);
        if (!sg.isInProgress()) {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN: lx = e.getX(); ly = e.getY(); lastPtr = e.getPointerCount(); break;
                case MotionEvent.ACTION_MOVE:
                    if (e.getPointerCount() == lastPtr) { m.postTranslate(e.getX() - lx, e.getY() - ly); invalidate(); }
                    lx = e.getX(); ly = e.getY(); lastPtr = e.getPointerCount(); break;
                case MotionEvent.ACTION_POINTER_UP: case MotionEvent.ACTION_POINTER_DOWN:
                    lx = e.getX(); ly = e.getY(); lastPtr = -1; break;
            }
        } else { lx = e.getX(); ly = e.getY(); lastPtr = -1; }
        getParent().requestDisallowInterceptTouchEvent(true);
        return true;
    }
}
