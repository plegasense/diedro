// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#pragma once
#include <BRep_Tool.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_SweptSurface.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
namespace diedro {
// Polos de curvas y superficies B-spline de la forma: mide lo que de verdad frena a HLR, booleanas y clasificador de puntos (muelles, mallas, roscas libres).
inline long splinePoles(const TopoDS_Shape& sh) {
    long n = 0;
    for (TopExp_Explorer fe(sh, TopAbs_FACE); fe.More(); fe.Next()) {
        Handle(Geom_Surface) su = BRep_Tool::Surface(TopoDS::Face(fe.Current()));
        if (su.IsNull()) continue;
        if (Handle(Geom_BSplineSurface) bs = Handle(Geom_BSplineSurface)::DownCast(su)) n += (long)bs->NbUPoles() * bs->NbVPoles();
        else if (Handle(Geom_SweptSurface) sw = Handle(Geom_SweptSurface)::DownCast(su)) {
            Handle(Geom_Curve) c = sw->BasisCurve();
            while (Handle(Geom_TrimmedCurve) tc = Handle(Geom_TrimmedCurve)::DownCast(c)) c = tc->BasisCurve();
            if (Handle(Geom_BSplineCurve) bc = Handle(Geom_BSplineCurve)::DownCast(c)) n += bc->NbPoles();
        }
    }
    for (TopExp_Explorer ee(sh, TopAbs_EDGE); ee.More(); ee.Next()) {
        double a, b;
        Handle(Geom_Curve) c = BRep_Tool::Curve(TopoDS::Edge(ee.Current()), a, b);
        while (!c.IsNull() && !Handle(Geom_TrimmedCurve)::DownCast(c).IsNull()) c = Handle(Geom_TrimmedCurve)::DownCast(c)->BasisCurve();
        if (Handle(Geom_BSplineCurve) bc = Handle(Geom_BSplineCurve)::DownCast(c)) n += bc->NbPoles();
    }
    return n;
}
}  // namespace diedro
