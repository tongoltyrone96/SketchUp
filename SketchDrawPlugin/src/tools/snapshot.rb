require 'base64'
require 'fileutils'

module SketchDraw
  # ============================================================================
  # Feature D - High-Quality Vector Snapshot (dual .skp + .svg output)
  # ============================================================================
  # Captures the current selection into two files at once:
  #   * <name>.skp - native SketchUp component, fully editable when reinserted
  #   * <name>.svg - Scalable Vector Graphics, opens in AutoCAD / Illustrator /
  #                  browsers and any other vector-aware software
  #
  # Both files share the same base name so the pair stays together. Textures
  # are embedded in the SVG at their original resolution so quality is
  # preserved at any zoom.
  # ============================================================================
  module Snapshot
    ATTR_NS = SketchDraw::PLUGIN_ID

    # ── Save entry point ────────────────────────────────────────────────
    # v5.84: adds high-resolution PNG export alongside the existing SKP
    # and SVG outputs. Same button, one dialog — three files. D's use
    # case (import back into SketchUp as a reference image) needs a
    # raster PNG since SketchUp's Image object type only accepts raster
    # formats; PNG is exported at 12,000 px on the longest side so it
    # stays sharp under normal viewing and even fairly deep zoom.
    def self.save
      return unless SketchDraw.version_ok?
      model = Sketchup.active_model
      sel   = model.selection.to_a
      if sel.empty?
        UI.messagebox('Select the geometry you want to snapshot first, then click Snap+.')
        return
      end

      # Ask user for path (without extension). The chooser filter is set to
      # .skp because we will save the same base name as .skp / .svg / .png.
      path = UI.savepanel('Save Snapshot', '', 'SketchDraw Snapshot|*.skp||')
      return unless path
      # Strip any of the extensions if the user typed one
      base = path.sub(/\.(skp|svg|png)$/i, '')
      skp_path = base + '.skp'
      svg_path = base + '.svg'
      png_path = base + '.png'

      begin
        save_skp(sel, skp_path)
      rescue => e
        UI.messagebox("SKP save failed: #{e.class}: #{e.message}")
        return
      end

      begin
        save_svg(sel, svg_path)
      rescue => e
        UI.messagebox("SVG save failed (SKP was saved successfully): #{e.class}: #{e.message}")
        return
      end

      begin
        save_png(sel, png_path)
      rescue => e
        # PNG failure is non-fatal — SKP and SVG are already saved.
        UI.messagebox("PNG save failed (SKP + SVG were saved successfully):\n#{e.class}: #{e.message}")
      end

      UI.messagebox(
        "Snapshot saved as:\n\n" \
        "  #{File.basename(skp_path)} (SketchUp component — vector, editable)\n" \
        "  #{File.basename(svg_path)} (SVG — for AutoCAD / Illustrator)\n" \
        "  #{File.basename(png_path)} (high-res PNG image — for File → Import → 2D Image)\n\n" \
        "Folder:\n  #{File.dirname(skp_path)}"
      )
    end

    # ── Load entry point ────────────────────────────────────────────────
    def self.load
      return unless SketchDraw.version_ok?
      path = UI.openpanel('Load Snapshot', '', 'SketchDraw Snapshot|*.skp||')
      return unless path
      unless File.exist?(path)
        UI.messagebox("File not found:\n#{path}")
        return
      end
      model = Sketchup.active_model
      defn  = model.definitions.load(path)
      model.select_tool(LoadTool.new(defn))
    end

    # ================================================================
    # SKP save (wrap selection in a group, save its definition to disk)
    # ================================================================
    def self.save_skp(sel, path)
      model = Sketchup.active_model
      model.start_operation('Save Snapshot SKP', true)
      grp = model.active_entities.add_group(sel)
      grp.name = File.basename(path, '.skp')
      grp.definition.save_as(path)
      model.abort_operation   # keep the user's drawing unchanged
    end

    # ================================================================
    # PNG save (v5.85) — high-resolution raster snapshot of ONLY the
    # selected geometry (not the whole viewport). Isolates the selection
    # by temporarily hiding every other top-level entity, zooms extents
    # so the selection fills the viewport, writes the image, then uses
    # abort_operation to cleanly restore the hidden state (no undo
    # history pollution). The user's camera is preserved as well.
    # ================================================================
    def self.save_png(sel, path)
      model = Sketchup.active_model
      view  = model.active_view
      ropt  = model.rendering_options
      cam_saved = view.camera

      # Save the rendering options we'll temporarily boost so we can put
      # them back to whatever the user had set. RenderingOptions changes
      # are tracked in the undo history, so abort_operation would revert
      # them too — but we ALSO save-and-restore manually as belt-and-
      # braces in case a SketchUp version handles them outside undo.
      ew_saved       = ropt['EdgeWidth']         rescue nil
      shadow_saved   = ropt['DisplayShadows']    rescue nil
      fog_saved      = ropt['DrawFog']           rescue nil
      xray_saved     = ropt['ModelTransparency'] rescue nil
      sil_saved      = ropt['DrawSilhouettes']   rescue nil
      silw_saved     = ropt['SilhouetteWidth']   rescue nil
      jit_saved      = ropt['JitterEdges']       rescue nil
      ext_saved      = ropt['ExtendEdges']       rescue nil
      endp_saved     = ropt['EdgesEndpoints']    rescue nil
      profedges_saved= ropt['DrawEdges']         rescue nil

      # Fast lookup of "this entity is part of the selection"
      sel_ids = {}
      sel.each { |e| sel_ids[e.entityID] = true }

      Sketchup.set_status_text('Rendering high-resolution PNG snapshot…')

      # Wrap the whole isolation in start_operation so abort_operation
      # cleanly reverts every visibility flip. Nothing survives into
      # the user's undo history.
      model.start_operation('SketchDraw: PNG isolation', true)
      begin
        # Hide every sibling of the selection in the current editing
        # context (`active_entities` handles both root and group-edit
        # cases correctly — the selection is always inside active_entities).
        model.active_entities.each do |ent|
          next if sel_ids[ent.entityID]
          next unless ent.respond_to?(:hidden=)
          ent.hidden = true unless ent.hidden?
        end

        # v5.91: max boldness at native SU texture resolution.
        # Combined tweaks for maximum edge clarity on import:
        #   • EdgeWidth 60         — very heavy lines
        #   • SilhouetteWidth 8    — extra-strong outer contours
        #   • JitterEdges off      — no hand-drawn wobble (crisp lines)
        #   • ExtendEdges off      — clean endpoints, no overshoot
        #   • DrawEdges on         — ensure edges render at all
        #   • Shadows/fog/x-ray off — nothing dims the colours
        begin
          ropt['EdgeWidth']         = 60   if ropt.key?('EdgeWidth')
          ropt['DrawSilhouettes']   = true if ropt.key?('DrawSilhouettes')
          ropt['SilhouetteWidth']   = 8    if ropt.key?('SilhouetteWidth')
          ropt['JitterEdges']       = false if ropt.key?('JitterEdges')
          ropt['ExtendEdges']       = false if ropt.key?('ExtendEdges')
          ropt['EdgesEndpoints']    = false if ropt.key?('EdgesEndpoints')
          ropt['DrawEdges']         = true if ropt.key?('DrawEdges')
          ropt['DisplayShadows']    = false if ropt.key?('DisplayShadows')
          ropt['DrawFog']           = false if ropt.key?('DrawFog')
          ropt['ModelTransparency'] = false if ropt.key?('ModelTransparency')
        rescue
          # If any RenderingOptions key is missing on this SU version,
          # skip silently — the PNG still exports, just without the
          # visual boost.
        end

        # zoom_extents now frames only the visible entities = selection
        view.zoom_extents
        view.refresh rescue nil

        # v5.91: back to 4,096 px — this is the safe max texture size
        # for ALL GPUs (older cards may cap at 4096; higher-end handle
        # 8192+ but 4096 works universally). With no downsampling on
        # import, combined with EdgeWidth 60 and Silhouettes 8, the
        # image reads clean and bold in any SU environment.
        target_max = 4_096
        vp_w = view.vpwidth.to_f
        vp_h = view.vpheight.to_f
        vp_h = 1.0 if vp_h < 1.0
        vp_w = 1.0 if vp_w < 1.0
        ratio = vp_w / vp_h
        if ratio >= 1.0
          out_w = target_max
          out_h = (target_max / ratio).round
        else
          out_h = target_max
          out_w = (target_max * ratio).round
        end

        # Hash-form write_image is SU 2015+ (well within our MIN_VERSION 19)
        view.write_image(
          filename:    path,
          width:       out_w,
          height:      out_h,
          antialias:   true,
          transparent: false
        )
      ensure
        # abort_operation undoes every visibility flip AND (in most SU
        # versions) the RenderingOptions changes we made above. Even if
        # write_image raised — this is what keeps the user's drawing
        # pristine and their undo stack clean.
        model.abort_operation rescue nil
        # Belt-and-braces: force-restore rendering options in case a
        # particular SU version tracks them outside the undo system.
        begin
          ropt['EdgeWidth']         = ew_saved        unless ew_saved.nil?
          ropt['DisplayShadows']    = shadow_saved    unless shadow_saved.nil?
          ropt['DrawFog']           = fog_saved       unless fog_saved.nil?
          ropt['ModelTransparency'] = xray_saved      unless xray_saved.nil?
          ropt['DrawSilhouettes']   = sil_saved       unless sil_saved.nil?
          ropt['SilhouetteWidth']   = silw_saved      unless silw_saved.nil?
          ropt['JitterEdges']       = jit_saved       unless jit_saved.nil?
          ropt['ExtendEdges']       = ext_saved       unless ext_saved.nil?
          ropt['EdgesEndpoints']    = endp_saved      unless endp_saved.nil?
          ropt['DrawEdges']         = profedges_saved unless profedges_saved.nil?
        rescue
        end
        view.camera = cam_saved
        Sketchup.set_status_text('')
      end
    end

    # ================================================================
    # SVG save
    # ================================================================
    def self.save_svg(sel, path)
      # Compute world-space bounds of the selection (in inches)
      bb = Geom::BoundingBox.new
      sel.each { |e| bb.add(e.bounds) if e.respond_to?(:bounds) }
      raise 'Empty selection bounds' unless bb.valid?

      x_min = bb.min.x.to_f;  x_max = bb.max.x.to_f
      y_min = bb.min.y.to_f;  y_max = bb.max.y.to_f

      # SVG viewBox in mm. y is flipped (SVG y-axis points down).
      w_mm = (x_max - x_min) * 25.4
      h_mm = (y_max - y_min) * 25.4
      w_mm = 1.0 if w_mm < 1.0
      h_mm = 1.0 if h_mm < 1.0

      ctx = {
        x_min: x_min, y_max: y_max,           # SVG (0,0) is (x_min, y_max)
        w_mm:  w_mm,  h_mm:  h_mm,
        body:  String.new(''),                # <line>, <path>, ... elements
        defs:  String.new(''),                # <pattern>, <image> in <defs>
        pat_idx: 0,
        emitted_patterns: {}                  # tex_path -> pattern id
      }

      traverse_svg(sel, Geom::Transformation.new, ctx)

      svg = build_svg_document(ctx)
      File.binwrite(path, svg)
    end

    # Build the final SVG XML string
    def self.build_svg_document(ctx)
      <<~SVG
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <svg xmlns="http://www.w3.org/2000/svg"
             xmlns:xlink="http://www.w3.org/1999/xlink"
             width="#{fmt(ctx[:w_mm])}mm"
             height="#{fmt(ctx[:h_mm])}mm"
             viewBox="0 0 #{fmt(ctx[:w_mm])} #{fmt(ctx[:h_mm])}">
          <defs>#{ctx[:defs]}</defs>
          <g fill="none" stroke="black" stroke-width="0.18" stroke-linecap="butt">
        #{ctx[:body]}
          </g>
        </svg>
      SVG
    end
    private_class_method :build_svg_document

    # Traverse selected entities recursively, emitting SVG for each
    def self.traverse_svg(entities, xform, ctx, parent_mat = nil, parent_edge_mat = nil)
      entities.each do |ent|
        next if ent.respond_to?(:hidden?) && ent.hidden?
        case ent
        when Sketchup::Group
          child_xform = xform * ent.transformation
          grp_mat     = ent.material || parent_mat
          ents_all    = ent.entities.to_a
          edge_only   = !ents_all.empty? && ents_all.all? { |e| e.is_a?(Sketchup::Edge) }
          child_edge_mat = edge_only ? (ent.material || parent_edge_mat) : nil
          traverse_svg(ent.entities, child_xform, ctx, grp_mat, child_edge_mat)
        when Sketchup::ComponentInstance
          child_xform = xform * ent.transformation
          child_mat   = ent.material || parent_mat
          def_ents    = ent.definition.entities.to_a
          edge_only   = !def_ents.empty? && def_ents.all? { |e| e.is_a?(Sketchup::Edge) }
          child_edge_mat = edge_only ? (ent.material || parent_edge_mat) : nil
          traverse_svg(ent.definition.entities, child_xform, ctx, child_mat, child_edge_mat)
        when Sketchup::Face
          emit_face_svg(ent, xform, ctx, parent_mat)
        when Sketchup::Edge
          emit_edge_svg(ent, xform, ctx, parent_edge_mat)
        end
      end
    end

    # ── Edge → <line> ───────────────────────────────────────────────────
    def self.emit_edge_svg(edge, xform, ctx, parent_edge_mat = nil)
      return if edge.respond_to?(:soft?) && edge.soft?
      p1 = edge.start.position.transform(xform)
      p2 = edge.end.position.transform(xform)
      x1, y1 = to_svg(p1.x, p1.y, ctx)
      x2, y2 = to_svg(p2.x, p2.y, ctx)

      # Line width from Feature C attribute (mm) or default
      lw_mm = edge.get_attribute(ATTR_NS, 'line_width_mm').to_f rescue 0.0
      lw_mm = 0.18 if lw_mm <= 0.0

      r, g, b = edge_rgb(edge, parent_edge_mat)
      stroke  = "rgb(#{(r*255).round},#{(g*255).round},#{(b*255).round})"

      # Dash pattern if the edge has a SketchUp line style
      dash_str = svg_dash_for_edge(edge)
      dash_attr = dash_str ? %( stroke-dasharray="#{dash_str}") : ''

      ctx[:body] << %(    <line x1="#{fmt(x1)}" y1="#{fmt(y1)}" x2="#{fmt(x2)}" y2="#{fmt(y2)}" stroke="#{stroke}" stroke-width="#{fmt(lw_mm)}"#{dash_attr}/>\n)
    end
    private_class_method :emit_edge_svg

    # ── Face → <path> ───────────────────────────────────────────────────
    def self.emit_face_svg(face, xform, ctx, parent_mat = nil)
      # Determine material
      mat = face.material || face.back_material || parent_mat

      if mat && mat.respond_to?(:texture) && mat.texture
        emit_textured_face_svg(face, xform, mat, ctx)
        return
      end

      # Solid fill
      r, g, b = mat_rgb(mat)
      fill = "rgb(#{(r*255).round},#{(g*255).round},#{(b*255).round})"

      d = face_path_data(face, xform, ctx)
      return if d.nil?
      ctx[:body] << %(    <path d="#{d}" fill="#{fill}" fill-rule="evenodd" stroke="none"/>\n)
    end
    private_class_method :emit_face_svg

    # Face with texture: embed image as <pattern> and use pattern as fill
    def self.emit_textured_face_svg(face, xform, mat, ctx)
      tex_path = texture_file_for_mat(mat)
      unless tex_path && File.exist?(tex_path)
        # Fallback to solid color if we cannot extract the texture
        r, g, b = mat_rgb(mat)
        fill = "rgb(#{(r*255).round},#{(g*255).round},#{(b*255).round})"
        d = face_path_data(face, xform, ctx)
        return if d.nil?
        ctx[:body] << %(    <path d="#{d}" fill="#{fill}" fill-rule="evenodd" stroke="none"/>\n)
        return
      end

      pat_id = ctx[:emitted_patterns][tex_path]
      unless pat_id
        pat_id = "pat#{ctx[:pat_idx]}"
        ctx[:pat_idx] += 1
        ctx[:emitted_patterns][tex_path] = pat_id

        # Tile size in mm (uses texture's declared size, converted from model units)
        lu = Sketchup.active_model.options['UnitsOptions']['LengthUnit'].to_i rescue 0
        unit_to_mm = [25.4, 304.8, 1.0, 10.0, 1000.0][lu] || 25.4
        tex = mat.texture
        tw_mm = tex.width  * unit_to_mm
        th_mm = tex.height * unit_to_mm
        tw_mm = 1.0 if tw_mm < 0.5
        th_mm = 1.0 if th_mm < 0.5

        ext = File.extname(tex_path).downcase
        mime = ['.jpg', '.jpeg'].include?(ext) ? 'image/jpeg' : 'image/png'
        data = File.binread(tex_path)
        b64  = Base64.strict_encode64(data)

        ctx[:defs] << %(
          <pattern id="#{pat_id}" patternUnits="userSpaceOnUse" width="#{fmt(tw_mm)}" height="#{fmt(th_mm)}">
            <image xlink:href="data:#{mime};base64,#{b64}" x="0" y="0" width="#{fmt(tw_mm)}" height="#{fmt(th_mm)}" preserveAspectRatio="none"/>
          </pattern>
        )
      end

      d = face_path_data(face, xform, ctx)
      return if d.nil?
      ctx[:body] << %(    <path d="#{d}" fill="url(##{pat_id})" fill-rule="evenodd" stroke="none"/>\n)
    end
    private_class_method :emit_textured_face_svg

    # Build the SVG "d" attribute for a face (all loops, even-odd fill)
    def self.face_path_data(face, xform, ctx)
      parts = []
      face.loops.each do |lp|
        verts = lp.vertices
        next if verts.length < 3
        first = true
        verts.each do |v|
          pt = v.position.transform(xform)
          x, y = to_svg(pt.x, pt.y, ctx)
          parts << (first ? "M #{fmt(x)} #{fmt(y)}" : "L #{fmt(x)} #{fmt(y)}")
          first = false
        end
        parts << 'Z'
      end
      parts.empty? ? nil : parts.join(' ')
    end
    private_class_method :face_path_data

    # ── Colour lookups (mirrors pdf_export.rb rules for consistency) ────
    def self.edge_rgb(edge, parent_edge_mat = nil)
      if edge.material && edge.material.respond_to?(:color) && edge.material.color
        c = edge.material.color
        return [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
      end
      if parent_edge_mat && parent_edge_mat.respond_to?(:color) && parent_edge_mat.color
        unless parent_edge_mat.respond_to?(:texture) && parent_edge_mat.texture
          c = parent_edge_mat.color
          return [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
        end
      end
      if edge.layer
        lname = edge.layer.name.to_s
        unless lname == 'Untagged' || lname == 'Layer0' || lname.empty?
          if edge.layer.respond_to?(:color) && edge.layer.color
            c = edge.layer.color
            return [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
          end
        end
      end
      [0.0, 0.0, 0.0]
    rescue
      [0.0, 0.0, 0.0]
    end
    private_class_method :edge_rgb

    def self.mat_rgb(mat)
      if mat && mat.respond_to?(:color) && mat.color
        c = mat.color
        [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
      else
        [1.0, 1.0, 1.0]   # default white
      end
    end
    private_class_method :mat_rgb

    def self.svg_dash_for_edge(edge)
      return nil unless edge.respond_to?(:line_style) && edge.line_style
      name = edge.line_style.respond_to?(:name) ? edge.line_style.name : edge.line_style.to_s
      case name
      when /solid/i           then nil
      when /^Dash$/i          then '4,2'
      when /Short dash/i      then '2,1'
      when /^Dot$/i           then '0.1,2'
      when /Dash dot/i        then '8,2,0.1,2'
      when /Long-dash/i       then '12,2,4,2'
      else
        # Fallback for any other patterned style
        '4,2'
      end
    rescue
      nil
    end
    private_class_method :svg_dash_for_edge

    # Extract material texture to a temp file so we can embed it in SVG
    def self.texture_file_for_mat(mat)
      return nil unless mat && mat.respond_to?(:texture) && mat.texture
      tex  = mat.texture
      orig = tex.filename.to_s
      return orig if orig.length > 0 && File.exist?(orig)

      if tex.respond_to?(:image_rep)
        safe   = mat.name.to_s.gsub(/[^A-Za-z0-9]/i, '_')[0, 40]
        tmpdir = ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir rescue '/tmp'
        dest   = File.join(tmpdir, "sd_snap_tex_#{safe}.png")
        unless File.exist?(dest)
          rep = tex.image_rep
          rep.save_file(dest) if rep && rep.respond_to?(:save_file)
        end
        return dest if File.exist?(dest)
      end
      nil
    rescue
      nil
    end
    private_class_method :texture_file_for_mat

    # ── Coordinate & format helpers ─────────────────────────────────────
    # SketchUp world coords (inches, y up) → SVG viewBox coords (mm, y down)
    def self.to_svg(x_in, y_in, ctx)
      [((x_in - ctx[:x_min]) * 25.4),
       ((ctx[:y_max] - y_in) * 25.4)]
    end
    private_class_method :to_svg

    def self.fmt(v)
      format('%.4f', v.to_f).sub(/\.?0+$/, '')
    end
    private_class_method :fmt

    # ================================================================
    # Placement tool for loading a snapshot back into a drawing
    # ================================================================
    class LoadTool
      def initialize(defn)
        @defn = defn
        @ip   = Sketchup::InputPoint.new
      end

      def activate
        Sketchup.set_status_text("Click to place snapshot '#{@defn.name}' (Esc to cancel)")
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        @ip.pick(view, x, y)
        pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
        model = Sketchup.active_model
        model.start_operation('Load Snapshot', true)
        inst = model.active_entities.add_instance(@defn, Geom::Transformation.new(pt))
        model.commit_operation
        model.selection.clear
        model.selection.add(inst)
        UI.start_timer(0.0, false) { Sketchup.active_model.select_tool(nil) }
      end

      def onKeyDown(key, _r, _f, _v)
        Sketchup.active_model.select_tool(nil) if key == 27
      end
    end
  end
end
