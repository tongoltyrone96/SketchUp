module SketchDraw
  # This file previously hosted a `ColourOverlay` that painted every plugin-
  # coloured edge over the top of SketchUp's viewport. That was necessary on
  # older SketchUp builds where a standalone edge wouldn't take its material
  # colour, but SketchUp 2019+ renders material colours on standalone edges
  # natively as long as `EdgeColorMode = 1` is set (which ColourPicker does
  # on first Apply). The overlay had become pure overhead:
  #
  #   • it repainted thousands of edges every frame (screen_coords per vertex)
  #   • made Apply Colour feel laggy — the whole overlay rebuilt on the
  #     callback thread while the user was waiting for the dialog to close
  #   • caused the "black flash" during camera drags — every zoom hid the
  #     overlay, exposing the SU-native rendering that used to look identical
  #     but felt like a colour drop-out to the user
  #   • invalidated a global screen-batch cache on every Apply, so unrelated
  #     coloured edges LOOKED like they'd changed even when they hadn't
  #
  # ColourPicker still creates SKD_col_ materials and turns EdgeColorMode on;
  # SketchUp's own renderer handles the actual display. This file now only
  # contains ThicknessOverlay, which is still needed because SU can't render
  # per-edge stroke widths natively.

  # ────────────────────────────────────────────────────────────────────
  # ThicknessOverlay — dedicated, lightweight viewport preview for the
  # Line Thickness feature.
  #
  # Only edges carrying the `line_width_mm` attribute are ever cached. The
  # typical user selects under a hundred edges, so both the one-time cache
  # build and the per-frame redraw stay in the sub-millisecond range even
  # on huge models.
  # ────────────────────────────────────────────────────────────────────
  class ThicknessOverlay < Sketchup::Overlay
    OVERLAY_ID = 'sketchdraw.thickness_preview'.freeze

    # Dash cadence (screen-pixel units) for each SketchUp Line-Style.
    # `nil` = solid, no segmentation. The rest are `[dash, gap, dash, gap…]`
    # arrays that repeat along the edge. Values chosen to visually match
    # SketchUp's own native dash rendering on the same edge, so a Thick
    # overlay stroke lines up with the thin native pattern beneath it
    # (rather than drifting out of phase like GL line_stipple did — GL
    # scales its pattern by line-width, so a 4px-thick overlay stipple
    # ends up ~4× longer than the 1px native dashes, which is what caused
    # the "깨진" cadence in v5.58/5.59).
    #
    # Rendering is pixel-space in `rebuild_screen_batches`, so patterns
    # remain constant on screen regardless of zoom — exactly like SU.
    STYLE_DASH_PATTERN = {
      'Solid Basic'            => nil,
      'Short dash'             => [4, 2],
      'Dash'                   => [8, 3],
      'Dot'                    => [1, 3],
      'Dash dot'               => [10, 3, 1, 3],
      'Dash double-dot'        => [10, 3, 1, 3, 1, 3],
      'Dash triple-dot'        => [10, 3, 1, 3, 1, 3, 1, 3],
      'Double-dash dot'        => [10, 3, 10, 3, 1, 3],
      'Double-dash double-dot' => [10, 3, 10, 3, 1, 3, 1, 3],
      'Double-dash triple-dot' => [10, 3, 10, 3, 1, 3, 1, 3, 1, 3],
      'Long-dash dash'         => [15, 3, 5, 3],
      'Long-dash double-dash'  => [15, 3, 5, 3, 5, 3]
    }.freeze

    def initialize
      super(OVERLAY_ID, 'SketchDraw - Line Thickness Preview')
      @cache                = nil
      @cache_key            = nil
      @screen_batches       = nil
      @screen_dash_batches  = nil
      @screen_cover_batches = nil
      @screen_batches_cam   = nil
      @screen_batches_sel   = nil
      @error_logged         = false
    end

    def invalidate_cache
      @cache                = nil
      @screen_batches       = nil
      @screen_dash_batches  = nil
      @screen_cover_batches = nil
    end

    def draw(view)
      model = view.model
      return unless model

      # No camera-move skip here — Thickness caches are small (< 50 edges
      # in typical use), so drawing every frame costs sub-millisecond and
      # eliminates the "have to click the screen to see thickness" bug.
      # Previously the first stable frame after a zoom or pan was being
      # dropped because it still counted as a camera change vs. the last
      # drag frame; that made Thick look like it needed manual refresh.
      # Screen-coord caching still keeps per-frame work near-zero when
      # the camera hasn't actually moved.
      cam = view.camera
      cam_key = [cam.eye.x,    cam.eye.y,    cam.eye.z,
                 cam.target.x, cam.target.y, cam.target.z,
                 cam.up.x,     cam.up.y,     cam.up.z]

      ensure_cache(model)
      return if @cache.nil? || @cache.empty?

      # v5.65: selection-skip REMOVED. Historically we skipped selected
      # edges to let SU's blue selection highlight show through, but
      # that was the actual root cause of the notorious "Apply → must
      # click viewport before Thick appears" bug: HtmlDialog Apply
      # leaves the just-modified edges selected, so on every draw
      # immediately after Apply the overlay silently skipped ALL
      # target edges (v5.64 diagnose logs showed cache=1 but 0 verts
      # rendered until user clicked away to deselect). Now we always
      # render — SU's selection outline still renders underneath the
      # overlay stroke; the thick colour just wins the top pixels,
      # which is what the user actually wants to see anyway.
      if @screen_batches.nil? || @screen_batches_cam != cam_key
        rebuild_screen_batches(view, nil)
        @screen_batches_cam = cam_key
        # One-shot log so we can confirm draw() is being reached without
        # spamming every frame during camera moves.
        dashes = @screen_dash_batches  ? @screen_dash_batches.values.map(&:length).inject(0, :+)  : 0
        solids = @screen_batches       ? @screen_batches.values.map(&:length).inject(0, :+)       : 0
        covers = @screen_cover_batches ? @screen_cover_batches.values.map(&:length).inject(0, :+) : 0
        SketchDraw::Debug.log('Draw', "rebuild: cache=#{@cache && @cache.length} solid_verts=#{solids} dash_verts=#{dashes} cover_verts=#{covers}")
      end

      # Three-pass draw:
      #   (1) BG COVER — a bg-coloured rectangle spanning the full length
      #       of each dashed edge. Hides SU's own thin-solid stroke so
      #       it doesn't bleed through the gaps in our dash pattern.
      #       (Un-tagging the edge from its SKD_Style_ layer in v5.62
      #       stopped SU rendering dashes, but SU still draws the edge
      #       as a thin solid line under everything else.)
      #   (2) SOLID — GL_LINES thick strokes for non-dashed thick edges.
      #   (3) DASH  — GL_TRIANGLES coloured dashes on top of the cover.
      # Order matters: covers must be drawn BEFORE dashes so the dashes
      # sit on top of the cover instead of behind it.
      if @screen_cover_batches
        @screen_cover_batches.each do |(r, g, b, _w), tris|
          next if tris.nil? || tris.empty?
          view.drawing_color = Sketchup::Color.new(r, g, b)
          view.draw2d(GL_TRIANGLES, tris)
        end
      end
      @screen_batches.each do |(r, g, b, w), points|
        next if points.nil? || points.empty?
        view.line_width    = w
        view.drawing_color = Sketchup::Color.new(r, g, b)
        view.draw2d(GL_LINES, points)
      end
      if @screen_dash_batches
        @screen_dash_batches.each do |(r, g, b, _w), tris|
          next if tris.nil? || tris.empty?
          view.drawing_color = Sketchup::Color.new(r, g, b)
          view.draw2d(GL_TRIANGLES, tris)
        end
      end
    rescue => e
      unless @error_logged
        puts "[SketchDraw::ThicknessOverlay] ERROR: #{e.class}: #{e.message}"
        (e.backtrace || []).first(5).each { |l| puts "  #{l}" }
        @error_logged = true
      end
    end

    # Surgical cache update — patches cache entries for the edges the caller
    # just modified, without touching anything else. Callers can hand us the
    # exact xform the edge lives under, so nested selections stay correct.
    def refresh_edges(pairs)
      if @cache.nil?
        SketchDraw::Debug.log('Refresh', "cache=nil, will build fresh on next draw (skipping surgical update for #{pairs && pairs.length} pairs)")
        return
      end
      return if pairs.nil? || pairs.empty?
      SketchDraw::Debug.log('Refresh', "surgical update for #{pairs.length} pairs, cache size was #{@cache.length}")
      id_hash = {}
      pairs.each { |p| id_hash[p[:edge].object_id] = true if p[:edge] }
      @cache.reject! { |info| !info[:edge].valid? || id_hash.key?(info[:edge].object_id) }
      pairs.each do |p|
        edge = p[:edge]
        next unless edge && edge.valid?
        next if edge.respond_to?(:hidden?) && edge.hidden?
        mm = edge.get_attribute(SketchDraw::PLUGIN_ID, 'line_width_mm').to_f rescue 0.0
        next unless mm > 0
        lay = edge.respond_to?(:layer) ? edge.layer : nil
        next if lay && !lay.visible?
        color = edge_color(edge, lay) || Sketchup::Color.new(0, 0, 0)
        px = (mm * 3.78).round
        px = 1 if px < 1
        px = 8 if px > 8
        @cache << {
          edge:     edge,
          xform:    p[:xform] || Geom::Transformation.new,
          color:    color,
          width_px: px,
          pattern:  pattern_for(edge)
        }
      end
      @screen_batches       = nil  # invalidate screen cache — cache changed
      @screen_dash_batches  = nil
      @screen_cover_batches = nil
    end

    private

    def rebuild_screen_batches(view, _sel_ids_unused)
      # sel_ids parameter kept for API stability but ignored — see
      # draw() for the reason we no longer filter by selection.
      solid_batches = {}
      dash_batches  = {}
      cover_batches = {}
      # Sample the paper/sky colour once per rebuild so every dashed
      # edge shares a single cover batch. Falls back to pure white
      # (255,255,255) — that's SU's default background for the
      # top-down 2D drafting views this plugin is designed for.
      bg = nil
      begin
        ro = view.model.rendering_options
        bg = ro['BackgroundColor']
      rescue
        bg = nil
      end
      bg_r = bg ? bg.red   : 255
      bg_g = bg ? bg.green : 255
      bg_b = bg ? bg.blue  : 255
      @cache.each do |info|
        edge = info[:edge]
        next unless edge.valid?
        p1 = edge.start.position.transform(info[:xform])
        p2 = edge.end.position.transform(info[:xform])
        sp1 = view.screen_coords(p1)
        sp2 = view.screen_coords(p2)
        next if sp1.nil? || sp2.nil?
        c   = info[:color]
        key = [c.red, c.green, c.blue, info[:width_px]]
        pattern = info[:pattern]
        if pattern.nil?
          # Solid — cheap GL_LINES path, one segment.
          (solid_batches[key] ||= []).push(sp1, sp2)
        else
          # Styled — draw a bg-colour cover rectangle spanning the full
          # edge, then coloured dash rectangles on top. The cover hides
          # SU's own thin-solid rendering (the edge is un-tagged from
          # SKD_Style_ so SU no longer draws its native dash pattern,
          # but SU DOES still draw the edge as a thin solid line under
          # everything else — which used to bleed through our dash gaps
          # and made Thick+Style look like solid-with-marks. Covering
          # first lets the coloured dashes read as true dashes on paper.
          cover_key = [bg_r, bg_g, bg_b, info[:width_px]]
          add_cover_rectangle(sp1, sp2, info[:width_px], (cover_batches[cover_key] ||= []))
          bucket = (dash_batches[key] ||= [])
          split_into_dash_triangles(sp1, sp2, info[:width_px], pattern, bucket)
        end
      end
      @screen_batches       = solid_batches
      @screen_dash_batches  = dash_batches
      @screen_cover_batches = cover_batches
    end

    # Emits two triangles forming a single rectangle spanning sp1→sp2
    # with the given screen-pixel width. Used for the bg-cover pass on
    # dashed thick edges — see rebuild_screen_batches for the rationale.
    def add_cover_rectangle(sp1, sp2, width_px, out)
      dx = sp2.x - sp1.x
      dy = sp2.y - sp1.y
      length = Math.sqrt(dx * dx + dy * dy)
      return if length < 0.5
      ux = dx / length
      uy = dy / length
      half = width_px * 0.5
      px = -uy * half
      py =  ux * half
      c1 = Geom::Point3d.new(sp1.x + px, sp1.y + py, 0)
      c2 = Geom::Point3d.new(sp1.x - px, sp1.y - py, 0)
      c3 = Geom::Point3d.new(sp2.x - px, sp2.y - py, 0)
      c4 = Geom::Point3d.new(sp2.x + px, sp2.y + py, 0)
      out.push(c1, c2, c3, c1, c3, c4)
    end

    # Emits triangle-strip data for a dashed line: each dash becomes a
    # filled rectangle whose long axis matches the edge and whose short
    # axis is `width_px`. Two triangles per dash → six vertices.
    #
    # We deliberately don't use `view.line_width=` + GL_LINES for dashes:
    # GL wraps each line segment with an end-cap that extends line-width/2
    # past the endpoint, so a `[8px dash, 3px gap]` pattern with a 4px
    # thick line would render as `[8+2+2, 3-2-2]` → gaps disappear and
    # the stroke looks solid. Rectangles have exact extents.
    #
    # `pattern` is `[dash, gap, dash, gap…]` in screen pixels; it's the
    # same cadence SU uses for its native dash rendering, so the thin
    # native pattern beneath and the thick overlay pattern on top stay
    # in phase regardless of zoom.
    def split_into_dash_triangles(sp1, sp2, width_px, pattern, out)
      dx = sp2.x - sp1.x
      dy = sp2.y - sp1.y
      length = Math.sqrt(dx * dx + dy * dy)
      return if length < 0.5
      ux = dx / length
      uy = dy / length
      # Perpendicular unit vector × half-width — used to offset the two
      # long sides of each rectangle above and below the edge centre.
      half = width_px * 0.5
      px = -uy * half
      py =  ux * half
      pos = 0.0
      idx = 0
      drawing = true
      # Same safety cap as GL_LINES variant — pathological zoom-ins can't
      # blow up per-frame vertex counts. 800 iterations × 6 verts = 4800
      # verts max per edge, easily under sub-ms draw budget.
      max_iters = 800
      iters = 0
      while pos < length && iters < max_iters
        step = pattern[idx % pattern.size].to_f
        step = 0.1 if step <= 0
        finish = pos + step
        finish = length if finish > length
        if drawing
          ax = sp1.x + ux * pos
          ay = sp1.y + uy * pos
          bx = sp1.x + ux * finish
          by = sp1.y + uy * finish
          # Four corners: (a+perp, a-perp, b-perp, b+perp) → two triangles
          c1 = Geom::Point3d.new(ax + px, ay + py, 0)
          c2 = Geom::Point3d.new(ax - px, ay - py, 0)
          c3 = Geom::Point3d.new(bx - px, by - py, 0)
          c4 = Geom::Point3d.new(bx + px, by + py, 0)
          out.push(c1, c2, c3, c1, c3, c4)
        end
        pos = finish
        idx += 1
        drawing = !drawing
        iters += 1
      end
    end

    def ensure_cache(model)
      active_ents = model.active_entities
      key = [active_ents.object_id, active_ents.length]
      return if @cache && @cache_key == key

      built = []
      collect(active_ents, Geom::Transformation.new, built)
      @cache                = built
      @cache_key            = key
      @screen_batches       = nil   # cache changed → drop precomputed screen batches
      @screen_dash_batches  = nil
      @screen_cover_batches = nil
      SketchDraw::Debug.log('Cache', "rebuilt from active_entities: #{built.length} thick edges")
    end

    def collect(entities, xform, out)
      entities.each do |ent|
        next if ent.respond_to?(:hidden?) && ent.hidden?
        lay = ent.respond_to?(:layer) ? ent.layer : nil
        next if lay && !lay.visible?

        case ent
        when Sketchup::Edge
          # Attribute filter — this is the sole performance guarantee.
          # An `edge.get_attribute` call is O(1), so a full scan of a
          # 10k-edge scaffold that only has 50 thickness-tagged edges
          # takes ~10ms once (on invalidation), then zero per frame.
          mm = ent.get_attribute(SketchDraw::PLUGIN_ID, 'line_width_mm').to_f rescue 0.0
          next unless mm > 0
          color = edge_color(ent, lay) || Sketchup::Color.new(0, 0, 0)
          px = (mm * 3.78).round
          px = 1 if px < 1
          px = 8 if px > 8
          out << { edge: ent, xform: xform, color: color, width_px: px, pattern: pattern_for(ent) }
        when Sketchup::Group
          # Do NOT skip paper_frame here — users legitimately apply
          # thickness to edges inside their paper drawings.
          collect(ent.entities, xform * ent.transformation, out)
        when Sketchup::ComponentInstance
          collect(ent.definition.entities, xform * ent.transformation, out)
        end
      end
    end


    # Returns the pixel-space dash pattern array for this edge based on
    # its SketchDraw Line-Style attribute. `nil` for solid / unstyled
    # edges (rebuild_screen_batches then draws them as one segment).
    def pattern_for(edge)
      v = edge.get_attribute(SketchDraw::PLUGIN_ID, 'line_style_name') rescue nil
      return nil if v.nil?
      STYLE_DASH_PATTERN[v.to_s]
    rescue
      nil
    end

    def edge_color(edge, lay)
      m = edge.material
      return m.color if m && m.respond_to?(:color) && m.color
      if lay && lay.respond_to?(:color) && lay.color
        name = lay.name.to_s
        # Skip plugin-created tag layers (Line Style / Line Width) — those
        # are used for tagging only, not for colouring. SketchUp
        # auto-assigns a random colour to any new layer, which was
        # bleeding through as an unexpected overlay colour after Style →
        # Thick (or making thick invisible if the auto-colour happened to
        # be white). Fall back to black in those cases.
        return nil if name.start_with?('SKD_Style_') || name.start_with?('SKD_LW_')
        return lay.color unless name == 'Untagged' || name == 'Layer0' || name.empty?
      end
      nil
    rescue
      nil
    end
  end

  module ThicknessOverlayManager
    MODEL_FLAG = 'has_line_thickness'.freeze

    # Tracks whether the per-session Thick+Style migration has already run.
    # Reset when the plugin is reloaded (fresh Ruby session).
    @migrated_models = {}

    def self.install(model)
      return false unless model && model.respond_to?(:overlays)
      overlays = model.overlays
      return false unless overlays

      existing = nil
      overlays.each do |o|
        id = o.respond_to?(:overlay_id) ? o.overlay_id : nil
        existing = o if id == ThicknessOverlay::OVERLAY_ID
      end
      if existing
        existing.enabled = true if existing.respond_to?(:enabled=)
        SketchDraw::Debug.log('Install', "overlay already installed, enabled=true")
        migrate_thick_styled_edges(model)
        return true
      end

      overlay = ThicknessOverlay.new
      overlays.add(overlay)
      overlay.enabled = true if overlay.respond_to?(:enabled=)
      SketchDraw::Debug.log('Install', "overlay CREATED and registered")
      migrate_thick_styled_edges(model)
      true
    rescue => e
      SketchDraw::Debug.log('Install', "ERROR: #{e.class}: #{e.message}")
      false
    end

    # ── One-time migration: remove SKD_Style_ tag from Thick+Style edges.
    #
    # Design change in v5.62 stopped putting new Thick+Style edges on the
    # native SU line-style tag (SU's tag-driven dash cadence and our
    # pixel-fixed overlay dash cadence can never match, so two competing
    # dash patterns drew on the same edge — the "style이 깨진" look).
    # This walker fixes edges that were saved on the tag by v5.61 or
    # earlier so opening an old model doesn't require the user to
    # re-Apply everything manually.
    #
    # Performance: attribute check is O(1) per edge; on a 10k-edge
    # scaffold with only 50 thickness-tagged edges the whole scan runs
    # in a few milliseconds. Runs at most ONCE per model per session
    # (tracked via `@migrated_models` object_id set), so subsequent
    # Apply calls have zero overhead.
    def self.migrate_thick_styled_edges(model)
      return unless model
      if @migrated_models[model.object_id]
        SketchDraw::Debug.log('Migrate', "already migrated this session, skipping")
        return
      end
      @migrated_models[model.object_id] = true

      layer0 = model.layers[0]
      unless layer0
        SketchDraw::Debug.log('Migrate', "no Layer0, aborting")
        return
      end

      to_move = []
      walk = lambda do |ents|
        ents.each do |ent|
          case ent
          when Sketchup::Edge
            mm = ent.get_attribute(SketchDraw::PLUGIN_ID, 'line_width_mm').to_f rescue 0
            next unless mm > 0
            lay = ent.layer
            to_move << ent if lay && lay.name.to_s.start_with?('SKD_Style_')
          when Sketchup::Group
            walk.call(ent.entities)
          when Sketchup::ComponentInstance
            walk.call(ent.definition.entities)
          end
        end
      end
      begin
        walk.call(model.entities)
      rescue => e
        SketchDraw::Debug.log('Migrate', "walker ERROR: #{e.class}: #{e.message}")
        return
      end

      SketchDraw::Debug.log('Migrate', "found #{to_move.length} thick+SKD_Style_ edges to un-tag")
      return if to_move.empty?

      model.start_operation('SketchDraw: repair Thick+Style tags', true)
      begin
        to_move.each { |e| e.layer = layer0 rescue nil }
        model.commit_operation
        SketchDraw::Debug.log('Migrate', "committed #{to_move.length} moves to Layer0")
      rescue => e
        model.abort_operation rescue nil
        SketchDraw::Debug.log('Migrate', "commit ERROR: #{e.class}: #{e.message}")
      end
    end

    def self.invalidate
      model = Sketchup.active_model
      return unless model && model.respond_to?(:overlays)
      model.overlays.each do |o|
        next unless o.respond_to?(:overlay_id) && o.overlay_id == ThicknessOverlay::OVERLAY_ID
        o.invalidate_cache if o.respond_to?(:invalidate_cache)
      end
    rescue
      nil
    end

    # Surgical update — only the specified edges are re-evaluated.
    def self.refresh_edges(pairs)
      model = Sketchup.active_model
      return unless model && model.respond_to?(:overlays)
      model.overlays.each do |o|
        next unless o.respond_to?(:overlay_id) && o.overlay_id == ThicknessOverlay::OVERLAY_ID
        o.refresh_edges(pairs) if o.respond_to?(:refresh_edges)
      end
    rescue
      nil
    end

    # Only install if this model actually contains thickness-tagged edges.
    # A model-level flag lets us decide in O(1) — no scene walk on boot.
    def self.install_if_needed(model)
      return false unless model
      flag = model.get_attribute(SketchDraw::PLUGIN_ID, MODEL_FLAG) rescue nil
      return install(model) if flag
      false
    end
  end
end
