import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../model/brep.dart';
import '../model/lines.dart';
import '../model/material.dart';
import '../model/mesh.dart';
import '../model/scene.dart';
import 'camera.dart';
import '../l10n/l10n.dart';

const _kBundle = 'build/shaderbundles/datum.shaderbundle';

enum ViewMode { shaded, wireframe }

/// Caras o arista de una instancia que se dibujan resaltadas.
class Highlight {
  Highlight(this.node, {this.faces = const [], this.edge});
  final SceneNode node;
  final List<int> faces;
  final int? edge;
}

/// Líneas sueltas en coordenadas del mundo (anotaciones del archivo).
class LineBuf {
  LineBuf(this.vertices, this.color);

  /// 6 floats por vértice (x y z + normal ficticia), dos vértices por segmento.
  final Float32List vertices;
  final Color color;
  Object? gpu;
}

/// Opciones de revisión de un modelo 3D.
class RenderOptions {
  List<Highlight> highlights = const [];
  List<LineBuf> pmiLines = const [];

  /// Mientras el usuario mueve la cámara, los conjuntos grandes se dibujan sin aristas.
  bool interacting = false;

  /// Dibuja las aristas vivas (solo geometría exacta).
  bool edges = true;

  /// Plano de sección (nx, ny, nz, d): se ve lo que cumple n·x <= d. null = sin sección.
  vm.Vector4? clip;

  /// Separación de las piezas desde el centro del conjunto (0 = montado).
  double explode = 0;

  /// Atenúa las piezas que no están seleccionadas.
  bool ghostOthers = false;

  /// Tapa el corte de una sección con color liso (solo vale para mallas cerradas).
  bool capClip = true;

  /// Dibuja los materiales sin textura ni color por vértice (para ver solo la forma).
  bool plainMaterials = false;
}

/// Recursos de GPU compartidos y dibujo de una malla con Flutter GPU.
class DatumRenderer {
  DatumRenderer._(this._pipeline, this._linePipeline, this._rich);
  final gpu.RenderPipeline _pipeline;
  final gpu.RenderPipeline _linePipeline;

  /// Malla con UV, color por vértice, textura y transparencia.
  final gpu.RenderPipeline _rich;

  /// Otro renderizador con sus propios destinos de dibujo (comparte los programas de sombreado).
  DatumRenderer clone() => DatumRenderer._(_pipeline, _linePipeline, _rich);

  static DatumRenderer? _instance;
  static Future<DatumRenderer> instance() async {
    if (_instance != null) return _instance!;
    final lib = await gpu.ShaderLibrary.fromAsset(_kBundle);
    if (lib == null) throw Exception(tr('No se pudo cargar {b}', {'b': _kBundle}));
    final ctx = gpu.gpuContext;
    _instance = DatumRenderer._(
      ctx.createRenderPipeline(lib['MeshVertex']!, lib['MeshFragment']!),
      ctx.createRenderPipeline(lib['LineVertex']!, lib['MeshFragment']!),
      ctx.createRenderPipeline(lib['RichVertex']!, lib['RichFragment']!),
    );
    return _instance!;
  }

  static gpu.Texture? _whiteTex;
  static gpu.Texture _white() {
    var t = _whiteTex;
    if (t == null) {
      t = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        1,
        1,
        enableRenderTargetUsage: false,
      );
      t.overwrite(ByteData.sublistView(Uint8List.fromList([255, 255, 255, 255])));
      _whiteTex = t;
    }
    return t;
  }

  static gpu.Texture? _flatTex;
  static gpu.Texture _flatNormal() {
    var t = _flatTex;
    if (t == null) {
      t = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        1,
        1,
        enableRenderTargetUsage: false,
      );
      t.overwrite(ByteData.sublistView(Uint8List.fromList([128, 128, 255, 255])));
      _flatTex = t;
    }
    return t;
  }

  /// Textura de GPU de una imagen ya decodificada (con mips si el dispositivo los admite).
  static gpu.Texture? textureOf(SceneTexture t) {
    final cached = t.gpu;
    if (cached is gpu.Texture) return cached;
    final mips = t.mips;
    if (mips == null || mips.isEmpty || t.width < 1 || t.height < 1) return null;
    final ctx = gpu.gpuContext;
    final useMips = mips.length > 1 && ctx.doesSupportManuallyMippedTextures;
    final levels = useMips
        ? math.min(mips.length, gpu.Texture.fullMipCount(t.width, t.height))
        : 1;
    final tex = ctx.createTexture(
      gpu.StorageMode.hostVisible,
      t.width,
      t.height,
      enableRenderTargetUsage: false,
      mipLevelCount: levels,
    );
    for (var i = 0; i < levels; i++) {
      tex.overwrite(ByteData.sublistView(mips[i]), mipLevel: i);
    }
    t.gpu = tex;
    return tex;
  }

  gpu.Texture? _msaa;
  gpu.Texture? _depth;
  gpu.Texture? _resolve;
  gpu.Texture? _resolveAlt; // segunda salida (pasada de profundidad del sombreado de borde)
  int _w = 0, _h = 0;
  gpu.Texture? get msaaTexture => _msaa;
  gpu.Texture? get depthTexture => _depth;
  gpu.Texture? get resolveTexture => _resolve;
  gpu.RenderPipeline get linePipeline => _linePipeline;
  void ensureTargets(int w, int h) => _ensureTargets(w, h);

  void _ensureTargets(int w, int h) {
    if (_w == w && _h == h && _resolve != null) return;
    final ctx = gpu.gpuContext;
    _msaa = ctx.createTexture(
      gpu.StorageMode.deviceTransient,
      w,
      h,
      sampleCount: 4,
      enableShaderReadUsage: false,
    );
    _depth = ctx.createTexture(
      gpu.StorageMode.deviceTransient,
      w,
      h,
      format: ctx.defaultDepthStencilFormat,
      sampleCount: 4,
      enableShaderReadUsage: false,
    );
    _resolve = ctx.createTexture(gpu.StorageMode.devicePrivate, w, h);
    _resolveAlt = ctx.createTexture(gpu.StorageMode.devicePrivate, w, h);
    _w = w;
    _h = h;
  }

  /// Dibuja la escena y devuelve la imagen resultante.
  ui.Image render(
    Scene scene,
    OrbitCamera cam,
    int w,
    int h,
    ViewMode mode,
    Set<SceneNode> selected, {
    Color defaultColor = const Color(0xFFB7CACD),
    Color highlight = const Color(0xFFFB923C),
    RenderOptions? options,
  }) {
    final opt = options ?? RenderOptions();
    _ensureTargets(w, h);
    final ctx = gpu.gpuContext;
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: _msaa!,
        resolveTexture: _resolve,
        clearValue: vm.Vector4(0.039, 0.071, 0.078, 1),
        storeAction: gpu.StoreAction.multisampleResolve,
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: _depth!,
        depthClearValue: 1.0,
      ),
    );
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(target);
    pass.setCullMode(gpu.CullMode.none);

    final viewProj = cam.projection(w / h) * cam.viewMatrix();
    final lightWorld = cam.lightDir();
    final host = ctx.createHostBuffer();
    final slot = _pipeline.vertexShader.getUniformSlot('FrameInfo');
    final lineSlot = _linePipeline.vertexShader.getUniformSlot('FrameInfo');
    final hasSel = selected.isNotEmpty;
    final clip = opt.clip ?? vm.Vector4(0, 0, 0, 1);
    // Una pieza sin triángulos (p. ej. solo geometría auxiliar) no se puede subir a la GPU.
    final all = [
      for (final i in scene.instances(explode: opt.explode))
        if (i.part.mesh.vertexCount > 0) i,
    ];
    final instances = all.length < 40
        ? all
        : _cull(all, viewProj, cam.viewMatrix(), w, h);
    final ghost = <Instance>[];
    // Si alguna pieza lleva textura o color por vértice, todas van por el mismo pipeline.
    final anyRich = scene.parts.any((p) => p.mesh.extra != null || p.material != null);
    bool isRich(Instance i) =>
        anyRich || i.part.mesh.extra != null || i.part.material != null;
    final richSlot = _rich.vertexShader.getUniformSlot('FrameInfo');
    final fragSlot = _rich.fragmentShader.getUniformSlot('FragInfo');
    final texSlot = _rich.fragmentShader.getUniformSlot('base_tex');
    final mrSlot = _rich.fragmentShader.getUniformSlot('mr_tex');
    final nrmSlot = _rich.fragmentShader.getUniformSlot('normal_tex');
    final occSlot = _rich.fragmentShader.getUniformSlot('occ_tex');
    final emSlot = _rich.fragmentShader.getUniformSlot('emis_tex');
    final eyeWorld = cam.eye;

    bool isSel(Instance i) => selected.contains(i.node);

    // Pieza con textura, color por vértice o transparencia (pipeline propio).
    void drawRich(
      Instance inst,
      double alpha, {
      Color? color,
      bool flat = false,
    }) {
      final part = inst.part;
      final mat = part.material;
      final gm = (part.gpu ??= GpuMesh.upload(part.mesh, rich: true)) as GpuMesh;
      final mvp = viewProj * inst.world;
      final rot = inst.world.getRotation()..transpose();
      final l = rot * lightWorld;
      final sel = isSel(inst);
      final plain = color != null || sel || opt.plainMaterials;
      Color base;
      if (color != null) {
        base = color;
      } else if (sel) {
        base = highlight;
      } else if (mat != null) {
        base = opt.plainMaterials && mat.texture != null
            ? defaultColor
            : Color(mat.baseColor);
      } else if (part.color != null) {
        base = _readable(Color(part.color!));
      } else {
        base = part.mesh.extra != null && !opt.plainMaterials
            ? const Color(0xFFFFFFFF)
            : defaultColor;
      }
      final dim = hasSel && !sel && !opt.ghostOthers ? 0.55 : 1.0;
      final mode = mat?.alphaMode ?? AlphaMode.opaque;
      final em = (plain || mat == null) ? const Color(0x00000000) : Color(mat.emissive);
      gpu.Texture? tex;
      if (!plain && mat?.texture != null && mat!.texture! < scene.textures.length) {
        tex = DatumRenderer.textureOf(scene.textures[mat.texture!]);
      }
      final uvt = !plain && mat != null && mat.hasUvTransform
          ? [mat.uvOx, mat.uvOy, mat.uvSx, mat.uvSy]
          : const [0.0, 0.0, 1.0, 1.0];
      final rotA = !plain && mat != null ? mat.uvRot : 0.0;
      final invW = vm.Matrix4.copy(inst.world)..invert();
      final eyeM = invW.transformed3(eyeWorld.clone());
      final upM = (rot * vm.Vector3(0, 0, 1))..normalize();
      final isPbr = !plain && (mat?.pbr ?? false);
      gpu.Texture? texOf(int? i) => (!plain && i != null && i < scene.textures.length)
          ? DatumRenderer.textureOf(scene.textures[i])
          : null;
      final nrmT = isPbr ? texOf(mat!.normalTexture) : null;
      final flags = [
        (flat || (!plain && (mat?.unlit ?? false))) ? 1.0 : 0.0,
        (!plain && part.mesh.extra != null) ? 1.0 : 0.0,
        mode == AlphaMode.mask ? (mat?.alphaCutoff ?? 0.5) : -1.0,
        mode == AlphaMode.opaque && alpha >= 1 ? 1.0 : 0.0,
      ];
      final u = Float32List(60)
        ..setAll(0, mvp.storage)
        ..setAll(16, [l.x, l.y, l.z, 0])
        ..setAll(20, [base.r * dim, base.g * dim, base.b * dim, base.a * alpha])
        ..setAll(24, inst.world.storage)
        ..setAll(40, [clip.x, clip.y, clip.z, clip.w])
        ..setAll(44, flags)
        ..setAll(48, uvt)
        ..setAll(52, [math.sin(rotA), math.cos(rotA), 0, 0]);
      final fu = Float32List(28)
        ..setAll(0, [base.r * dim, base.g * dim, base.b * dim, base.a * alpha])
        ..setAll(4, flags)
        ..setAll(8, [em.r, em.g, em.b, 0])
        ..setAll(12, [eyeM.x, eyeM.y, eyeM.z, 0])
        ..setAll(16, [upM.x, upM.y, upM.z, isPbr ? 1 : 0])
        ..setAll(20, [l.x, l.y, l.z, 0])
        ..setAll(24, [
          mat?.metallic ?? 0,
          mat?.roughness ?? 1,
          nrmT != null ? (mat!.normalScale) : 0,
          mat?.occlusionStrength ?? 1,
        ]);
      pass.setPrimitiveType(gpu.PrimitiveType.triangle);
      pass.bindUniform(richSlot, host.emplace(ByteData.sublistView(u)));
      pass.bindUniform(fragSlot, host.emplace(ByteData.sublistView(fu)));
      final smp = gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.linear,
        magFilter: gpu.MinMagFilter.linear,
        mipFilter: gpu.MipFilter.linear,
        widthAddressMode: _wrap(plain ? 0 : (mat?.wrapS ?? 0)),
        heightAddressMode: _wrap(plain ? 0 : (mat?.wrapT ?? 0)),
      );
      pass.bindTexture(texSlot, tex ?? DatumRenderer._white(), sampler: smp);
      pass.bindTexture(mrSlot, (isPbr ? texOf(mat!.mrTexture) : null) ?? DatumRenderer._white(), sampler: smp);
      pass.bindTexture(nrmSlot, nrmT ?? DatumRenderer._flatNormal(), sampler: smp);
      pass.bindTexture(occSlot, (isPbr ? texOf(mat!.occlusionTexture) : null) ?? DatumRenderer._white(), sampler: smp);
      pass.bindTexture(emSlot, (isPbr ? texOf(mat!.emissiveTexture) : null) ?? DatumRenderer._white(), sampler: smp);
      gm.draw(pass);
    }

    void drawMesh(
      Instance inst,
      double alpha, {
      Color? color,
      int firstTri = 0,
      int triCount = -1,
      bool flat = false,
    }) {
      final gm = (inst.part.gpu ??= GpuMesh.upload(inst.part.mesh)) as GpuMesh;
      final mvp = viewProj * inst.world;
      final rot = inst.world.getRotation()..transpose();
      final l = rot * lightWorld;
      final sel = isSel(inst);
      final base =
          color ??
          (sel
              ? highlight
              : (inst.part.color != null
                    ? _readable(Color(inst.part.color!))
                    : defaultColor));
      final dim = hasSel && !sel && !opt.ghostOthers ? 0.55 : 1.0;
      final u = Float32List(48)
        ..setAll(0, mvp.storage)
        ..setAll(16, [l.x, l.y, l.z, 0])
        ..setAll(20, [base.r * dim, base.g * dim, base.b * dim, alpha])
        ..setAll(24, inst.world.storage)
        ..setAll(40, [clip.x, clip.y, clip.z, clip.w])
        ..setAll(44, [flat ? 1 : 0, 0, 0, 0]);
      pass.setPrimitiveType(gpu.PrimitiveType.triangle);
      pass.bindUniform(slot, host.emplace(ByteData.sublistView(u)));
      if (gm.ibuf != null) {
        gm.draw(pass, firstTri: firstTri, triCount: triCount);
        return;
      }
      const vstride = Mesh.floatsPerVertex * 4;
      final count = triCount < 0 ? gm.vertexCount : triCount * 3;
      pass.bindVertexBuffer(
        gpu.BufferView(
          gm.vbuf,
          offsetInBytes: firstTri * 3 * vstride,
          lengthInBytes: count * vstride,
        ),
      );
      pass.draw(count);
    }

    // 1) Piezas opacas.
    pass.bindPipeline(_pipeline);
    pass.setDepthWriteEnable(true);
    pass.setDepthCompareOperation(gpu.CompareFunction.less);
    pass.setPolygonMode(
      mode == ViewMode.wireframe ? gpu.PolygonMode.line : gpu.PolygonMode.fill,
    );
    final rich = <Instance>[];
    for (final inst in instances) {
      if (isRich(inst)) {
        rich.add(inst);
      } else if (opt.ghostOthers && hasSel && !isSel(inst)) {
        ghost.add(inst);
      } else {
        drawMesh(inst, 1);
      }
    }

    // 1a) Piezas con textura o color por vértice: primero las opacas, luego las
    // translúcidas de atrás adelante y sin escribir profundidad.
    if (rich.isNotEmpty) {
      final blendList = <Instance>[];
      final ghostRich = <Instance>[];
      pass.bindPipeline(_rich);
      pass.setDepthWriteEnable(true);
      pass.setDepthCompareOperation(gpu.CompareFunction.less);
      pass.setPolygonMode(
        mode == ViewMode.wireframe ? gpu.PolygonMode.line : gpu.PolygonMode.fill,
      );
      pass.setCullMode(gpu.CullMode.none);
      for (final inst in rich) {
        final blend = inst.part.material?.alphaMode == AlphaMode.blend;
        if (opt.ghostOthers && hasSel && !isSel(inst)) {
          ghostRich.add(inst);
        } else if (blend) {
          blendList.add(inst);
        } else {
          drawRich(inst, 1);
        }
      }
      if (opt.clip != null && opt.capClip && mode == ViewMode.shaded) {
        pass.setCullMode(gpu.CullMode.backFace);
        pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
        for (final inst in rich) {
          if (ghostRich.contains(inst) || blendList.contains(inst)) continue;
          drawRich(inst, 1, color: _capColor, flat: true);
        }
        pass.setCullMode(gpu.CullMode.none);
      }
      if (blendList.isNotEmpty || ghostRich.isNotEmpty) {
        double depthOf(Instance i) {
          final c = i.part.mesh.bounds.center;
          final v = vm.Vector4(c[0], c[1], c[2], 1)
            ..applyMatrix4(viewProj * i.world);
          return v.w;
        }

        blendList.sort((a, b) => depthOf(b).compareTo(depthOf(a)));
        pass.setDepthWriteEnable(false);
        pass.setDepthCompareOperation(gpu.CompareFunction.less);
        pass.setColorBlendEnable(true);
        for (final inst in blendList) {
          drawRich(inst, 1);
        }
        for (final inst in ghostRich) {
          drawRich(inst, 0.16);
        }
        pass.setColorBlendEnable(false);
      }
      pass.bindPipeline(_pipeline);
      pass.setDepthWriteEnable(true);
      pass.setDepthCompareOperation(gpu.CompareFunction.less);
      pass.setPolygonMode(gpu.PolygonMode.fill);
    }

    // 1b) Tapa de la sección: las caras traseras que asoman por el corte se pintan planas.
    if (opt.clip != null && opt.capClip && mode == ViewMode.shaded) {
      pass.setCullMode(gpu.CullMode.backFace);
      pass.setDepthWriteEnable(true);
      pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
      for (final inst in instances) {
        if (ghost.contains(inst)) continue;
        drawMesh(inst, 1, color: _capColor, flat: true);
      }
      pass.setCullMode(gpu.CullMode.none);
    }

    // 2) Aristas vivas de las piezas opacas (mismo pipeline, sin iluminación).
    void drawEdges(
      Instance inst,
      PartBrep brep,
      Color color, {
      int first = 0,
      int count = -1,
      double bias = 0.0004,
      List<(double, double)> offsetsIn = const [(0.0, 0.0), (0.8, 0.8)],
    }) {
      final buf =
          (brep.gpuEdges ??= ctx.createDeviceBufferWithCopy(
                ByteData.sublistView(_edgeVertices(brep)),
              ))
              as gpu.DeviceBuffer;
      const vstride = 24;
      final offsets = instances.length > 400 ? const [(0.0, 0.0)] : offsetsIn;
      final n = count < 0 ? brep.edgeSegments.length ~/ 3 : count * 2;
      pass.setPrimitiveType(gpu.PrimitiveType.line);
      pass.bindVertexBuffer(
        gpu.BufferView(
          buf,
          offsetInBytes: first * 2 * vstride,
          lengthInBytes: n * vstride,
        ),
      );
      final mvp = viewProj * inst.world;
      for (final o in offsets) {
        final u = Float32List(48)
          ..setAll(0, mvp.storage)
          ..setAll(16, [0, 0, 1, 0])
          ..setAll(20, [color.r, color.g, color.b, 1])
          ..setAll(24, inst.world.storage)
          ..setAll(40, [clip.x, clip.y, clip.z, clip.w])
          ..setAll(44, [1, bias, o.$1 * 2 / w, o.$2 * 2 / h]);
        pass.bindUniform(slot, host.emplace(ByteData.sublistView(u)));
        pass.draw(n);
      }
    }

    final skipEdges = opt.interacting && instances.length > 200;
    if (opt.edges && mode == ViewMode.shaded && !skipEdges) {
      pass.setDepthWriteEnable(true);
      pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
      pass.setPolygonMode(gpu.PolygonMode.fill);
      for (final inst in instances) {
        final brep = inst.part.brep;
        if (brep == null || brep.edgeSegments.isEmpty) continue;
        if (ghost.contains(inst)) continue;
        drawEdges(inst, brep, _edgeColor(inst.part.color));
      }
    }

    // 2b) Caras y aristas resaltadas (selección y medición).
    if (opt.highlights.isNotEmpty) {
      for (final hl in opt.highlights) {
        Instance? inst;
        for (final i in all) {
          if (i.node == hl.node) inst = i;
        }
        final brep = inst?.part.brep;
        if (inst == null || brep == null) continue;
        if (hl.faces.isNotEmpty) {
          pass.bindPipeline(_pipeline);
          pass.setDepthWriteEnable(false);
          pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
          pass.setPolygonMode(gpu.PolygonMode.fill);
          for (final f in hl.faces) {
            final s0 = brep.faceStart[f], s1 = brep.faceStart[f + 1];
            if (s1 > s0) {
              drawMesh(
                inst,
                1,
                color: highlight,
                firstTri: s0,
                triCount: s1 - s0,
              );
            }
          }
        }
        if (hl.edge != null) {
          final e = hl.edge!;
          final s0 = brep.edgeStart[e], s1 = brep.edgeStart[e + 1];
          if (s1 > s0) {
            pass.bindPipeline(_pipeline);
            pass.setDepthWriteEnable(false);
            pass.setDepthCompareOperation(gpu.CompareFunction.always);
            pass.setPolygonMode(gpu.PolygonMode.fill);
            drawEdges(
              inst,
              brep,
              highlight,
              first: s0,
              count: s1 - s0,
              bias: 0.0006,
              offsetsIn: const [(0.0, 0.0), (1.2, 0.0), (0.0, 1.2), (1.2, 1.2)],
            );
          }
        }
      }
    }

    // 2c) Anotaciones del archivo (cotas, tolerancias), siempre visibles.
    if (opt.pmiLines.isNotEmpty) {
      pass.setDepthWriteEnable(false);
      pass.setDepthCompareOperation(gpu.CompareFunction.always);
      pass.setPolygonMode(gpu.PolygonMode.fill);
      pass.setPrimitiveType(gpu.PrimitiveType.line);
      final ident = vm.Matrix4.identity();
      for (final lb in opt.pmiLines) {
        if (lb.vertices.isEmpty) continue;
        final buf =
            (lb.gpu ??= ctx.createDeviceBufferWithCopy(
                  ByteData.sublistView(lb.vertices),
                ))
                as gpu.DeviceBuffer;
        pass.bindVertexBuffer(
          gpu.BufferView(buf, offsetInBytes: 0, lengthInBytes: buf.sizeInBytes),
        );
        for (final o in const [(0.0, 0.0), (0.9, 0.0), (0.0, 0.9)]) {
          final u = Float32List(48)
            ..setAll(0, viewProj.storage)
            ..setAll(16, [0, 0, 1, 0])
            ..setAll(20, [lb.color.r, lb.color.g, lb.color.b, 1])
            ..setAll(24, ident.storage)
            ..setAll(40, [0, 0, 0, 1])
            ..setAll(44, [1, 0, o.$1 * 2 / w, o.$2 * 2 / h]);
          pass.bindUniform(slot, host.emplace(ByteData.sublistView(u)));
          pass.draw(lb.vertices.length ~/ 6);
        }
      }
    }

    // 3) Piezas atenuadas, con mezcla y sin escribir profundidad.
    if (ghost.isNotEmpty) {
      pass.bindPipeline(_pipeline);
      pass.setDepthWriteEnable(false);
      pass.setDepthCompareOperation(gpu.CompareFunction.less);
      pass.setPolygonMode(gpu.PolygonMode.fill);
      pass.setColorBlendEnable(true);
      for (final inst in ghost) {
        drawMesh(inst, 0.16);
      }
      pass.setColorBlendEnable(false);
    }
    cb.submit();
    return _resolve!.asImage();
  }
}

/// Vértices (x y z + normal ficticia) de las aristas de una pieza.
Float32List _edgeVertices(PartBrep brep) {
  final src = brep.edgeSegments;
  final out = Float32List(src.length * 2);
  for (var i = 0, o = 0; i < src.length; i += 3, o += 6) {
    out[o] = src[i];
    out[o + 1] = src[i + 1];
    out[o + 2] = src[i + 2];
    out[o + 5] = 1;
  }
  return out;
}

/// Descarta las instancias fuera de pantalla o de menos de un píxel.
List<Instance> _cull(
  List<Instance> list,
  vm.Matrix4 viewProj,
  vm.Matrix4 view,
  int w,
  int h,
) {
  final right = vm.Vector3(view.storage[0], view.storage[4], view.storage[8]);
  final out = <Instance>[];
  for (final i in list) {
    final b = i.part.mesh.bounds;
    final c = b.center;
    final r = b.radius;
    final center = vm.Vector3(c[0], c[1], c[2])..applyMatrix4(i.world);
    final vc = vm.Vector4(center.x, center.y, center.z, 1)
      ..applyMatrix4(viewProj);
    final e = center + right * r;
    final ve = vm.Vector4(e.x, e.y, e.z, 1)..applyMatrix4(viewProj);
    if (vc.w <= 1e-6 && ve.w <= 1e-6) continue; // detrás de la cámara
    if (vc.w <= 1e-6 || ve.w <= 1e-6) {
      out.add(i); // cruza el plano de cámara: se deja pasar
      continue;
    }
    final cx = vc.x / vc.w, cy = vc.y / vc.w;
    final rn = math.sqrt(
      math.pow(ve.x / ve.w - cx, 2) + math.pow(ve.y / ve.w - cy, 2),
    );
    if (cx.abs() > 1 + rn || cy.abs() > 1 + rn) continue; // fuera de la vista
    if (rn * w * 0.5 < 0.8) continue; // menos de un píxel
    out.add(i);
  }
  return out;
}

const _capColor = Color(0xFF3E9C93);

/// Color de las aristas: oscuro sobre piezas claras, claro sobre piezas oscuras.
Color _edgeColor(int? partColor) {
  var lum = 0.7;
  if (partColor != null) {
    final c = _readable(Color(partColor));
    lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
  }
  return lum < 0.38 ? const Color(0xFFCFD8DA) : const Color(0xFF12191B);
}

gpu.SamplerAddressMode _wrap(int m) => m == 1
    ? gpu.SamplerAddressMode.clampToEdge
    : (m == 2 ? gpu.SamplerAddressMode.mirror : gpu.SamplerAddressMode.repeat);

/// Aclara los colores de pieza muy oscuros para que se distingan sobre el fondo.
Color _readable(Color c) {
  final lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
  final k = ((0.55 - lum) / 0.55).clamp(0.0, 1.0) * 0.7;
  return Color.from(
    alpha: 1,
    red: c.r + (1 - c.r) * k,
    green: c.g + (1 - c.g) * k,
    blue: c.b + (1 - c.b) * k,
  );
}

/// Un tramo de un LineSet para dibujar con un tinte.
class LineDraw {
  LineDraw(
    this.set,
    this.firstVertex,
    this.vertexCount, {
    this.tint = 1.0,
    this.passes = 1,
    this.points = false,
    this.pointSize = 3.0,
  });
  final LineSet set;
  final int firstVertex;
  final int vertexCount;
  final double tint;

  /// Veces que se dibuja con un desplazamiento de un píxel, para engrosar la línea (1–4).
  final int passes;

  /// Dibuja cada vértice como un punto (nubes de puntos) en lugar de pares como segmentos.
  final bool points;
  final double pointSize;
}

extension LineRendering on DatumRenderer {
  /// Dibuja conjuntos de líneas (dibujos 2D, trayectorias de G-code).
  ui.Image renderLines(
    List<LineDraw> draws,
    OrbitCamera cam,
    int w,
    int h, {
    bool transparent = false,
    bool depthPass = false,
  }) {
    ensureTargets(w, h);
    final ctx = gpu.gpuContext;
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: msaaTexture!,
        resolveTexture: depthPass ? _resolveAlt : resolveTexture,
        clearValue: depthPass
            ? vm.Vector4(1, 0, 0, 1)
            : (transparent ? vm.Vector4(0, 0, 0, 0) : vm.Vector4(0.039, 0.071, 0.078, 1)),
        storeAction: gpu.StoreAction.multisampleResolve,
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depthTexture!,
        depthClearValue: 1.0,
      ),
    );
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(target);
    final pipe = linePipeline;
    pass.bindPipeline(pipe);
    pass.setDepthWriteEnable(true);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setCullMode(gpu.CullMode.none);
    final mvp = cam.projection(w / h) * cam.viewMatrix();
    final host = ctx.createHostBuffer();
    final slot = pipe.vertexShader.getUniformSlot('FrameInfo');
    const stride = LineSet.floatsPerVertex * 4;
    const offsets = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)];
    for (final d in draws) {
      if (d.vertexCount <= 0) continue;
      final buf =
          (d.set.gpu ??= ctx.createDeviceBufferWithCopy(
                ByteData.sublistView(d.set.vertices),
              ))
              as gpu.DeviceBuffer;
      pass.setPrimitiveType(
        d.points ? gpu.PrimitiveType.point : gpu.PrimitiveType.line,
      );
      pass.bindVertexBuffer(
        gpu.BufferView(
          buf,
          offsetInBytes: d.firstVertex * stride,
          lengthInBytes: d.vertexCount * stride,
        ),
      );
      final passes = d.points ? 1 : d.passes.clamp(1, 4);
      for (var k = 0; k < passes; k++) {
        final u = Float32List(44)
          ..setAll(0, mvp.storage)
          ..setAll(16, depthPass ? [0, cam.nearFar.$1, cam.nearFar.$2, -1] : [d.tint, d.tint, d.tint, 1])
          ..setAll(20, [
            offsets[k].$1 * 2 / w,
            offsets[k].$2 * 2 / h,
            d.pointSize,
            0,
          ])
          ..setAll(24, vm.Matrix4.identity().storage)
          ..setAll(40, [0, 0, 0, 1]);
        pass.bindUniform(slot, host.emplace(ByteData.sublistView(u)));
        pass.draw(d.vertexCount);
      }
    }
    cb.submit();
    return (depthPass ? _resolveAlt! : resolveTexture!).asImage();
  }
}

/// Aclara los colores muy oscuros del archivo para que se lean sobre el fondo oscuro.
Color _lifted(Color c) {
  final lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
  final k = ((0.55 - lum) / 0.55).clamp(0.0, 1.0) * 0.6;
  return Color.from(
    alpha: 1,
    red: c.r + (1 - c.r) * k,
    green: c.g + (1 - c.g) * k,
    blue: c.b + (1 - c.b) * k,
  );
}

/// Malla ya subida a la GPU.
class GpuMesh {
  GpuMesh._(
    this.vbuf,
    this.ibuf,
    this.vertexCount,
    this.indexCount,
    this.source,
    this.stride,
    this.wide,
    this.rich,
  );
  final gpu.DeviceBuffer vbuf;
  final gpu.DeviceBuffer? ibuf;
  final int vertexCount;
  final int indexCount;
  final Mesh source;

  /// Bytes por vértice en `vbuf`: 24 (posición + normal) o 48 (con UV y color).
  final int stride;

  /// Índices de 32 bits (si no, de 16).
  final bool wide;

  /// Vértices de 48 bytes (con UV y color) para el pipeline de texturas.
  final bool rich;

  factory GpuMesh.upload(Mesh m, {bool rich = false}) {
    final ctx = gpu.gpuContext;
    final n = m.vertexCount;
    Float32List data = m.vertices;
    var stride = 24;
    final ex = m.extra;
    if (ex != null || rich) {
      // Intercalado: posición, normal, uv, color (12 floats).
      data = _interleave(m);
      stride = 48;
    }
    final vb = ctx.createDeviceBufferWithCopy(ByteData.sublistView(data));
    gpu.DeviceBuffer? ib;
    var wide = true;
    final idx = m.indices;
    if (idx != null) {
      wide = n > 65535;
      ib = ctx.createDeviceBufferWithCopy(
        ByteData.sublistView(wide ? idx : Uint16List.fromList(idx)),
      );
    }
    return GpuMesh._(vb, ib, n, idx?.length ?? 0, m, stride, wide, stride == 48);
  }

  /// Dibuja la malla (o un tramo de triángulos) con el pipeline activo.
  void draw(gpu.RenderPass pass, {int firstTri = 0, int triCount = -1}) {
    if (ibuf == null) {
      final count = triCount < 0 ? vertexCount : triCount * 3;
      pass.bindVertexBuffer(
        gpu.BufferView(
          vbuf,
          offsetInBytes: firstTri * 3 * stride,
          lengthInBytes: count * stride,
        ),
      );
      pass.draw(count);
      return;
    }
    final isz = wide ? 4 : 2;
    final count = triCount < 0 ? indexCount : triCount * 3;
    pass.bindVertexBuffer(
      gpu.BufferView(vbuf, offsetInBytes: 0, lengthInBytes: vertexCount * stride),
    );
    pass.bindIndexBuffer(
      gpu.BufferView(
        ibuf!,
        offsetInBytes: firstTri * 3 * isz,
        lengthInBytes: count * isz,
      ),
      wide ? gpu.IndexType.int32 : gpu.IndexType.int16,
    );
    pass.drawIndexed(count);
  }
}

extension GpuMeshUpdate on GpuMesh {
  /// Vuelve a subir los vértices de la malla (animación por piel o formas de morfo).
  void update() {
    final m = source;
    vbuf.overwrite(ByteData.sublistView(rich ? _interleave(m) : m.vertices));
  }
}

/// Posición, normal, uv y color de cada vértice en un solo arreglo (12 floats por vértice).
Float32List _interleave(Mesh m) {
  final n = m.vertexCount;
  final out = Float32List(n * 12);
  final v = m.vertices, ex = m.extra;
  for (var i = 0; i < n; i++) {
    final a = i * 6, b = i * 12;
    for (var k = 0; k < 6; k++) {
      out[b + k] = v[a + k];
    }
    if (ex != null) {
      for (var k = 0; k < 6; k++) {
        out[b + 6 + k] = ex[a + k];
      }
    } else {
      out[b + 8] = 1;
      out[b + 9] = 1;
      out[b + 10] = 1;
      out[b + 11] = 1;
    }
  }
  return out;
}
