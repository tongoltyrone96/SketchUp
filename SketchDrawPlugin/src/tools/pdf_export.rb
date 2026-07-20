module SketchDraw
  module PdfExport
    ATTR_NS      = SketchDraw::PLUGIN_ID
    PDF_FONT_MAP = {
      'Arial'           => 'Helvetica',
      'Times New Roman' => 'Times-Roman',
      'Courier New'     => 'Courier',
      'Helvetica'       => 'Helvetica',
      'Times'           => 'Times-Roman',
      'Courier'         => 'Courier'
    }.freeze

    # All 12 SketchUp built-in line styles — dash arrays follow ISO 128-20 paper-space sizes.
    #
    # ISO 128-20 specifies line-type dimensions in mm on printed paper:
    #   dashed line     : dash 4mm, gap 2mm
    #   chain line      : long-dash 8mm, gap 2mm, dot 0.5mm, gap 2mm
    #   double-chain    : long-dash 8mm, gap 2mm, dot 0.5mm, gap 2mm, dot 0.5mm, gap 2mm
    #   long-dash line  : 12mm dash, 2mm gap
    #
    # These are PAPER-SPACE millimetres (physical size on the printed sheet), independent of
    # drawing scale (1:50, 1:100 …).  PDF renders them at the same physical size at any
    # zoom level — which is correct for printed technical drawings.
    # SketchUp's viewport, by contrast, keeps dashes at a FIXED PIXEL size regardless of zoom,
    # so they appear larger/smaller relative to geometry as you zoom in/out; the PDF behaviour
    # (constant paper-mm size) is the professional standard.
    _MM = 72.0 / 25.4
    STYLE_MAP = {
      'Solid Basic'            => nil,
      'Short dash'             => [2*_MM,  1*_MM],                                                                             # ISO: short dash 2mm/1mm
      'Dash'                   => [4*_MM,  2*_MM],                                                                             # ISO: dash 4mm/2mm
      'Dot'                    => [0,       2*_MM],                                                                            # dot = zero-length + round cap → circular
      'Dash dot'               => [8*_MM, 2*_MM, 0,       2*_MM],                                                             # ISO: chain line
      'Dash double-dot'        => [8*_MM, 2*_MM, 0,       2*_MM, 0,       2*_MM],                                            # ISO: double-chain
      'Dash triple-dot'        => [8*_MM, 2*_MM, 0,       2*_MM, 0,       2*_MM, 0,       2*_MM],                           # ISO: triple-chain
      'Double-dash dot'        => [8*_MM, 2*_MM, 8*_MM, 2*_MM, 0,       2*_MM],                                            # Two identical dashes (Double = same repeat)
      'Double-dash double-dot' => [8*_MM, 2*_MM, 8*_MM, 2*_MM, 0,       2*_MM, 0,       2*_MM],
      'Double-dash triple-dot' => [8*_MM, 2*_MM, 8*_MM, 2*_MM, 0,       2*_MM, 0,       2*_MM, 0,       2*_MM],
      'Long-dash dash'         => [12*_MM, 2*_MM, 4*_MM, 2*_MM],                                                              # ISO: long-short dash
      'Long-dash double-dash'  => [12*_MM, 2*_MM, 4*_MM, 2*_MM, 4*_MM, 2*_MM],
    }.transform_values { |v| v&.map { |x| x.round(2) } }.freeze

    DASH_FALLBACK = [
      [/solid/i,             nil],
      [/long[\s_-]+dash/i,   [12*_MM, 2*_MM].map { |v| v.round(2) }],
      [/short[\s_-]+dash/i,  [2*_MM,  1*_MM].map { |v| v.round(2) }],
      [/triple[\s_-]*dot/i,  [8*_MM, 2*_MM, 0.5*_MM, 2*_MM, 0.5*_MM, 2*_MM, 0.5*_MM, 2*_MM].map { |v| v.round(2) }],
      [/double[\s_-]*dot/i,  [8*_MM, 2*_MM, 0.5*_MM, 2*_MM, 0.5*_MM, 2*_MM].map { |v| v.round(2) }],
      [/dot/i,               [8*_MM, 2*_MM, 0.5*_MM, 2*_MM].map { |v| v.round(2) }],
      [/dash/i,              [4*_MM, 2*_MM].map { |v| v.round(2) }],
    ].freeze

    def self.log(msg)
      puts "[SketchDraw PDF] #{msg}"
    end
    private_class_method :log

    # ── Entry point ──────────────────────────────────────────────────────
    def self.run
      model = Sketchup.active_model
      return unless SketchDraw.version_ok?

      frame = PaperFrame.find_frame(model)
      unless frame
        UI.messagebox('No paper frame found. Please insert a paper frame first (Paper button).', MB_OK)
        return
      end

      pdf_path = UI.savepanel('Export PDF', '', 'PDF Files|*.pdf||')
      return unless pdf_path
      pdf_path += '.pdf' unless pdf_path.end_with?('.pdf')

      paper_w_mm = frame.get_attribute(ATTR_NS, 'width').to_f
      paper_h_mm = frame.get_attribute(ATTR_NS, 'height').to_f

      log "--- START --- path=#{pdf_path}"
      log "Paper attr: width=#{paper_w_mm}mm height=#{paper_h_mm}mm"

      prog = UI::HtmlDialog.new(
        dialog_title: 'SketchDraw — PDF Export',
        width: 400, height: 130,
        left: 560, top: 420,
        resizable: false, scrollable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      prog.set_html(<<~HTML)
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body { background:#1e1e1e; color:#fff; font-family:Arial,sans-serif;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; text-align:center; }
          .msg { font-size:15px; font-weight:bold; }
          .sub { font-size:12px; opacity:0.6; margin-top:8px; }
        </style></head>
        <body>
          <div>
            <div class="msg">Exporting PDF...</div>
            <div class="sub">Please wait — building vector PDF</div>
          </div>
        </body></html>
      HTML
      prog.show

      UI.start_timer(0.3, false) do
        perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      end
    end

    # ── Core export ──────────────────────────────────────────────────────
    def self.perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      fb   = frame.bounds
      @fx0 = fb.min.x
      @fy0 = fb.min.y
      @wpt = (paper_w_mm * 72.0 / 25.4).round(4)
      @hpt = (paper_h_mm * 72.0 / 25.4).round(4)
      @images       = {}
      @img_idx      = 0
      @used_fonts   = {}
      @image_paths  = {}   # tex_path → img_key (dedup same image across different tile sizes)
      @texture_keys = {}   # "imgKey_tileW_tileH" → pat_key
      @patterns     = {}   # pat_key → { tw, th, img }
      @pattern_idx  = 0
      @ext_gstates  = {}   # alpha (rounded) → gs_name
      @gs_idx       = 0
      @used_fonts['Helvetica'] = 'F1'   # always pre-register so BT ops never reference undefined font

      # tex.width/height are returned in the model's display units (mm/cm/m/in/ft) → convert to inches
      # LengthUnit: 0=in, 1=ft, 2=mm, 3=cm, 4=m
      lu = Sketchup.active_model.options['UnitsOptions']['LengthUnit'].to_i rescue 0
      @tex_unit_to_in = [1.0, 12.0, 1.0/25.4, 1.0/2.54, 39.3701][lu] || 1.0
      log "Model LengthUnit=#{lu}  tex_unit_to_in=#{@tex_unit_to_in.round(6)}"

      log "Frame bounds min=(#{@fx0.round(4)}, #{@fy0.round(4)})"
      log "PDF page: #{@wpt}pt x #{@hpt}pt"

      if @wpt < 1 || @hpt < 1
        log "ERROR: invalid page size (#{@wpt} x #{@hpt}) — paper attributes missing?"
        UI.messagebox("PDF export error: page size is 0.\nPlease re-insert the paper frame.", MB_OK)
        prog.close rescue nil
        return
      end

      Sketchup.set_status_text('SketchDraw: building vector PDF...')

      face_buf = String.new('', encoding: 'BINARY')
      edge_buf = String.new('', encoding: 'BINARY')

      log "Traversing entities (count=#{model.active_entities.count})..."
      traverse(model.active_entities, Geom::Transformation.new, face_buf, edge_buf)

      log "face_buf: #{face_buf.bytesize} bytes"
      log "edge_buf: #{edge_buf.bytesize} bytes"
      log "images registered: #{@images.length} — #{@images.keys.inspect}"
      log "fonts registered:  #{@used_fonts.inspect}"

      # Expand clip 1pt beyond page boundary so frame border edges (at exactly 0/wpt/hpt) render fully
      clip    = "-1 -1 #{fn(@wpt + 2)} #{fn(@hpt + 2)} re W n\n"
      content = String.new('', encoding: 'BINARY')
      content << "q\n"
      content << clip.encode('BINARY')
      content << face_buf
      content << edge_buf
      content << "Q\n"

      log "content stream: #{content.bytesize} bytes  encoding=#{content.encoding}"

      pdf_bytes = build_pdf(content)
      log "PDF binary: #{pdf_bytes.bytesize} bytes  encoding=#{pdf_bytes.encoding}"

      File.binwrite(pdf_path, pdf_bytes)
      actual_size = File.size(pdf_path)
      log "File written: #{actual_size} bytes at #{pdf_path}"

      Sketchup.set_status_text('')
      prog.close rescue nil
      UI.messagebox("PDF saved (#{actual_size} bytes):\n#{pdf_path}", MB_OK)
    rescue => e
      Sketchup.set_status_text('')
      prog.close rescue nil
      log "EXCEPTION: #{e.class}: #{e.message}"
      e.backtrace.first(8).each { |l| log "  #{l}" }
      UI.messagebox("PDF export error:\n#{e.class}: #{e.message}", MB_OK)
    end
    private_class_method :perform_export

    # ── Entity traversal ─────────────────────────────────────────────────
    # parent_mat: material inherited for faces (grp.material || upstream inheritance)
    # parent_edge_mat: material inherited for edges. Only non-nil for "edge only" groups (decorative outlines).
    #                  For structural groups, this is nil → edges stay black.
    def self.traverse(entities, xform, fbuf, ebuf, parent_mat = nil, parent_edge_mat = nil)
      entities.each do |ent|
        next if ent_hidden?(ent)
        case ent
        when Sketchup::Group
          emit_group(ent, xform, fbuf, ebuf, parent_mat, parent_edge_mat)
        when Sketchup::ComponentInstance
          log "  ComponentInstance: #{ent.definition.name}"
          child_mat = ent.material || parent_mat
          # Same rule for Component: if definition is edge-only, propagate edge material; otherwise nil
          def_ents = ent.definition.entities.to_a
          is_edge_only = !def_ents.empty? && def_ents.all? { |e| e.is_a?(Sketchup::Edge) }
          child_edge_mat = is_edge_only ? (ent.material || parent_edge_mat) : nil
          traverse(ent.definition.entities, xform * ent.transformation, fbuf, ebuf, child_mat, child_edge_mat)
        when Sketchup::Face
          emit_face(ent, xform, fbuf, parent_mat)
        when Sketchup::Edge
          emit_edge(ent, xform, ebuf, parent_edge_mat)
        when Sketchup::Text
          emit_su_text(ent, xform, ebuf)
        when Sketchup::DimensionLinear
          emit_dimension(ent, xform, ebuf)
        end
      end
    end
    private_class_method :traverse

    def self.ent_hidden?(ent)
      return true if ent.respond_to?(:hidden?) && ent.hidden?
      return true if ent.respond_to?(:layer) && ent.layer && !ent.layer.visible?
      false
    end
    private_class_method :ent_hidden?

    def self.emit_group(grp, xform, fbuf, ebuf, parent_mat = nil, parent_edge_mat = nil)
      type        = grp.get_attribute(ATTR_NS, 'type')
      child_xform = xform * grp.transformation
      grp_mat     = grp.material || parent_mat   # for faces
      log "  Group name=#{grp.name.inspect} type=#{type.inspect} entities=#{grp.entities.count}"

      # Edge-inheritance rule: only propagate group material to edges if this group is edge-only
      # (a decorative outline). Structural groups (containing faces/subgroups) keep edges black,
      # matching SketchUp's default rendering behavior.
      ents_all = grp.entities.to_a
      is_edge_only_group = !ents_all.empty? && ents_all.all? { |e| e.is_a?(Sketchup::Edge) }
      child_edge_mat = is_edge_only_group ? (grp.material || parent_edge_mat) : nil

      # Auto-detect concentric ring pairs (couplers, bolts, etc.)
      if type.nil?
        edges_only = ents_all.grep(Sketchup::Edge)
        no_other   = ents_all.length == edges_only.length
        if no_other && edges_only.length >= 20 && edges_only.length <= 200
          rings = find_concentric_rings(edges_only)
          if rings.any?
            log "  [ring] #{rings.length} concentric pair(s) detected → thin stroke outlines"
            consumed = {}
            rings.each do |pair|
              emit_ring(pair, child_xform, fbuf, child_edge_mat)
              pair[:outer][:edges].each { |e| consumed[e.object_id] = true }
              pair[:inner][:edges].each { |e| consumed[e.object_id] = true }
            end
            edges_only.each do |e|
              next if consumed[e.object_id]
              next if ent_hidden?(e)
              emit_edge(e, child_xform, ebuf, child_edge_mat)
            end
            return
          end
        end
      end

      case type
      when 'image' then emit_image_group(grp, fbuf)
      when 'text'  then emit_text_group(grp, child_xform, ebuf)
      else              traverse(grp.entities, child_xform, fbuf, ebuf, grp_mat, child_edge_mat)
      end
    end
    private_class_method :emit_group

    # ── Concentric ring detection & rendering ─────────────────────────────
    # Build a hashable tuple from a Point3d for use as a graph vertex key.
    def self.pos_key(pt)
      [pt.x.to_f.round(4), pt.y.to_f.round(4), pt.z.to_f.round(4)]
    end
    private_class_method :pos_key

    # Walk connected edges starting from start_edge to trace a closed cycle.
    # Returns { edges: [...], vertices: [...] } on success, nil if not closed.
    def self.trace_cycle(start_edge, vertex_edges, visited)
      cycle_edges = [start_edge]
      visited[start_edge.object_id] = true

      start_pos = start_edge.start.position
      current   = start_edge.end.position
      verts     = [start_pos, current]

      loop do
        candidates = vertex_edges[pos_key(current)].reject { |e| visited[e.object_id] }
        break if candidates.empty?
        nxt = candidates.first
        cycle_edges << nxt
        visited[nxt.object_id] = true
        next_pos = (nxt.start.position == current) ? nxt.end.position : nxt.start.position
        current = next_pos
        if pos_key(current) == pos_key(start_pos)
          return { edges: cycle_edges, vertices: verts }
        end
        verts << current
      end
      nil
    end
    private_class_method :trace_cycle

    # Fit a circle to the given vertices → returns [center(Point3d), radius(Float), max_error(Float)].
    def self.fit_circle(vertices)
      n = vertices.length
      return [nil, 0, Float::INFINITY] if n < 3
      cx = vertices.map { |v| v.x.to_f }.inject(0.0, :+) / n
      cy = vertices.map { |v| v.y.to_f }.inject(0.0, :+) / n
      radii = vertices.map { |v| Math.sqrt((v.x.to_f - cx)**2 + (v.y.to_f - cy)**2) }
      r_avg = radii.inject(0.0, :+) / n
      err   = radii.map { |r| (r - r_avg).abs }.max
      [Geom::Point3d.new(cx, cy, 0), r_avg, err]
    end
    private_class_method :fit_circle

    # Find concentric ring pairs among the given edges.
    # Returns: [{outer: {edges, vertices, center, radius}, inner: {...}}, ...]
    def self.find_concentric_rings(edges)
      vertex_edges = Hash.new { |h, k| h[k] = [] }
      edges.each do |e|
        vertex_edges[pos_key(e.start.position)] << e
        vertex_edges[pos_key(e.end.position)]   << e
      end

      visited = {}
      cycles  = []
      edges.each do |edge|
        next if visited[edge.object_id]
        cd = trace_cycle(edge, vertex_edges, visited)
        cycles << cd if cd && cd[:edges].length >= 10
      end
      return [] if cycles.length < 2

      circles = []
      cycles.each do |cd|
        c, r, err = fit_circle(cd[:vertices])
        next if r <= 0.001
        next if err > r * 0.05   # not a circle, skip
        circles << { edges: cd[:edges], vertices: cd[:vertices], center: c, radius: r }
      end

      pairs = []
      used  = {}
      circles.each_with_index do |c1, i|
        next if used[i]
        circles.each_with_index do |c2, j|
          next if j <= i || used[j]
          d = Math.sqrt((c1[:center].x - c2[:center].x)**2 + (c1[:center].y - c2[:center].y)**2)
          min_r = [c1[:radius], c2[:radius]].min
          if d < min_r * 0.3   # centers are close enough → treat as concentric
            outer = c1[:radius] > c2[:radius] ? c1 : c2
            inner = c1[:radius] > c2[:radius] ? c2 : c1
            pairs << { outer: outer, inner: inner }
            used[i] = true
            used[j] = true
            break
          end
        end
      end
      pairs
    end
    private_class_method :find_concentric_rings

    # Emit a concentric pair as two thin stroked outlines.
    # Key detail: apply xform's actual scale (ScaleTool compression) so the line width is
    # determined by the true world/PDF-space ring gap. Otherwise the two strokes overlap
    # in world space and merge into a single thick ring.
    def self.emit_ring(pair, xform, fbuf, parent_mat = nil)
      first_edge = pair[:outer][:edges].first
      r, g, b = edge_rgb(first_edge, parent_mat)

      # Extract world scale (reflects ScaleTool compression)
      scale_f = begin
        if xform.respond_to?(:xscale)
          xform.xscale.abs
        else
          Geom::Vector3d.new(1, 0, 0).transform(xform).length
        end
      rescue
        1.0
      end
      scale_f = 1.0 if scale_f <= 0.0

      # Actual ring gap in world/PDF space
      gap_local_in = pair[:outer][:radius] - pair[:inner][:radius]   # local inches
      gap_pt       = gap_local_in * scale_f * 72.0                    # PDF pt

      # Line width: 40% of the actual gap so the two strokes always fit inside it.
      # min 0.1pt (very thin but visible when zoomed), max 0.5pt
      lw = gap_pt * 0.4
      lw = 0.1 if lw < 0.1
      lw = 0.5 if lw > 0.5

      log "  [ring_emit] scale=#{scale_f.round(4)} gap=#{gap_pt.round(3)}pt lw=#{fn(lw)}"

      fbuf << "q\n"
      fbuf << "#{fn(r)} #{fn(g)} #{fn(b)} RG #{fn(lw)} w 0 J [] 0 d\n"

      # Outer circle stroke
      pair[:outer][:vertices].each_with_index do |v, i|
        wp = v.transform(xform)
        px, py = su_to_pdf(wp.x, wp.y)
        fbuf << "#{fn(px)} #{fn(py)} #{i == 0 ? 'm' : 'l'}\n"
      end
      fbuf << "h S\n"

      # Inner circle stroke
      pair[:inner][:vertices].each_with_index do |v, i|
        wp = v.transform(xform)
        px, py = su_to_pdf(wp.x, wp.y)
        fbuf << "#{fn(px)} #{fn(py)} #{i == 0 ? 'm' : 'l'}\n"
      end
      fbuf << "h S\n"

      fbuf << "Q\n"
    end
    private_class_method :emit_ring

    # ── Image group ───────────────────────────────────────────────────────
    def self.emit_image_group(grp, fbuf)
      path = grp.get_attribute(ATTR_NS, 'orig_path')
      log "  [image] orig_path=#{path.inspect}"

      unless path
        log "  [image] SKIP: no orig_path attribute"
        return
      end
      unless File.exist?(path)
        log "  [image] SKIP: file not found at #{path}"
        return
      end

      b  = grp.bounds
      pw = b.width  * 72.0
      ph = b.height * 72.0
      log "  [image] bounds: width=#{b.width.round(4)}in height=#{b.height.round(4)}in => #{pw.round(1)}x#{ph.round(1)}pt"

      if pw < 0.01 || ph < 0.01
        log "  [image] SKIP: zero size"
        return
      end

      file_size = File.size(path)
      ext       = File.extname(path).downcase
      log "  [image] reading file: #{file_size} bytes  ext=#{ext}"

      raw = File.binread(path) rescue (log "  [image] ERROR reading file"; return)

      log "  [image] calling image_payload..."
      w, h, filt, payload, alpha_payload = image_payload(raw, ext)
      log "  [image] image_payload result: w=#{w} h=#{h} filter=#{filt.inspect} payload=#{payload&.bytesize}bytes alpha=#{alpha_payload&.bytesize}bytes"

      unless w && w > 0 && payload
        log "  [image] SKIP: image_payload failed"
        return
      end

      px, py = su_to_pdf(b.min.x, b.min.y)
      name   = "Im#{@img_idx}"
      @img_idx += 1
      @images[name] = { w: w, h: h, filter: filt, data: payload, alpha: alpha_payload }
      log "  [image] registered as #{name}  pdf_pos=(#{px.round(1)},#{py.round(1)})  pdf_size=#{pw.round(1)}x#{ph.round(1)}"
      fbuf << "q #{fn(pw)} 0 0 #{fn(ph)} #{fn(px)} #{fn(py)} cm /#{name} Do Q\n"
    end
    private_class_method :emit_image_group

    # ── Text group (type='text', has text_props) ──────────────────────────
    def self.emit_text_group(grp, xform, ebuf)
      json = grp.get_attribute(ATTR_NS, 'text_props')
      return unless json
      props = JSON.parse(json) rescue (log "  [text] JSON parse failed"; return)
      content = props['content'].to_s
      return if content.empty?
      content = content.upcase if props['is_caps']
      fp = map_font(props['font'])
      sz = [props['size_pt'].to_f, 1.0].max
      r, g, b = hex_rgb(props['color'] || '#000000')
      register_font(fp)
      fk = @used_fonts[fp]

      log "  [text] content=#{content[0, 40].inspect} font=#{fp} size=#{sz}"

      line_grps = grp.entities.grep(Sketchup::Group).sort_by do |lg|
        -(xform * lg.transformation).origin.y
      end

      if line_grps.empty?
        log "  [text] SKIP: no line sub-groups found"
        return
      end

      non_empty = content.split("\n").map(&:strip).reject(&:empty?)
      non_empty.each_with_index do |line, i|
        lg = line_grps[i] || line_grps.last
        t  = (xform * lg.transformation).origin
        ox, oy = su_to_pdf(t.x, t.y)
        log "  [text] line#{i}: #{line[0,30].inspect} pos=(#{ox.round(1)},#{oy.round(1)})"
        ebuf << "BT /#{fk} #{fn(sz)} Tf #{fn(r)} #{fn(g)} #{fn(b)} rg " \
                "#{fn(ox)} #{fn(oy)} Td (#{pdf_escape(line)}) Tj ET\n"
      end
    end
    private_class_method :emit_text_group

    # ── Sketchup::Text (title block field values, leader text) ────────────
    def self.emit_su_text(txt, xform, ebuf)
      str = begin
        txt.respond_to?(:string) ? txt.string.to_s : txt.text.to_s
      rescue
        ''
      end
      str = str.strip
      return if str.empty?
      pt = txt.respond_to?(:point) ? txt.point : nil
      return unless pt
      wp = pt.transform(xform)
      px, py = su_to_pdf(wp.x, wp.y)
      register_font('Helvetica')
      fk = @used_fonts['Helvetica']
      log "  [su_text] #{str[0,30].inspect} pos=(#{px.round(1)},#{py.round(1)})"
      ebuf << "BT /#{fk} 7 Tf 0 0 0 rg #{fn(px)} #{fn(py)} Td (#{pdf_escape(str)}) Tj ET\n"
    end
    private_class_method :emit_su_text

    # ── Face (filled polygon) ─────────────────────────────────────────────
    def self.emit_face(face, xform, fbuf, parent_mat = nil)
      # Track which side's material is used (needed for UV selection below)
      mat = face.material
      from_back = false
      if mat.nil? && face.back_material
        mat = face.back_material
        from_back = true
      end
      mat ||= parent_mat

      if mat && mat.respond_to?(:texture) && mat.texture
        tex_path = texture_file_for_mat(mat)
        if tex_path
          emit_textured_face(face, xform, mat, tex_path, fbuf, from_back)
          return
        end
      end

      emit_face_solid(face, xform, mat, fbuf)
    end
    private_class_method :emit_face

    def self.emit_face_solid(face, xform, mat, fbuf)
      r, g, b = mat_rgb(mat, 1.0)
      fbuf << "#{fn(r)} #{fn(g)} #{fn(b)} rg\n"
      face.loops.each do |loop|
        pts = loop.vertices.map { |v| v.position.transform(xform) }
        next if pts.length < 3
        px0, py0 = su_to_pdf(pts[0].x, pts[0].y)
        fbuf << "#{fn(px0)} #{fn(py0)} m\n"
        pts[1..-1].each do |pt|
          px, py = su_to_pdf(pt.x, pt.y)
          fbuf << "#{fn(px)} #{fn(py)} l\n"
        end
        fbuf << "h\n"
      end
      fbuf << "f*\n"
    end
    private_class_method :emit_face_solid

    # Renders a face using a PDF Tiling Pattern with a full affine UV→world matrix.
    #
    # The pattern's /Matrix [A B C D Tx Ty] is derived from 3 non-collinear face vertices,
    # mapping (u,v) UV coords → (Wx,Wy) PDF world coords. This captures rotation, scale,
    # translation, and skew — replicating SketchUp's UV mapping exactly.
    #
    # Formula: Wx = A·u + C·v + Tx,  Wy = B·u + D·v + Ty
    #
    # Pattern object uses unit tile (BBox [0 0 1 1], XStep 1 YStep 1), and the image
    # fills that unit tile via `/Im Do`. All positioning/scaling/rotation lives in Matrix.
    #
    # Fallback: if UV lookup fails or vertices are collinear, use an axis-aligned matrix
    # derived from tex.width/height × ScaleTool factor.
    def self.emit_textured_face(face, xform, mat, tex_path, fbuf, from_back = false)
      verts = face.outer_loop.vertices
      return emit_face_solid(face, xform, mat, fbuf) if verts.length < 3

      outer_pts = verts.map { |v| v.position.transform(xform) }
      xs = outer_pts.map(&:x); ys = outer_pts.map(&:y)
      x_min, x_max = xs.min, xs.max
      y_min, y_max = ys.min, ys.max
      px_min, py_min = su_to_pdf(x_min, y_min)
      px_max, py_max = su_to_pdf(x_max, y_max)
      pw = (px_max - px_min).abs
      ph = (py_max - py_min).abs
      return emit_face_solid(face, xform, mat, fbuf) if pw < 0.01 || ph < 0.01

      # Decide which UV side to use (assuming a top-down 2D view):
      # - If back_material is being rendered → back UV
      # - If front normal points -Z (facing down) → back side faces the viewer → back UV
      # - Otherwise → front UV
      world_normal_z = begin
        face.normal.transform(xform).z
      rescue
        1.0
      end
      use_back_uv = from_back || world_normal_z < 0

      # Compute affine matrix from UV mapping (preferred path).
      matrix = compute_uv_matrix(face, verts, xform, use_back_uv)

      # Fallback: axis-aligned matrix using tex.width×tex.height and ScaleTool factor.
      if matrix.nil?
        local_p0 = verts[0].position
        local_p1 = verts.length > 1 ? verts[1].position : verts[0].position
        local_d  = local_p0.distance(local_p1)
        world_d  = outer_pts[0].distance(outer_pts.length > 1 ? outer_pts[1] : outer_pts[0])
        scale_f  = (local_d > 1e-10) ? world_d / local_d : 1.0
        tw       = [(mat.texture.width  * @tex_unit_to_in * 72.0 * scale_f).round(4), 0.5].max
        th       = [(mat.texture.height * @tex_unit_to_in * 72.0 * scale_f).round(4), 0.5].max
        matrix   = [tw, 0.0, 0.0, th, px_min, py_min]
        log "  [tex_uv] fallback matrix (UV lookup failed) tile=#{tw.round(1)}x#{th.round(1)}pt"
      end

      # Respect the actual alpha value set on the SketchUp material.
      # (If mat.alpha = 1.0, get_or_create_gs returns nil so no ExtGState is emitted.)
      raw_alpha = mat.respond_to?(:alpha) ? mat.alpha.to_f : 1.0
      raw_alpha = 1.0 if raw_alpha <= 0.0 || raw_alpha > 1.0
      gs_name   = get_or_create_gs(raw_alpha)

      # Image dedup: embed each unique texture file only once
      img_key = @image_paths[tex_path]
      unless img_key
        ext = File.extname(tex_path).downcase
        raw = File.binread(tex_path) rescue nil
        return emit_face_solid(face, xform, mat, fbuf) unless raw
        img_w, img_h, filt, payload, alpha_payload = image_payload(raw, ext)
        return emit_face_solid(face, xform, mat, fbuf) unless img_w && img_w > 0 && payload
        img_key = "Im#{@img_idx}"; @img_idx += 1
        @images[img_key]       = { w: img_w, h: img_h, filter: filt, data: payload, alpha: alpha_payload }
        @image_paths[tex_path] = img_key
        log "  [tex_img] #{img_key} #{img_w}x#{img_h} path=#{File.basename(tex_path)} alpha=#{alpha_payload ? 'yes' : 'no'}"
      end

      # Pattern dedup — reuse when the same image+matrix combination already exists
      mat_key   = matrix.map { |v| v.round(3) }.join('_')
      pat_cache = "#{img_key}_m_#{mat_key}"
      pat_key   = @texture_keys[pat_cache]
      unless pat_key
        pat_key = "Pat#{@pattern_idx}"; @pattern_idx += 1
        @patterns[pat_key]       = { matrix: matrix, img: img_key }
        @texture_keys[pat_cache] = pat_key
        log "  [tex_pat] #{pat_key} mat=#{mat.name} M=[#{matrix.map { |v| v.round(2) }.join(',')}]"
      end

      # Fill: clip to the face outline and fill with the pattern. Matrix handles position/rotation/scale.
      fbuf << "q\n"
      face.loops.each do |lp|
        lp.vertices.each_with_index do |v, i|
          pt = v.position.transform(xform)
          px, py = su_to_pdf(pt.x, pt.y)
          fbuf << "#{fn(px)} #{fn(py)} #{i == 0 ? 'm' : 'l'}\n"
        end
        fbuf << "h\n"
      end
      fbuf << "W* n\n"
      fbuf << "/#{gs_name} gs\n" if gs_name
      fbuf << "/Pattern cs /#{pat_key} scn\n"
      fbuf << "#{fn(px_min)} #{fn(py_min)} #{fn(pw)} #{fn(ph)} re f\n"
      fbuf << "Q\n"
    end
    private_class_method :emit_textured_face

    # ── UV → world affine matrix computation ──────────────────────────
    # Collect UV and world coordinates from the face vertices, then solve for a
    # 6-parameter affine matrix [A B C D Tx Ty] using 3 non-collinear points.
    # If use_back=true, back-side UVs (get_back_UVQ) are used instead.
    # Returns nil on failure so the caller can fall back to an axis-aligned matrix.
    def self.compute_uv_matrix(face, verts, xform, use_back = false)
      return nil unless face.respond_to?(:get_UVHelper)
      uvh = face.get_UVHelper(!use_back, use_back) rescue nil
      return nil unless uvh

      points = []
      verts.each do |v|
        lp = v.position
        uvq = use_back ? (uvh.get_back_UVQ(lp) rescue nil) : (uvh.get_front_UVQ(lp) rescue nil)
        next unless uvq && uvq.z.abs > 1e-10
        u  = uvq.x / uvq.z
        vc = uvq.y / uvq.z
        wp = lp.transform(xform)
        wx, wy = su_to_pdf(wp.x, wp.y)
        points << [u, vc, wx, wy]
      end
      return nil if points.length < 3

      # Fix the first point and search the rest for a non-collinear pair
      p1 = points[0]
      (1...points.length).each do |i|
        (i + 1...points.length).each do |j|
          m = solve_affine(p1, points[i], points[j])
          return m if m
        end
      end
      nil
    end
    private_class_method :compute_uv_matrix

    # Compute a 6-parameter affine [A B C D Tx Ty] from three [u,v,Wx,Wy] points.
    # Wx = A·u + C·v + Tx,  Wy = B·u + D·v + Ty
    def self.solve_affine(p1, p2, p3)
      u1, v1, wx1, wy1 = p1
      u2, v2, wx2, wy2 = p2
      u3, v3, wx3, wy3 = p3

      du2 = u2 - u1;  dv2 = v2 - v1
      du3 = u3 - u1;  dv3 = v3 - v1
      dwx2 = wx2 - wx1; dwy2 = wy2 - wy1
      dwx3 = wx3 - wx1; dwy3 = wy3 - wy1

      det = du2 * dv3 - dv2 * du3
      return nil if det.abs < 1e-6

      a = (dwx2 * dv3 - dwx3 * dv2) / det
      c = (du2 * dwx3 - du3 * dwx2) / det
      b = (dwy2 * dv3 - dwy3 * dv2) / det
      d = (du2 * dwy3 - du3 * dwy2) / det

      tx = wx1 - a * u1 - c * v1
      ty = wy1 - b * u1 - d * v1

      [a, b, c, d, tx, ty]
    end
    private_class_method :solve_affine

    # Cache one ExtGState per alpha value so identical alphas share a resource
    def self.get_or_create_gs(alpha)
      return nil if alpha >= 0.999   # fully opaque → no ExtGState needed
      key = alpha.round(3)
      name = @ext_gstates[key]
      unless name
        name = "GS#{@gs_idx}"
        @gs_idx += 1
        @ext_gstates[key] = name
      end
      name
    end
    private_class_method :get_or_create_gs

    # Extracts texture image to a temp file; returns path or nil.
    def self.texture_file_for_mat(mat)
      return nil unless mat && mat.respond_to?(:texture) && mat.texture
      tex  = mat.texture
      orig = tex.filename.to_s
      return orig if orig.length > 0 && File.exist?(orig)

      if tex.respond_to?(:image_rep)
        ext    = File.extname(orig).downcase
        ext    = '.png' unless ['.jpg', '.jpeg', '.png'].include?(ext)
        safe   = mat.name.to_s.gsub(/[^a-zA-Z0-9]/i, '_')[0, 40]
        tmpdir = ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir rescue '/tmp'
        dest   = File.join(tmpdir, "sd_tex_#{safe}#{ext}")
        unless File.exist?(dest)
          rep = tex.image_rep
          rep.save_file(dest) if rep && rep.respond_to?(:save_file)
        end
        return dest if File.exist?(dest)
      end

      nil
    rescue => e
      log "  [texture] extract failed: #{e.message}"
      nil
    end
    private_class_method :texture_file_for_mat

    # ── Edge (line) ───────────────────────────────────────────────────────
    def self.emit_edge(edge, xform, ebuf, parent_mat = nil)
      return if edge.hidden?
      return if edge.respond_to?(:soft?) && edge.soft?
      r, g, b = edge_rgb(edge, parent_mat)
      p1 = edge.start.position.transform(xform)
      p2 = edge.end.position.transform(xform)
      x1, y1 = su_to_pdf(p1.x, p1.y)
      x2, y2 = su_to_pdf(p2.x, p2.y)

      dash     = edge_dash_array(edge)
      has_dots = dash && dash.any? { |v| v == 0 }
      lw       = has_dots ? 0.8 : 0.5   # thin (0.5pt≈0.18mm ISO thin; dot patterns get 0.8pt so dots stay visible)
      cap      = has_dots ? 1   : 0     # 1 = round cap (circular dots), 0 = butt cap (square dash ends)

      # Compute a dash phase so the pattern is symmetric across the line.
      # Centering the first dash element on the line midpoint yields left/right symmetry.
      dash_phase = 0.0
      if dash
        period = dash.inject(0.0) { |s, v| s + v }
        if period > 0.001
          line_len = Math.sqrt((x2 - x1)**2 + (y2 - y1)**2)
          dash_phase = ((dash[0] / 2.0) - (line_len / 2.0)) % period
          dash_phase = 0.0 if dash_phase.nan? || dash_phase.infinite?
        end
      end

      dash_cmd = dash ? "[#{dash.map { |v| fn(v) }.join(' ')}] #{fn(dash_phase)} d" : '[] 0 d'
      ebuf << "#{fn(r)} #{fn(g)} #{fn(b)} RG #{fn(lw)} w #{cap} J #{dash_cmd} " \
              "#{fn(x1)} #{fn(y1)} m #{fn(x2)} #{fn(y2)} l S\n"
    end
    private_class_method :emit_edge

    # Returns [r, g, b] for an edge.
    # Priority: edge's own material → parent_edge_mat (edge-only decorative groups only) → named layer → black.
    # parent_edge_mat is only passed by emit_group when the containing group is edge-only.
    # A structural group's face material is NOT inherited by edges, matching SketchUp's default look.
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

    # Returns PDF dash array for the edge's line style, or nil for solid.
    def self.edge_dash_array(edge)
      style_name = nil
      if edge.respond_to?(:line_style) && (ls = edge.line_style)
        style_name = ls.respond_to?(:name) ? ls.name : ls.to_s
      end
      style_name ||= layer_line_style_name(edge.layer)
      return nil unless style_name && !style_name.empty?

      # Exact match: covers all 12 built-in SketchUp line styles
      return STYLE_MAP[style_name] if STYLE_MAP.key?(style_name)

      # Regex fallback: for any custom/imported style name
      log "  [dash] unknown style #{style_name.inspect} — using regex fallback"
      DASH_FALLBACK.each { |rx, arr| return arr if style_name =~ rx }
      nil
    rescue
      nil
    end
    private_class_method :edge_dash_array

    def self.layer_line_style_name(layer)
      return nil unless layer
      ls = layer.line_style if layer.respond_to?(:line_style)
      return nil unless ls
      ls.respond_to?(:name) ? ls.name : ls.to_s
    rescue
      nil
    end
    private_class_method :layer_line_style_name

    # ── Dimension linear ──────────────────────────────────────────────────
    def self.emit_dimension(dim, xform, ebuf)
      raw1 = dim.start
      raw2 = dim.end
      pt1  = dim_endpoint(raw1)
      pt2  = dim_endpoint(raw2)
      return unless pt1 && pt2

      pt1 = pt1.transform(xform)
      pt2 = pt2.transform(xform)

      off = if dim.respond_to?(:offset_vector) then dim.offset_vector
            elsif dim.respond_to?(:offset)      then dim.offset
            else Geom::Vector3d.new(0, 0, 0) end
      off ||= Geom::Vector3d.new(0, 0, 0)

      d1  = Geom::Point3d.new(pt1.x + off.x, pt1.y + off.y, 0)
      d2  = Geom::Point3d.new(pt2.x + off.x, pt2.y + off.y, 0)
      x1,  y1  = su_to_pdf(pt1.x, pt1.y)
      xd1, yd1 = su_to_pdf(d1.x,  d1.y)
      x2,  y2  = su_to_pdf(pt2.x, pt2.y)
      xd2, yd2 = su_to_pdf(d2.x,  d2.y)
      ebuf << "0 0 0 RG 0.35 w [] 0 d #{fn(x1)} #{fn(y1)} m #{fn(xd1)} #{fn(yd1)} l S\n"
      ebuf << "0 0 0 RG 0.35 w [] 0 d #{fn(x2)} #{fn(y2)} m #{fn(xd2)} #{fn(yd2)} l S\n"
      ebuf << "0 0 0 RG 0.5 w [] 0 d #{fn(xd1)} #{fn(yd1)} m #{fn(xd2)} #{fn(yd2)} l S\n"
      label = dim.text.to_s.strip
      return if label.empty?
      mid_x = (xd1 + xd2) / 2.0
      mid_y = (yd1 + yd2) / 2.0 + 3.5
      register_font('Helvetica')
      fk = @used_fonts['Helvetica']
      ebuf << "BT /#{fk} 8 Tf 0 0 0 rg #{fn(mid_x)} #{fn(mid_y)} Td (#{pdf_escape(label)}) Tj ET\n"
    rescue => e
      log "  [dimension] ERROR: #{e.message}"
    end
    private_class_method :emit_dimension

    # Resolves dim.start / dim.end to Geom::Point3d across all SU versions.
    def self.dim_endpoint(raw)
      return raw[1] if raw.is_a?(Array) && raw[1].is_a?(Geom::Point3d)
      return raw     if raw.is_a?(Geom::Point3d)
      return raw.position if raw.respond_to?(:position)
      nil
    rescue
      nil
    end
    private_class_method :dim_endpoint

    # ── Coordinate / format helpers ───────────────────────────────────────
    def self.su_to_pdf(x, y)
      [(x - @fx0) * 72.0, (y - @fy0) * 72.0]
    end
    private_class_method :su_to_pdf

    def self.fn(v)
      format('%.4f', v.to_f).sub(/\.?0+$/, '')
    end
    private_class_method :fn

    def self.map_font(name)
      PDF_FONT_MAP[name.to_s] || 'Helvetica'
    end
    private_class_method :map_font

    def self.register_font(pdf_font)
      @used_fonts[pdf_font] ||= "F#{@used_fonts.size + 1}"
    end
    private_class_method :register_font

    def self.hex_rgb(hex)
      parts = hex.to_s.gsub('#', '').scan(/../)
      return [0.0, 0.0, 0.0] if parts.length < 3
      parts.first(3).map { |s| s.to_i(16) / 255.0 }
    end
    private_class_method :hex_rgb

    def self.mat_rgb(mat, default)
      if mat && mat.respond_to?(:color) && mat.color
        c = mat.color
        [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
      else
        [default, default, default]
      end
    end
    private_class_method :mat_rgb

    # Encode a Ruby string for a PDF Tj literal.
    # Uses Windows-1252 which matches the font's /Encoding /WinAnsiEncoding declaration
    # and covers characters such as • (bullet), – — (dashes), curly quotes, €, ©, ®, ™, etc.
    def self.pdf_escape(str)
      str.to_s
         .encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
         .gsub('\\', '\\\\')
         .gsub('(', '\\(')
         .gsub(')', '\\)')
         .b
    end
    private_class_method :pdf_escape

    # ── PDF binary assembly ───────────────────────────────────────────────
    def self.build_pdf(content_str)
      require 'zlib'
      log "build_pdf: compressing #{content_str.bytesize}b content..."
      cs = Zlib::Deflate.deflate(content_str.force_encoding('BINARY'), Zlib::BEST_COMPRESSION)
      log "build_pdf: compressed to #{cs.bytesize}b"

      next_id  = 5
      font_ids = {}
      @used_fonts.each { |pf, _| font_ids[pf] = next_id; next_id += 1 }
      log "build_pdf: fonts=#{font_ids.inspect}"

      img_ids   = {}
      smask_ids = {}   # img_key → SMask XObject id (only when alpha data is present)
      img_objs  = {}
      @images.each do |name, info|
        next unless info[:data] && info[:w].to_i > 0
        img_ids[name]  = next_id
        img_objs[name] = info
        log "build_pdf: image #{name} id=#{next_id} #{info[:w]}x#{info[:h]} #{info[:filter]} alpha=#{info[:alpha] ? 'yes' : 'no'}"
        next_id += 1
        if info[:alpha]
          smask_ids[name] = next_id
          log "build_pdf: SMask for #{name} id=#{next_id}"
          next_id += 1
        end
      end

      pat_ids = {}
      @patterns.each do |name, _|
        pat_ids[name] = next_id
        next_id += 1
      end

      gs_ids = {}
      @ext_gstates.each do |_alpha, name|
        gs_ids[name] = next_id
        next_id += 1
      end

      total = next_id - 1
      log "build_pdf: total objects=#{total}  ext_gstates=#{@ext_gstates.inspect}"

      font_res = @used_fonts.map { |pf, fk| "/#{fk} #{font_ids[pf]} 0 R" }.join(' ')
      xobj_res = img_ids.map    { |n,  id| "/#{n} #{id} 0 R" }.join(' ')
      pat_res  = pat_ids.map    { |n,  id| "/#{n} #{id} 0 R" }.join(' ')
      gs_res   = gs_ids.map     { |n,  id| "/#{n} #{id} 0 R" }.join(' ')

      res = String.new('', encoding: 'BINARY')
      res << "/Font << #{font_res} >> "     unless font_res.empty?
      res << "/XObject << #{xobj_res} >> "  unless xobj_res.empty?
      res << "/Pattern << #{pat_res} >> "   unless pat_res.empty?
      res << "/ExtGState << #{gs_res} >>"   unless gs_res.empty?
      log "build_pdf: Resources=#{res.inspect[0, 120]}"

      buf = String.new("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n", encoding: 'BINARY')
      off = {}

      off[1] = buf.bytesize
      buf << "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"

      off[2] = buf.bytesize
      buf << "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"

      off[3] = buf.bytesize
      page_dict = "3 0 obj\n<< /Type /Page /Parent 2 0 R " \
                  "/MediaBox [0 0 #{fn(@wpt)} #{fn(@hpt)}] " \
                  "/Contents 4 0 R /Resources << #{res} >> >>\nendobj\n"
      buf << page_dict

      off[4] = buf.bytesize
      buf << "4 0 obj\n<< /Length #{cs.bytesize} /Filter /FlateDecode >>\nstream\n"
      buf << cs
      buf << "\nendstream\nendobj\n"

      @used_fonts.each do |pf, _fk|
        id = font_ids[pf]
        off[id] = buf.bytesize
        buf << "#{id} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /#{pf} " \
               "/Encoding /WinAnsiEncoding >>\nendobj\n"
      end

      img_objs.each do |name, d|
        id = img_ids[name]
        off[id] = buf.bytesize
        smask_ref = d[:alpha] ? " /SMask #{smask_ids[name]} 0 R" : ""
        buf << "#{id} 0 obj\n" \
               "<< /Type /XObject /Subtype /Image /Width #{d[:w]} /Height #{d[:h]} " \
               "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /#{d[:filter]}#{smask_ref} " \
               "/Length #{d[:data].bytesize} >>\nstream\n"
        buf << d[:data]
        buf << "\nendstream\nendobj\n"

        # SMask (alpha mask) — 8-bit grayscale image built from the original PNG's alpha channel
        if d[:alpha]
          sid = smask_ids[name]
          off[sid] = buf.bytesize
          buf << "#{sid} 0 obj\n" \
                 "<< /Type /XObject /Subtype /Image /Width #{d[:w]} /Height #{d[:h]} " \
                 "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode " \
                 "/Length #{d[:alpha].bytesize} >>\nstream\n"
          buf << d[:alpha]
          buf << "\nendstream\nendobj\n"
        end
      end

      # Tiling Pattern objects.
      # BBox = [0 0 1 1] defines the unit tile that the image fills.
      # /Matrix [A B C D Tx Ty] carries the full UV→world transform (rotation, scale, translation, skew).
      @patterns.each do |name, info|
        id  = pat_ids[name]
        m   = info[:matrix]
        img = info[:img]
        iid = img_ids[img]
        pat_stream = "1 0 0 1 0 0 cm /#{img} Do\n"
        pat_b = pat_stream.b
        off[id] = buf.bytesize
        buf << "#{id} 0 obj\n"
        buf << "<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 2 "
        buf << "/BBox [0 0 1 1] /XStep 1 /YStep 1 "
        buf << "/Matrix [#{m.map { |v| fn(v) }.join(' ')}] "
        buf << "/Resources << /XObject << /#{img} #{iid} 0 R >> >> "
        buf << "/Length #{pat_b.bytesize} >>\n"
        buf << "stream\n"
        buf << pat_b
        buf << "\nendstream\nendobj\n"
      end

      # ExtGState (graphics state with alpha) — used for texture translucency
      @ext_gstates.each do |alpha, name|
        id = gs_ids[name]
        off[id] = buf.bytesize
        buf << "#{id} 0 obj\n<< /Type /ExtGState /ca #{fn(alpha)} /CA #{fn(alpha)} >>\nendobj\n"
      end

      xp = buf.bytesize
      buf << "xref\n0 #{total + 1}\n0000000000 65535 f \n"
      (1..total).each { |n| buf << format('%010d 00000 n ', off[n] || 0) << "\n" }
      buf << "trailer\n<< /Size #{total + 1} /Root 1 0 R >>\nstartxref\n#{xp}\n%%EOF\n"
      log "build_pdf: xref at #{xp}  total buf=#{buf.bytesize}b"
      buf
    end
    private_class_method :build_pdf

    # ── Image helpers ─────────────────────────────────────────────────────
    # Returns: [width, height, filter, rgb_payload, alpha_payload_or_nil]
    # If alpha_payload_or_nil is non-nil, an SMask XObject will be generated.
    def self.image_payload(raw, ext)
      log "  [image_payload] ext=#{ext} raw=#{raw.bytesize}b"
      if ['.jpg', '.jpeg'].include?(ext)
        w, h = jpeg_dims(raw)
        log "  [image_payload] JPEG dims: #{w}x#{h}"
        return [0, 0, nil, nil, nil] if w == 0
        [w, h, 'DCTDecode', raw, nil]   # JPEG has no alpha channel
      else
        w, h = png_dims(raw)
        log "  [image_payload] PNG dims: #{w}x#{h}"
        return [0, 0, nil, nil, nil] if w == 0
        log "  [image_payload] decoding PNG pixels..."
        rgb, alpha = png_to_rgba(raw, w, h)
        log "  [image_payload] raw RGB: #{rgb.bytesize}b (expected #{w*h*3}b)"
        rgb_comp = Zlib::Deflate.deflate(rgb, Zlib::BEST_COMPRESSION)
        log "  [image_payload] compressed RGB: #{rgb_comp.bytesize}b"
        alpha_comp = nil
        if alpha
          alpha_comp = Zlib::Deflate.deflate(alpha, Zlib::BEST_COMPRESSION)
          log "  [image_payload] compressed alpha: #{alpha_comp.bytesize}b"
        end
        [w, h, 'FlateDecode', rgb_comp, alpha_comp]
      end
    rescue => e
      log "  [image_payload] EXCEPTION: #{e.class}: #{e.message}"
      e.backtrace.first(4).each { |l| log "    #{l}" }
      [0, 0, nil, nil, nil]
    end
    private_class_method :image_payload

    def self.jpeg_dims(data)
      i = 2
      while i < data.bytesize - 4
        return [0, 0] unless data.getbyte(i) == 0xFF
        marker = data.getbyte(i + 1)
        len    = data[i + 2, 2].unpack1('n')
        if [0xC0, 0xC1, 0xC2, 0xC9].include?(marker)
          return [data[i + 7, 2].unpack1('n'), data[i + 5, 2].unpack1('n')]
        end
        i += 2 + len
      end
      [0, 0]
    end
    private_class_method :jpeg_dims

    def self.png_dims(data)
      return [0, 0] if data.bytesize < 24
      [data[16, 4].unpack1('N'), data[20, 4].unpack1('N')]
    end
    private_class_method :png_dims

    # PNG decoder — returns RGB and alpha data separately.
    # Returns: [rgb_bytes, alpha_bytes_or_nil]
    # - RGBA or grayscale+alpha PNG: alpha extracted as a separate grayscale stream
    # - Fully opaque (all alpha=255): alpha_bytes = nil (no SMask needed)
    # - RGB or grayscale PNG (no alpha channel): alpha_bytes = nil
    def self.png_to_rgba(data, pw, ph)
      require 'zlib'
      pos      = 8
      idat     = String.new('', encoding: 'BINARY')
      channels = 3
      while pos < data.bytesize
        len  = data[pos, 4].unpack1('N')
        type = data[pos + 4, 4]
        if type == 'IHDR'
          ct       = data[pos + 8 + 9, 1].unpack1('C') rescue 2
          channels = case ct
                     when 0 then 1
                     when 2 then 3
                     when 3 then 1
                     when 4 then 2
                     when 6 then 4
                     else 3
                     end
          log "  [png_to_rgba] IHDR: #{pw}x#{ph} color_type=#{ct} channels=#{channels}"
        end
        idat << data[pos + 8, len] if type == 'IDAT'
        pos += 12 + len
      end
      log "  [png_to_rgba] IDAT total: #{idat.bytesize}b, inflating..."
      raw       = Zlib::Inflate.inflate(idat)
      log "  [png_to_rgba] inflated: #{raw.bytesize}b (expected #{ph*(pw*channels+1)}b)"
      stride    = pw * channels
      out_rgb   = String.new('', encoding: 'BINARY')
      out_alpha = String.new('', encoding: 'BINARY')
      has_alpha = (channels == 2 || channels == 4)
      all_opaque = true
      prev      = "\x00".b * stride
      ph.times do |y|
        base   = y * (stride + 1)
        filter = raw.getbyte(base)
        row    = raw[base + 1, stride].bytes
        case filter
        when 1
          stride.times { |i| row[i] = (row[i] + (i >= channels ? row[i - channels] : 0)) & 0xFF }
        when 2
          pb = prev.bytes
          stride.times { |i| row[i] = (row[i] + pb[i]) & 0xFF }
        when 3
          pb = prev.bytes
          stride.times { |i|
            a = i >= channels ? row[i - channels] : 0
            row[i] = (row[i] + ((a + pb[i]) >> 1)) & 0xFF
          }
        when 4
          pb = prev.bytes
          stride.times { |i|
            a  = i >= channels ? row[i - channels] : 0
            b  = pb[i]
            c  = i >= channels ? pb[i - channels] : 0
            p2 = a + b - c
            pa = (p2 - a).abs; pb2 = (p2 - b).abs; pc = (p2 - c).abs
            pr = pa <= pb2 && pa <= pc ? a : pb2 <= pc ? b : c
            row[i] = (row[i] + pr) & 0xFF
          }
        end
        prev = row.pack('C*')
        rgb  = String.new('', encoding: 'BINARY')
        case channels
        when 4  # RGBA
          pw.times do |i|
            rgb << prev[i * 4, 3]
            av = prev.getbyte(i * 4 + 3)
            out_alpha << av.chr
            all_opaque = false if av < 255
          end
        when 2  # Grayscale + Alpha
          pw.times do |i|
            g  = prev[i * 2, 1]
            rgb << g << g << g
            av = prev.getbyte(i * 2 + 1)
            out_alpha << av.chr
            all_opaque = false if av < 255
          end
        when 1  # Grayscale (no alpha)
          pw.times { |i| g = prev[i, 1]; rgb << g << g << g }
        else    # RGB (no alpha)
          rgb = prev
        end
        out_rgb << rgb
      end
      final_alpha = (has_alpha && !all_opaque) ? out_alpha : nil
      log "  [png_to_rgba] alpha: #{final_alpha ? "#{final_alpha.bytesize}b (SMask generated)" : 'none (fully opaque or no alpha channel)'}"
      [out_rgb, final_alpha]
    end
    private_class_method :png_to_rgba
  end
end
