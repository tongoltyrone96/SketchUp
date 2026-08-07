module SketchDraw
  # ────────────────────────────────────────────────────────────────────
  # Feature: Hatches — fill selected face(s) with a standard drafting
  # pattern (concrete, diagonal, cross-hatch, brick, earth).
  #
  # Phase 1 (v5.51): toolbar button + dialog, stored settings on face.
  # Phase 2+3 (v5.52, this file): actual hatch line geometry generated
  # inside the face boundary, clipped to the polygon outline. Pattern
  # spacing scales with the current view via
  # SketchDraw::State.paper_scale_multiplier_at, so 3mm paper spacing
  # looks the same whether the face lives on a paper frame or a 17m
  # scaffold.
  #
  # Safety:
  #   • No observers, no timers, no viewport draws — the entire feature
  #     is inert until the user clicks the Hatch button.
  #   • MAX_LINES_PER_FACE caps runaway generation on huge faces so the
  #     model can never end up with 100k stray edges from one click.
  #   • Generated geometry lives in its own sub-group per face, tagged
  #     with attributes, so re-applying a pattern cleans up the old one
  #     and Undo works as a single step.
  # ────────────────────────────────────────────────────────────────────
  module Hatch
    ATTR_NS = SketchDraw::PLUGIN_ID

    PATTERNS = [
      { id: 'diagonal_45',  name: 'Diagonal 45°',           default_spacing: 3.0 },
      { id: 'cross_hatch',  name: 'Cross-hatch (45°)',      default_spacing: 4.0 },
      { id: 'concrete',     name: 'Concrete (dots)',        default_spacing: 6.0 },
      { id: 'brick',        name: 'Brick',                  default_spacing: 6.0 },
      { id: 'earth',        name: 'Earth / Ground',         default_spacing: 4.0 }
    ].freeze

    # ── Entry point ─────────────────────────────────────────────────
    def self.activate
      return unless SketchDraw.version_ok?
      sel   = Sketchup.active_model.selection
      faces = sel.grep(Sketchup::Face)
      if faces.empty?
        UI.messagebox('Select one or more FACES first, then click Hatch.')
        return
      end
      show_dialog(faces)
    end

    # ── Core apply logic ────────────────────────────────────────────
    # Saves the chosen pattern as attributes on each face and generates
    # the hatch line geometry inside the face boundary.
    def self.apply_hatch(faces, pattern_id, spacing_mm, angle_deg)
      SketchDraw::Debug.log('Hatch', "apply_hatch begin: faces=#{faces.length} pattern=#{pattern_id.inspect} spacing=#{spacing_mm} angle=#{angle_deg}")
      pattern_id = pattern_id.to_s
      valid_ids  = PATTERNS.map { |p| p[:id] }
      unless valid_ids.include?(pattern_id)
        SketchDraw::Debug.log('Hatch', "invalid pattern_id=#{pattern_id.inspect}, falling back to #{valid_ids.first}")
        pattern_id = valid_ids.first
      end

      spacing_mm = spacing_mm.to_f.clamp(0.5, 50.0)
      angle_deg  = angle_deg.to_f

      model = Sketchup.active_model
      model.start_operation('Apply Hatch', true)
      begin
        faces.each_with_index do |f, i|
          unless f.is_a?(Sketchup::Face) && f.valid?
            SketchDraw::Debug.log('Hatch', "face[#{i}] invalid or not a Face — skipping")
            next
          end
          SketchDraw::Debug.log('Hatch', "face[#{i}] valid, area=#{f.area rescue 'n/a'}")
          # Wipe any pre-existing hatch geometry for this face so a
          # re-apply doesn't stack patterns on top of each other.
          remove_existing_hatch_geometry(f)
          # Persist the pattern so PDF export / re-edit can rebuild it.
          f.set_attribute(ATTR_NS, 'hatch_pattern',     pattern_id)
          f.set_attribute(ATTR_NS, 'hatch_spacing_mm',  spacing_mm.round(3))
          f.set_attribute(ATTR_NS, 'hatch_angle_deg',   angle_deg.round(2))
          # Generate the visible hatch lines.
          n_before = f.parent.entities.length rescue 0
          HatchGenerator.generate(f, pattern_id, spacing_mm, angle_deg)
          n_after  = f.parent.entities.length rescue 0
          SketchDraw::Debug.log('Hatch', "face[#{i}] generate done, parent.entities: #{n_before} → #{n_after}")
        end
        model.commit_operation
        SketchDraw::Debug.log('Hatch', "apply_hatch committed")
      rescue => e
        model.abort_operation rescue nil
        SketchDraw::Debug.log('Hatch', "ERROR: #{e.class}: #{e.message}")
        (e.backtrace || []).first(4).each { |l| SketchDraw::Debug.log('Hatch', "  #{l}") }
        UI.messagebox("Hatch apply failed: #{e.class}: #{e.message}")
      end
    end

    # Remove the sub-group of hatch geometry previously attached to
    # `face`. Safe no-op if no hatch was applied before.
    def self.remove_existing_hatch_geometry(face)
      grp_id = face.get_attribute(ATTR_NS, 'hatch_geometry_id')
      return unless grp_id
      face.parent.entities.each do |ent|
        next unless ent.is_a?(Sketchup::Group)
        next unless ent.valid?
        if (ent.entityID == grp_id) ||
           (ent.get_attribute(ATTR_NS, 'owner_face_id') == face.entityID)
          ent.erase! rescue nil
        end
      end
      face.set_attribute(ATTR_NS, 'hatch_geometry_id', nil) rescue nil
    end

    # ── Dialog ──────────────────────────────────────────────────────
    def self.show_dialog(faces)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Hatch Pattern',
        preferences_key: 'SketchDraw_Hatch_v1',
        width:  380,
        height: 520,
        style:  UI::HtmlDialog::STYLE_DIALOG
      )

      patterns_json = PATTERNS.map { |p|
        %({id:"#{p[:id]}", name:"#{p[:name]}", spacing:#{p[:default_spacing]}})
      }.join(',')

      html = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          html, body { height: 100%; }
          body {
            font-family: Arial, sans-serif;
            background: #2b2b2b;
            color: #ddd;
            display: flex; flex-direction: column;
            overflow: hidden;
          }
          .content { flex: 1; overflow-y: auto; padding: 12px; }
          h4 { margin-bottom: 8px; font-size: 13px; color: #ccc; font-weight: bold; }
          .patterns { display: flex; flex-direction: column; gap: 5px; margin-bottom: 12px; }
          .pv {
            display: flex; align-items: center; gap: 12px;
            padding: 7px 10px;
            background: #3a3a3a;
            border: 1px solid #555;
            border-radius: 3px;
            cursor: pointer;
          }
          .pv:hover  { background: #4a4a4a; }
          .pv.active { background: #0078D4; border-color: #4aa3e6; }
          .pv .preview {
            width: 60px; height: 32px;
            background: #fff;
            border: 1px solid #666;
          }
          .pv .name { flex: 1; font-size: 12px; font-weight: bold; }
          .field-row { display: flex; align-items: center; gap: 8px; margin-top: 8px; }
          .field-row label { font-size: 12px; color: #aaa; width: 110px; }
          .field-row input {
            flex: 1;
            padding: 6px 10px;
            background: #1e1e1e; color: #fff;
            border: 1px solid #555; border-radius: 3px;
            font-size: 13px;
          }
          .hint { font-size: 11px; color: #888; margin-top: 10px; line-height: 1.4; }
          .footer {
            flex-shrink: 0;
            display: flex; justify-content: flex-end; gap: 8px;
            padding: 10px 12px;
            border-top: 1px solid #444;
            background: #232323;
          }
          button {
            padding: 8px 22px;
            background: #0078D4; color: #fff;
            border: none; border-radius: 3px;
            font-size: 12px; font-weight: bold;
            cursor: pointer;
          }
          button.cancel { background: #505050; }
          button:hover { filter: brightness(1.15); }
        </style>
        </head>
        <body>
          <div class="content">
            <h4>Pattern</h4>
            <div class="patterns" id="patterns"></div>

            <h4>Spacing &amp; angle</h4>
            <div class="field-row">
              <label>Spacing (paper mm):</label>
              <input type="number" id="spacing" step="0.5" min="0.5" max="50" value="3">
            </div>
            <div class="field-row">
              <label>Angle (deg):</label>
              <input type="number" id="angle" step="5" min="-90" max="90" value="45">
            </div>

            <div class="hint">
              The pattern is generated inside the face boundary. Spacing
              scales with the drawing view — the same 3mm spacing looks
              right whether you're inside a paper frame or on a metre-scale
              scaffold. Applying the tool again on the same face replaces
              the previous pattern.
            </div>
          </div>

          <div class="footer">
            <button class="cancel" onclick="sketchup.cancel()">Cancel</button>
            <button onclick="apply()">Apply</button>
          </div>

        <script>
          var PATTERNS = [#{patterns_json}];
          var chosen = PATTERNS[0].id;

          function svgFor(id) {
            switch (id) {
              case 'diagonal_45':
                return '<svg viewBox="0 0 60 32" width="60" height="32"><line x1="0" y1="32" x2="32" y2="0" stroke="black" stroke-width="1"/><line x1="15" y1="32" x2="47" y2="0" stroke="black" stroke-width="1"/><line x1="30" y1="32" x2="62" y2="0" stroke="black" stroke-width="1"/></svg>';
              case 'cross_hatch':
                return '<svg viewBox="0 0 60 32" width="60" height="32"><line x1="0" y1="32" x2="32" y2="0" stroke="black" stroke-width="1"/><line x1="15" y1="32" x2="47" y2="0" stroke="black" stroke-width="1"/><line x1="30" y1="32" x2="62" y2="0" stroke="black" stroke-width="1"/><line x1="0" y1="0" x2="32" y2="32" stroke="black" stroke-width="1"/><line x1="15" y1="0" x2="47" y2="32" stroke="black" stroke-width="1"/><line x1="30" y1="0" x2="62" y2="32" stroke="black" stroke-width="1"/></svg>';
              case 'concrete':
                return '<svg viewBox="0 0 60 32" width="60" height="32"><circle cx="8" cy="8" r="1" fill="black"/><circle cx="22" cy="10" r="1" fill="black"/><circle cx="38" cy="6" r="1" fill="black"/><circle cx="50" cy="14" r="1" fill="black"/><circle cx="12" cy="22" r="1" fill="black"/><circle cx="30" cy="24" r="1" fill="black"/><circle cx="46" cy="26" r="1" fill="black"/></svg>';
              case 'brick':
                return '<svg viewBox="0 0 60 32" width="60" height="32"><line x1="0" y1="10" x2="60" y2="10" stroke="black" stroke-width="1"/><line x1="0" y1="22" x2="60" y2="22" stroke="black" stroke-width="1"/><line x1="15" y1="10" x2="15" y2="22" stroke="black" stroke-width="1"/><line x1="35" y1="10" x2="35" y2="22" stroke="black" stroke-width="1"/><line x1="55" y1="10" x2="55" y2="22" stroke="black" stroke-width="1"/><line x1="5" y1="0" x2="5" y2="10" stroke="black" stroke-width="1"/><line x1="25" y1="0" x2="25" y2="10" stroke="black" stroke-width="1"/><line x1="45" y1="0" x2="45" y2="10" stroke="black" stroke-width="1"/><line x1="5" y1="22" x2="5" y2="32" stroke="black" stroke-width="1"/><line x1="25" y1="22" x2="25" y2="32" stroke="black" stroke-width="1"/><line x1="45" y1="22" x2="45" y2="32" stroke="black" stroke-width="1"/></svg>';
              case 'earth':
                return '<svg viewBox="0 0 60 32" width="60" height="32"><line x1="0" y1="32" x2="16" y2="16" stroke="black" stroke-width="1"/><line x1="16" y1="32" x2="32" y2="16" stroke="black" stroke-width="1"/><line x1="32" y1="32" x2="48" y2="16" stroke="black" stroke-width="1"/><line x1="48" y1="32" x2="60" y2="20" stroke="black" stroke-width="1"/><line x1="8" y1="16" x2="24" y2="0" stroke="black" stroke-width="1"/><line x1="24" y1="16" x2="40" y2="0" stroke="black" stroke-width="1"/><line x1="40" y1="16" x2="56" y2="0" stroke="black" stroke-width="1"/></svg>';
              default: return '';
            }
          }

          function render() {
            var box = document.getElementById('patterns');
            box.innerHTML = '';
            PATTERNS.forEach(function(p) {
              var el = document.createElement('div');
              el.className = 'pv' + (p.id === chosen ? ' active' : '');
              el.innerHTML =
                '<div class="preview">' + svgFor(p.id) + '</div>' +
                '<div class="name">' + p.name + '</div>';
              el.onclick = function() {
                chosen = p.id;
                document.getElementById('spacing').value = p.spacing;
                render();
              };
              box.appendChild(el);
            });
          }

          function apply() {
            var spacing = parseFloat(document.getElementById('spacing').value);
            var angle   = parseFloat(document.getElementById('angle').value);
            if (isNaN(spacing) || spacing <= 0) spacing = 3;
            if (isNaN(angle)) angle = 45;
            sketchup.apply_hatch(chosen, spacing, angle);
          }

          render();
        </script>
        </body>
        </html>
      HTML

      dlg.set_html(html)

      dlg.add_action_callback('apply_hatch') do |_ctx, pattern_id, spacing, angle|
        apply_hatch(faces, pattern_id, spacing, angle)
        dlg.close
      end
      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end
    private_class_method :show_dialog
  end

  # ────────────────────────────────────────────────────────────────────
  # HatchGenerator — produces the actual line geometry for a face given
  # the pattern id, paper-mm spacing, and angle. Runs only when the user
  # clicks Apply; performs zero work otherwise.
  # ────────────────────────────────────────────────────────────────────
  module HatchGenerator
    ATTR_NS = SketchDraw::PLUGIN_ID

    # Hard cap so a single Apply on a huge face can never spam SketchUp
    # with tens of thousands of edges (would freeze the app the same way
    # the chain-dot bug did before v5.48).
    MAX_LINES_PER_FACE = 500

    def self.generate(face, pattern_id, spacing_mm, angle_deg)
      return unless face && face.valid?
      model = Sketchup.active_model
      # Scale the paper spacing to world size using the current view. The
      # same helper Text/Arrow/Section already use — inside a paper frame
      # the multiplier is 1.0 so paper output is unchanged.
      paper_mult = SketchDraw::State.paper_scale_multiplier_at(model, face.bounds.center)
      spacing = spacing_mm.mm * paper_mult
      SketchDraw::Debug.log('HatchGen', "pattern=#{pattern_id} spacing_mm=#{spacing_mm} paper_mult=#{paper_mult} spacing_world=#{spacing}")
      if spacing <= 0.001
        SketchDraw::Debug.log('HatchGen', "spacing too small (#{spacing}), aborting")
        return
      end

      # One sub-group per face holds all its hatch edges. Tagging makes
      # PDF export / re-apply / cleanup easy.
      parent_ents = face.parent.entities
      grp = parent_ents.add_group
      grp.name = "SKD_Hatch_#{face.entityID}"
      grp.set_attribute(ATTR_NS, 'type',          'hatch_geometry')
      grp.set_attribute(ATTR_NS, 'owner_face_id', face.entityID)
      face.set_attribute(ATTR_NS, 'hatch_geometry_id', grp.entityID)

      # Pre-compute polygon geometry for clipping. Faces on a scaffold
      # top view are Z=0, so 2D XY is enough. Nested / rotated faces
      # will get proper UV projection in a later phase.
      outer_poly  = face.outer_loop.vertices.map { |v| [v.position.x, v.position.y] }
      inner_polys = face.loops.reject { |l| l.equal?(face.outer_loop) }.map { |l|
        l.vertices.map { |v| [v.position.x, v.position.y] }
      }
      SketchDraw::Debug.log('HatchGen', "outer_poly verts=#{outer_poly.length} inner_polys=#{inner_polys.length} bbox=#{face.bounds.min.to_a}..#{face.bounds.max.to_a}")

      case pattern_id.to_s
      when 'diagonal_45'
        gen_parallel_lines(grp, face, outer_poly, inner_polys, spacing, angle_deg)
      when 'cross_hatch'
        gen_parallel_lines(grp, face, outer_poly, inner_polys, spacing,  45.0)
        gen_parallel_lines(grp, face, outer_poly, inner_polys, spacing, -45.0)
      when 'concrete'
        gen_concrete_dots(grp, face, outer_poly, inner_polys, spacing)
      when 'brick'
        gen_brick_pattern(grp, face, outer_poly, inner_polys, spacing)
      when 'earth'
        gen_earth_pattern(grp, face, outer_poly, inner_polys, spacing)
      end

      edges_added = grp.entities.grep(Sketchup::Edge).length rescue 0
      faces_auto  = grp.entities.grep(Sketchup::Face).length rescue 0
      SketchDraw::Debug.log('HatchGen', "after generate: edges=#{edges_added} auto_faces=#{faces_auto}")
      # SketchUp auto-forms faces whenever a closed edge loop appears
      # inside a group — for brick/cross-hatch this can create dozens of
      # tiny hatch-cell faces. Wipe them so only the hatch edges remain.
      grp.entities.grep(Sketchup::Face).each { |f2| f2.erase! rescue nil }
    rescue => e
      SketchDraw::Debug.log('HatchGen', "ERROR: #{e.class}: #{e.message}")
      (e.backtrace || []).first(4).each { |l| SketchDraw::Debug.log('HatchGen', "  #{l}") }
    end

    # Parallel lines at `angle_deg`, spaced `spacing` apart in world
    # units, covering the face's XY bounding box, each clipped to the
    # polygon interior.
    def self.gen_parallel_lines(grp, face, outer_poly, inner_polys, spacing, angle_deg)
      bbox = face.bounds
      angle_rad = angle_deg * Math::PI / 180.0
      dir_x  = Math.cos(angle_rad)
      dir_y  = Math.sin(angle_rad)
      norm_x = -dir_y
      norm_y =  dir_x

      # Project bbox corners onto the normal to find the range of offsets
      # we need to cover with parallel lines.
      corners = [
        [bbox.min.x, bbox.min.y], [bbox.max.x, bbox.min.y],
        [bbox.max.x, bbox.max.y], [bbox.min.x, bbox.max.y]
      ]
      projs = corners.map { |c| c[0] * norm_x + c[1] * norm_y }
      min_p = projs.min
      max_p = projs.max
      # Snap min to nearest spacing multiple below, so pattern origin is
      # deterministic across faces (helps re-applies overlay cleanly).
      min_p = (min_p / spacing).floor * spacing

      # v5.68 fix: anchor the parametric base point at the bbox centre
      # instead of the world origin. Previous version put the base at
      # (norm_x*offset, norm_y*offset), which sits on the normal line
      # through the ORIGIN — fine for a small face near (0,0) but the
      # line span (bbox diag) is far too short to reach the face when
      # the paper-frame page pushes coordinates to (391..400, 1139..1146)
      # like this scaffolding drawing does. Every candidate line landed
      # 700+ mm away from the polygon → clipper returned 0 segments
      # (log: "clip_calls=28 lines_added=0" for diagonal_45).
      # Anchoring at the bbox centre keeps the base point ON the face
      # so the same short span always straddles it.
      cx = (bbox.min.x + bbox.max.x) * 0.5
      cy = (bbox.min.y + bbox.max.y) * 0.5
      center_offset = cx * norm_x + cy * norm_y

      # Span only needs to cover the bbox diagonal now that we anchor
      # near the face — add spacing*2 slack so edge-of-bbox lines still
      # cross the polygon after the floor() snap.
      diag = Math.sqrt((bbox.max.x - bbox.min.x)**2 + (bbox.max.y - bbox.min.y)**2)
      span = diag + spacing * 2.0

      count = 0
      clip_calls = 0
      offset = min_p
      while offset <= max_p + spacing
        # Shift the (offset-from-origin) line so its base sits on the
        # bbox centre rather than on the perpendicular from origin.
        rel = offset - center_offset
        bx = cx + rel * norm_x
        by = cy + rel * norm_y
        p1 = [bx - dir_x * span, by - dir_y * span]
        p2 = [bx + dir_x * span, by + dir_y * span]
        segs = HatchClip.clip_line_to_polygon(p1, p2, outer_poly, inner_polys)
        clip_calls += 1
        segs.each do |seg|
          break if count >= MAX_LINES_PER_FACE
          add_edge(grp, seg[0], seg[1])
          count += 1
        end
        break if count >= MAX_LINES_PER_FACE
        offset += spacing
      end
      SketchDraw::Debug.log('HatchGen', "gen_parallel_lines angle=#{angle_deg} projs=#{min_p.round(3)}..#{max_p.round(3)} span=#{span.round(3)} center=(#{cx.round(2)},#{cy.round(2)}) clip_calls=#{clip_calls} lines_added=#{count}")
    end

    # Small cross at each grid intersection inside the polygon.
    def self.gen_concrete_dots(grp, face, outer_poly, inner_polys, spacing)
      bbox = face.bounds
      # Half-length of each dot cross-arm.
      arm = [spacing * 0.08, 0.5.mm].max
      count = 0
      y = (bbox.min.y / spacing).floor * spacing
      while y <= bbox.max.y
        x = (bbox.min.x / spacing).floor * spacing
        while x <= bbox.max.x
          if HatchClip.point_in_polygon?([x, y], outer_poly, inner_polys)
            add_edge(grp, [x - arm, y], [x + arm, y])
            add_edge(grp, [x, y - arm], [x, y + arm])
            count += 2
            break if count >= MAX_LINES_PER_FACE
          end
          x += spacing
        end
        break if count >= MAX_LINES_PER_FACE
        y += spacing
      end
    end

    # Brick pattern: horizontal rows + staggered verticals every other
    # row. Row height = spacing, brick width = 2 * spacing.
    def self.gen_brick_pattern(grp, face, outer_poly, inner_polys, spacing)
      bbox = face.bounds
      brick_w = spacing * 2.0
      count = 0
      # Long horizontal span for clipping.
      span = (bbox.max.x - bbox.min.x).abs + spacing

      row_index = 0
      y = (bbox.min.y / spacing).floor * spacing
      while y <= bbox.max.y
        # Horizontal row line at y
        segs = HatchClip.clip_line_to_polygon(
          [bbox.min.x - span, y], [bbox.max.x + span, y], outer_poly, inner_polys
        )
        segs.each do |seg|
          break if count >= MAX_LINES_PER_FACE
          add_edge(grp, seg[0], seg[1])
          count += 1
        end
        # Vertical brick joints on this row (from y to y + spacing).
        offset = row_index.odd? ? brick_w * 0.5 : 0.0
        x = (bbox.min.x / brick_w).floor * brick_w + offset
        while x <= bbox.max.x
          segs = HatchClip.clip_line_to_polygon(
            [x, y], [x, y + spacing], outer_poly, inner_polys
          )
          segs.each do |seg|
            break if count >= MAX_LINES_PER_FACE
            add_edge(grp, seg[0], seg[1])
            count += 1
          end
          x += brick_w
          break if count >= MAX_LINES_PER_FACE
        end
        break if count >= MAX_LINES_PER_FACE
        y += spacing
        row_index += 1
      end
    end

    # Earth pattern: repeating horizontal rows, each with a series of
    # short 45° tick marks pointing up-left (standard geotechnical fill).
    def self.gen_earth_pattern(grp, face, outer_poly, inner_polys, spacing)
      bbox = face.bounds
      tick = spacing * 0.5
      row_step = spacing * 1.4
      count = 0

      y = (bbox.min.y / row_step).floor * row_step
      while y <= bbox.max.y
        # Horizontal base line
        segs = HatchClip.clip_line_to_polygon(
          [bbox.min.x - spacing, y], [bbox.max.x + spacing, y], outer_poly, inner_polys
        )
        segs.each do |seg|
          break if count >= MAX_LINES_PER_FACE
          add_edge(grp, seg[0], seg[1])
          count += 1
        end
        # Tick marks pointing up-left from the row line
        x = (bbox.min.x / spacing).floor * spacing
        while x <= bbox.max.x
          x2 = x - tick * 0.7071
          y2 = y + tick * 0.7071
          if HatchClip.point_in_polygon?([(x + x2) * 0.5, (y + y2) * 0.5], outer_poly, inner_polys)
            add_edge(grp, [x, y], [x2, y2])
            count += 1
            break if count >= MAX_LINES_PER_FACE
          end
          x += spacing * 1.2
        end
        break if count >= MAX_LINES_PER_FACE
        y += row_step
      end
    end

    # Add a 2D edge to the hatch group at Z=0. Marks each edge with a
    # `hatch_edge` attribute so PDF export / cleanup can identify them
    # cheaply (no scene walk needed).
    def self.add_edge(grp, p1, p2)
      return if (p1[0] - p2[0]).abs < 1e-6 && (p1[1] - p2[1]).abs < 1e-6
      e = grp.entities.add_line(
        Geom::Point3d.new(p1[0], p1[1], 0),
        Geom::Point3d.new(p2[0], p2[1], 0)
      )
      e.set_attribute(ATTR_NS, 'hatch_edge', true) if e && e.respond_to?(:set_attribute)
      e
    rescue
      nil
    end
    private_class_method :add_edge
  end

  # ────────────────────────────────────────────────────────────────────
  # HatchClip — 2D polygon clipping for hatch lines. Works on Z=0
  # polygons (scaffold top-view faces). Inner loops are treated as
  # holes: a point inside a hole is considered outside the fill area.
  # ────────────────────────────────────────────────────────────────────
  module HatchClip
    EPSILON = 1.0e-9

    # True if `pt` lies inside the outer polygon and NOT inside any inner
    # hole. Uses ray-casting (Jordan curve theorem).
    def self.point_in_polygon?(pt, outer, inners = [])
      return false unless ray_cast_inside?(pt, outer)
      inners.each { |hole| return false if ray_cast_inside?(pt, hole) }
      true
    end

    def self.ray_cast_inside?(pt, poly)
      x, y = pt
      n = poly.length
      return false if n < 3
      inside = false
      j = n - 1
      i = 0
      while i < n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y)
          slope = (xj - xi).to_f / ((yj - yi).abs < EPSILON ? EPSILON : (yj - yi))
          xt = xi + slope * (y - yi)
          inside = !inside if x < xt
        end
        j = i
        i += 1
      end
      inside
    end

    # Clip a hatch line segment (pt1..pt2) against the polygon. Returns
    # an array of [p_start, p_end] pairs representing the parts of the
    # line INSIDE the polygon (with holes subtracted).
    def self.clip_line_to_polygon(pt1, pt2, outer, inners = [])
      dx = pt2[0] - pt1[0]
      dy = pt2[1] - pt1[1]
      len_sq = dx * dx + dy * dy
      return [] if len_sq < EPSILON

      # Gather intersection parameters along pt1→pt2 from all polygon
      # edges (outer + holes). t ∈ [0, 1] means the intersection lies on
      # the hatch segment.
      params = []
      each_edge(outer, inners) do |v1, v2|
        t = segment_intersect_param(pt1, dx, dy, len_sq, v1, v2)
        params << t if t
      end

      # Boundary points (t=0 and t=1) count too when they're inside.
      params << 0.0 if point_in_polygon?(pt1, outer, inners)
      params << 1.0 if point_in_polygon?(pt2, outer, inners)

      params.sort!
      params = dedupe(params, 1.0e-6)
      return [] if params.length < 2

      # Pair consecutive t-values; keep the segment only if its midpoint
      # is inside — handles concave outlines cleanly.
      out = []
      i = 0
      while i < params.length - 1
        t_a = params[i]
        t_b = params[i + 1]
        if t_b - t_a > 1.0e-6
          mid_t = (t_a + t_b) * 0.5
          mid = [pt1[0] + mid_t * dx, pt1[1] + mid_t * dy]
          if point_in_polygon?(mid, outer, inners)
            pa = [pt1[0] + t_a * dx, pt1[1] + t_a * dy]
            pb = [pt1[0] + t_b * dx, pt1[1] + t_b * dy]
            out << [pa, pb]
          end
        end
        i += 1
      end
      out
    end

    # Iterate every polygon edge (outer + each inner hole).
    def self.each_edge(outer, inners)
      [outer].concat(inners).each do |poly|
        n = poly.length
        next if n < 2
        i = 0
        while i < n
          yield poly[i], poly[(i + 1) % n]
          i += 1
        end
      end
    end

    # Compute the parameter `t` along the hatch segment pt1 + t*(dx,dy)
    # where it crosses the polygon edge v1→v2. Returns nil if there is
    # no crossing (parallel, or intersection lies off the polygon edge).
    def self.segment_intersect_param(pt1, dx, dy, len_sq, v1, v2)
      ex = v2[0] - v1[0]
      ey = v2[1] - v1[1]
      denom = dx * ey - dy * ex
      return nil if denom.abs < EPSILON
      rx = v1[0] - pt1[0]
      ry = v1[1] - pt1[1]
      t = (rx * ey - ry * ex) / denom     # parameter along hatch line
      s = (rx * dy - ry * dx) / denom     # parameter along polygon edge
      # Only count if the intersection lies on the polygon edge segment.
      # `t` may fall outside [0,1] because the hatch line is intentionally
      # extended past the bbox; we let it through here and let the segment
      # pairing above use the clamped params.
      return nil if s < -EPSILON || s > 1.0 + EPSILON
      t.clamp(0.0, 1.0)
    end

    def self.dedupe(sorted, eps)
      return sorted if sorted.length < 2
      out = [sorted[0]]
      i = 1
      while i < sorted.length
        out << sorted[i] if (sorted[i] - out.last).abs > eps
        i += 1
      end
      out
    end
  end
end
