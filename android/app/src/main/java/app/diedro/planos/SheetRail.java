package app.diedro.planos;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.os.ParcelFileDescriptor;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.function.IntConsumer;

/** Tira lateral con una miniatura por hoja del PDF (conjunto, corte y una por pieza). */
class SheetRail extends ScrollView {
    private final Context c;
    private final LinearLayout col;
    private final ArrayList<String[]> items = new ArrayList<>();   // {kind, label}
    private final ArrayList<View> cards = new ArrayList<>();
    private final ArrayList<ImageView> thumbs = new ArrayList<>();
    private final boolean[] chk = new boolean[256];
    private boolean choose;
    private int cur;
    private IntConsumer onPick = k -> {};
    private Runnable onCheck = () -> {};

    SheetRail(Context ctx) {
        super(ctx);
        c = ctx;
        setVerticalScrollBarEnabled(false);
        col = new LinearLayout(ctx);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(Ui.dp(c, 6), Ui.dp(c, 4), Ui.dp(c, 6), Ui.dp(c, 8));
        addView(col);
    }

    void onPick(IntConsumer f) { onPick = f; }
    void onCheck(Runnable f) { onCheck = f; }
    int count() { return items.size(); }
    String label(int i) { return items.get(i)[1]; }
    boolean choosing() { return choose; }

    /** Indices elegidos, separados por comas (todos si no se está eligiendo). */
    String selection() {
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < items.size(); i++) if (!choose || chk[i]) s.append(s.length() > 0 ? "," : "").append(i);
        return s.toString();
    }
    int selected() { return selection().isEmpty() ? 0 : selection().split(",").length; }

    void setChoose(boolean on) {
        choose = on;
        java.util.Arrays.fill(chk, false);
        redraw();
    }

    /** Lee las líneas HOJA\t<i>\t<tipo>\t<etiqueta> del resultado de Native.generate. */
    void setItems(String r) {
        items.clear();
        for (String l : r.split("\n")) {
            String[] q = l.split("\t", -1);
            if (q.length >= 4 && q[0].equals("HOJA")) items.add(new String[]{q[2], q[3]});
        }
        cur = 0;
        choose = false;
        java.util.Arrays.fill(chk, false);
        build();
    }

    void select(int k) { cur = k; redraw(); }

    private String kindName(String k) {
        switch (k) {
            case "asm": return I18n.tr("Conjunto");
            case "cut": return I18n.tr("Corte A-A");
            case "turn": return I18n.tr("Torneada");
            case "inspect": return I18n.tr("Inspección");
            default: return I18n.tr("Prismática");
        }
    }
    private int kindColor(String k) {
        switch (k) {
            case "asm": return Ui.TEAL;
            case "cut": return Ui.AMBER;
            case "turn": return 0xFF7FB2FF;
            default: return 0xFFB79CFF;
        }
    }

    private void build() {
        col.removeAllViews(); cards.clear(); thumbs.clear();
        for (int i = 0; i < items.size(); i++) {
            final int k = i;
            LinearLayout card = new LinearLayout(c);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setPadding(Ui.dp(c, 5), Ui.dp(c, 5), Ui.dp(c, 5), Ui.dp(c, 6));
            ImageView im = new ImageView(c);
            im.setScaleType(ImageView.ScaleType.FIT_CENTER);
            im.setBackgroundColor(Color.WHITE);
            card.addView(im, new LinearLayout.LayoutParams(-1, Ui.dp(c, 64)));
            TextView nm = Ui.text(c, items.get(i)[1], 11, Ui.TEXT, true);
            nm.setSingleLine(); nm.setEllipsize(android.text.TextUtils.TruncateAt.END); nm.setGravity(Gravity.CENTER);
            nm.setPadding(0, Ui.dp(c, 4), 0, 0);
            card.addView(nm, new LinearLayout.LayoutParams(-1, -2));
            TextView ch = Ui.text(c, kindName(items.get(i)[0]), 9, kindColor(items.get(i)[0]), true);
            ch.setSingleLine(); ch.setGravity(Gravity.CENTER);
            card.addView(ch, new LinearLayout.LayoutParams(-1, -2));
            Ui.press(card);
            card.setOnClickListener(v -> {
                if (choose) { chk[k] = !chk[k]; redraw(); onCheck.run(); }
                else { cur = k; redraw(); onPick.accept(k); }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = Ui.dp(c, 6);
            col.addView(card, lp);
            cards.add(card); thumbs.add(im);
        }
        redraw();
    }

    private void redraw() {
        for (int i = 0; i < cards.size(); i++) {
            boolean on = choose ? chk[i] : i == cur;
            cards.get(i).setBackground(on ? Ui.outline(c, Ui.SURFACE2, Ui.TEAL, 12) : Ui.rr(c, Ui.SURFACE, 12));
            View nm = ((LinearLayout) cards.get(i)).getChildAt(1);
            ((TextView) nm).setText((choose ? (chk[i] ? "✓ " : "○ ") : "") + items.get(i)[1]);
        }
    }

    /** Miniaturas en segundo plano a partir del PDF ya generado. */
    void loadThumbs(File pdf) {
        new Thread(() -> {
            try (ParcelFileDescriptor fd = ParcelFileDescriptor.open(pdf, ParcelFileDescriptor.MODE_READ_ONLY); PdfRenderer r = new PdfRenderer(fd)) {
                for (int i = 0; i < Math.min(r.getPageCount(), thumbs.size()); i++) {
                    Bitmap b;
                    try (PdfRenderer.Page pg = r.openPage(i)) {
                        int w = 260, h = Math.max(1, (int) ((long) w * pg.getHeight() / pg.getWidth()));
                        b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                        b.eraseColor(Color.WHITE);
                        pg.render(b, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                    }
                    final int k = i; final Bitmap fb = b;
                    post(() -> { if (k < thumbs.size()) thumbs.get(k).setImageBitmap(fb); });
                }
            } catch (Exception ignored) {}
        }).start();
    }
}
