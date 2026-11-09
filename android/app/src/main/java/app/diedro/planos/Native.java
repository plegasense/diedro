// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
package app.diedro.planos;

public final class Native {
    static { System.loadLibrary("diedro_jni"); }
    public static native void setProjection(boolean third);
    public static native void setDfm(boolean on);
    public static native String generate(String step, String pdf, String title, String partNo, String material, String tol, String tols, String lang, boolean imperial, String sheet, boolean explode, boolean inspect);
    /** Re-renderiza el último plano con las ediciones del usuario (órdenes TAB, una por línea); devuelve GRUPO/TEXTO/PUNTOS/AGUJERO/VISTA. */
    /** Avance de generate(): porcentaje*10 + etapa (0 leer, 1 analizar, 2 vistas y cotas, 3 isométrico, 4 globos, 5 escribir). */
    public static native int progress();
    public static native String exportPages(String dir, String name, String ops, String sel, boolean split);
    public static native String render(String pdf, String ops);
}
